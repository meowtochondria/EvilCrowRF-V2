/**
 * @file ProtoPirateModule.cpp
 * @brief ProtoPirate module implementation.
 *
 * Manages CC1101 RX, feeds ISR samples to protocol decoders,
 * stores results in history, and notifies BLE clients.
 */

#include "ProtoPirateModule.h"
#include "modules/subghz_function/StreamingSubFileParser.h"
#include "FlipperSubFile.h"
#include <cstring>
#include <algorithm>

// Static allocation for FreeRTOS task
StackType_t ProtoPirateModule::taskStack_[ProtoPirateModule::TASK_STACK_SIZE];
StaticTask_t ProtoPirateModule::taskTcb_;

bool ProtoPirateModule::init() {
    if (mutex_) return true;  // Already initialized

    mutex_ = xSemaphoreCreateMutex();
    if (!mutex_) {
        ESP_LOGE(TAG, "Failed to create mutex");
        return false;
    }

    // Instantiate all registered protocol decoders
    const auto& factories = ppGetRegisteredProtocols();
    decoders_.reserve(factories.size());
    for (auto& entry : factories) {
        decoders_.push_back(entry.creator());
    }
    ESP_LOGI(TAG, "Initialized with %zu protocol decoders", decoders_.size());
    return true;
}

bool ProtoPirateModule::startDecode(int ccModule, float frequency) {
    if (state_ == PPState::Decoding) {
        ESP_LOGW(TAG, "Already decoding — stop first");
        return false;
    }

    if (ccModule < 0 || ccModule >= CC1101_NUM_MODULES) {
        ESP_LOGE(TAG, "Invalid CC1101 module: %d", ccModule);
        return false;
    }

    // Check module not busy
    if (CC1101Worker::getState(ccModule) != CC1101State::Idle) {
        ESP_LOGW(TAG, "CC1101 module %d is busy", ccModule);
        return false;
    }

    activeModule_ = ccModule;
    activeFrequency_ = frequency;
    stopRequested_ = false;

    // Reset all decoders
    for (auto& d : decoders_) d->reset();

    // Start CC1101 in ProtoPirate continuous RX mode.
    // This uses a dedicated CC1101State::ProtoPirate so the CC1101Worker
    // does NOT call processRecording (which would steal samples and remove ISR).
    bool started = CC1101Worker::startProtoPirateRX(ccModule, frequency);

    if (!started) {
        ESP_LOGE(TAG, "Failed to start CC1101 ProtoPirate RX on module %d", ccModule);
        return false;
    }

    // Create decode task (statically allocated)
    taskHandle_ = xTaskCreateStatic(
        decodeTask,
        "PPDecode",
        TASK_STACK_SIZE,
        this,
        2,  // Priority (above idle, below main)
        taskStack_,
        &taskTcb_
    );

    state_ = PPState::Decoding;
    signalCount_ = 0;
    ESP_LOGI(TAG, "Started decoding on module %d at %.2f MHz", ccModule, frequency);

    sendStatus();
    return true;
}

void ProtoPirateModule::stopDecode() {
    if (state_ != PPState::Decoding) return;

    stopRequested_ = true;

    // Wait for task to finish
    if (taskHandle_) {
        // Give the task time to see stopRequested_ and exit
        vTaskDelay(pdMS_TO_TICKS(100));
        taskHandle_ = nullptr;
    }

    // Stop CC1101 ProtoPirate RX
    if (activeModule_ >= 0) {
        CC1101Worker::stopProtoPirateRX(activeModule_);
    }

    state_ = PPState::Idle;
    activeModule_ = -1;
    ESP_LOGI(TAG, "Stopped decoding");

    sendStatus();
}

void ProtoPirateModule::clearHistory() {
    if (xSemaphoreTake(mutex_, pdMS_TO_TICKS(100)) == pdTRUE) {
        history_.clear();
        xSemaphoreGive(mutex_);
    }
}

void ProtoPirateModule::decodeTask(void* param) {
    auto* self = static_cast<ProtoPirateModule*>(param);
    self->processLoop();
    vTaskDelete(nullptr);
}

void ProtoPirateModule::processLoop() {
    ESP_LOGI(TAG, "Decode task started, monitoring module %d at %.2f MHz",
             activeModule_, activeFrequency_);

    std::vector<unsigned long> localSamples;
    localSamples.reserve(MAX_SAMPLES_BUFFER);

    uint32_t debugTimer = millis();

    while (!stopRequested_) {
        if (activeModule_ < 0) break;

        ReceivedSamples& rxData = CC1101Worker::getSamples(activeModule_);
        portMUX_TYPE& mux = CC1101Worker::getSamplesMux(activeModule_);

        // Read ISR buffer metadata under critical section
        size_t sampleCount = 0;
        unsigned long lastRxTime = 0;

        taskENTER_CRITICAL(&mux);
        sampleCount = rxData.samples.size();
        lastRxTime = rxData.lastReceiveTime;
        taskEXIT_CRITICAL(&mux);

        // Wait for signal completion: gap > MAX_SIGNAL_DURATION (100 ms)
        // This mirrors checkAndSaveRecording() behaviour and ensures the
        // full signal is available before we feed it to decoders.
        bool signalComplete = false;
        if (sampleCount >= 2 && lastRxTime > 0) {
            unsigned long now = micros();
            unsigned long elapsed = now - lastRxTime;
            if (elapsed > MAX_SIGNAL_DURATION) {
                signalComplete = true;
            }
        }

        if (signalComplete) {
            // Copy the complete signal under critical section
            localSamples.clear();
            taskENTER_CRITICAL(&mux);
            localSamples.assign(rxData.samples.begin(), rxData.samples.end());
            rxData.samples.clear();
            rxData.lastReceiveTime = 0;  // Reset for next signal
            taskEXIT_CRITICAL(&mux);

            if (!localSamples.empty()) {
                ++signalCount_;

                // Filter out noise/glitch signals (< 20 samples)
                static constexpr size_t PP_MIN_SAMPLES = 20;
                if (localSamples.size() < PP_MIN_SAMPLES) {
                    ESP_LOGD(TAG, "Signal #%lu discarded: only %zu samples (min %zu)",
                             (unsigned long)signalCount_, localSamples.size(), PP_MIN_SAMPLES);
                } else {
                    // Log first 16 pulse durations for diagnostics
                    char dbg[160];
                    int pos = 0;
                    size_t n = std::min(localSamples.size(), (size_t)16);
                    for (size_t i = 0; i < n && pos < 150; i++) {
                        pos += snprintf(dbg + pos, sizeof(dbg) - pos, "%s%lu",
                                        (i % 2 == 0) ? "+" : "-",
                                        localSamples[i]);
                    }
                    ESP_LOGI(TAG, "Signal #%lu captured: %zu samples on module %d  pulses: %s%s",
                             (unsigned long)signalCount_, localSamples.size(), activeModule_,
                             dbg, localSamples.size() > 16 ? "..." : "");
                    feedSamplesToDecoders(localSamples);
                }
            }
        }

        // Periodic debug status (every 5 s) — also notify app
        if (millis() - debugTimer >= 5000) {
            ESP_LOGI(TAG, "[PP] module %d | pending=%zu | lastRx=%lu | signals=%lu",
                     activeModule_, sampleCount, lastRxTime, (unsigned long)signalCount_);
            sendStatus();
            debugTimer = millis();
        }

        vTaskDelay(pdMS_TO_TICKS(10));  // 10 ms polling interval
    }

    ESP_LOGI(TAG, "Decode task exiting (signals captured: %lu)", (unsigned long)signalCount_);
}

void ProtoPirateModule::feedSamplesToDecoders(const std::vector<unsigned long>& samples) {
    // Samples alternate: HIGH duration, LOW duration, HIGH, LOW, ...
    bool level = true;  // First sample is HIGH

    for (size_t i = 0; i < samples.size(); i++) {
        uint32_t duration = static_cast<uint32_t>(samples[i]);

        for (auto& d : decoders_) {
            bool decoded = d->feed(level, duration);
            if (decoded) {
                PPDecodeResult result = d->getResult();
                result.frequency = activeFrequency_;

                ESP_LOGI(TAG, "Decoded: %s (data=0x%llX, serial=%u, btn=%u)",
                         result.protocolName ? result.protocolName : "?",
                         result.data, result.serial, result.button);

                // Add to history (with dedup)
                if (xSemaphoreTake(mutex_, pdMS_TO_TICKS(50)) == pdTRUE) {
                    bool isNew = history_.add(result, (uint32_t)(millis()));
                    xSemaphoreGive(mutex_);

                    if (isNew) {
                        notifyDecodeResult(result);
                    }
                }

                d->reset();
            }
        }

        level = !level;
    }
}

void ProtoPirateModule::notifyDecodeResult(const PPDecodeResult& result) {
    // Build binary notification packet for BLE
    // Format: [MSG_PP_DECODE_RESULT][protocolNameLen:1][protocolName...][data:8][data2:8]
    //         [serial:4][button:1][counter:4][dataBits:1][encrypted:1][crcValid:1]
    uint8_t buf[64];
    size_t pos = 0;

    buf[pos++] = MSG_PP_DECODE_RESULT;

    // Protocol name (variable length, max 20 chars)
    const char* name = result.protocolName ? result.protocolName : "Unknown";
    uint8_t nameLen = (uint8_t)strnlen(name, 20);
    buf[pos++] = nameLen;
    memcpy(buf + pos, name, nameLen);
    pos += nameLen;

    // Data (8 bytes LE)
    memcpy(buf + pos, &result.data, 8);
    pos += 8;

    // Data2 (8 bytes LE)
    memcpy(buf + pos, &result.data2, 8);
    pos += 8;

    // Serial (4 bytes LE)
    memcpy(buf + pos, &result.serial, 4);
    pos += 4;

    // Button (1 byte)
    buf[pos++] = result.button;

    // Counter (4 bytes LE)
    memcpy(buf + pos, &result.counter, 4);
    pos += 4;

    // dataBits (1 byte)
    buf[pos++] = result.dataBits;

    // encrypted (1 byte)
    buf[pos++] = result.encrypted ? 1 : 0;

    // crcValid (1 byte)
    buf[pos++] = result.crcValid ? 1 : 0;

    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::SignalDetected, buf, pos);
}

bool ProtoPirateModule::sendHistoryEntry(int index) {
    if (xSemaphoreTake(mutex_, pdMS_TO_TICKS(100)) != pdTRUE) return false;

    const PPHistoryEntry* entry = history_.get(index);
    if (!entry) {
        xSemaphoreGive(mutex_);
        return false;
    }

    // Copy result while holding mutex
    PPDecodeResult result = entry->result;
    uint32_t ts = entry->timestampMs;
    xSemaphoreGive(mutex_);

    // Build BLE packet — same format as decode result but with index + timestamp
    uint8_t buf[72];
    size_t pos = 0;

    buf[pos++] = MSG_PP_HISTORY_ENTRY;
    buf[pos++] = (uint8_t)index;

    // Timestamp (4 bytes LE)
    memcpy(buf + pos, &ts, 4);
    pos += 4;

    // Protocol name
    const char* name = result.protocolName ? result.protocolName : "Unknown";
    uint8_t nameLen = (uint8_t)strnlen(name, 20);
    buf[pos++] = nameLen;
    memcpy(buf + pos, name, nameLen);
    pos += nameLen;

    // Data fields (same as notifyDecodeResult)
    memcpy(buf + pos, &result.data, 8);   pos += 8;
    memcpy(buf + pos, &result.data2, 8);  pos += 8;
    memcpy(buf + pos, &result.serial, 4); pos += 4;
    buf[pos++] = result.button;
    memcpy(buf + pos, &result.counter, 4); pos += 4;
    buf[pos++] = result.dataBits;
    buf[pos++] = result.encrypted ? 1 : 0;
    buf[pos++] = result.crcValid ? 1 : 0;

    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::SignalDetected, buf, pos);
    return true;
}

void ProtoPirateModule::sendHistoryCount() {
    uint8_t buf[3];
    buf[0] = MSG_PP_HISTORY_COUNT;
    uint16_t count = (uint16_t)history_.getCount();
    memcpy(buf + 1, &count, 2);
    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::SignalDetected, buf, 3);
}

void ProtoPirateModule::sendStatus() {
    // Format: [0xB7][state:1][module:1][freqx100:2LE][signalCount:4LE] = 9 bytes
    uint8_t buf[9];
    buf[0] = MSG_PP_STATUS;
    buf[1] = (uint8_t)state_;
    buf[2] = (activeModule_ >= 0) ? (uint8_t)activeModule_ : 0xFF;
    // Frequency as uint16 in 10kHz units (e.g. 433.92 → 43392)
    uint16_t freqVal = (uint16_t)(activeFrequency_ * 100);
    memcpy(buf + 3, &freqVal, 2);
    // Signal count (total RF signals analyzed in this session)
    uint32_t sc = signalCount_;
    memcpy(buf + 5, &sc, 4);
    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::SignalDetected, buf, 9);
}

bool ProtoPirateModule::loadSubFile(const char* filePath) {
    if (!mutex_) {
        ESP_LOGE(TAG, "loadSubFile: not initialized");
        return false;
    }

    // Reset all decoders before feeding file data
    for (auto& d : decoders_) d->reset();

    StreamingSubFileParser parser;
    StreamingSubFileParser::SubFileHeader header;

    if (!parser.parseHeader(filePath, header)) {
        ESP_LOGE(TAG, "loadSubFile: failed to parse header of %s", filePath);
        return false;
    }

    ESP_LOGI(TAG, "loadSubFile: %s  freq=%u Hz  preset=%s",
             filePath, header.frequency, header.preset.c_str());

    // Set active frequency from file header (Hz → MHz)
    // so decoded results carry the correct frequency value.
    if (header.frequency > 0) {
        activeFrequency_ = (float)header.frequency / 1000000.0f;
    }

    // Collect all samples from the .sub file first
    // (streamRawData gives us signed durations: + = HIGH, - = LOW)
    std::vector<unsigned long> samples;
    samples.reserve(2048);
    size_t totalPulses = 0;

    parser.streamRawData(filePath, [&](int32_t duration_us, bool pinState) {
        // We just store absolute duration; the alternation HIGH/LOW
        // is implied by position (even=HIGH, odd=LOW) in the RAW stream.
        // The .sub format already has correct signing.
        (void)pinState;
        if (duration_us > 0) {
            samples.push_back((unsigned long)duration_us);
        }
        totalPulses++;
    });

    if (samples.size() < 20) {
        ESP_LOGW(TAG, "loadSubFile: too few samples (%zu) in %s", samples.size(), filePath);
        return false;
    }

    // Log first 16 pulses for diagnostics
    char dbg[160];
    int pos = 0;
    size_t n = std::min(samples.size(), (size_t)16);
    for (size_t i = 0; i < n && pos < 150; i++) {
        pos += snprintf(dbg + pos, sizeof(dbg) - pos, "%s%lu",
                        (i % 2 == 0) ? "+" : "-",
                        samples[i]);
    }
    ESP_LOGI(TAG, "loadSubFile: %zu samples, pulses: %s%s",
             samples.size(), dbg, samples.size() > 16 ? "..." : "");

    // Feed to decoders exactly as we do for ISR-captured signals
    feedSamplesToDecoders(samples);

    // Check if any decoder found a match (getResult has valid data)
    // We look for results that were already notified during feedSamplesToDecoders
    ESP_LOGI(TAG, "loadSubFile: analysis complete for %s (%zu pulses processed)",
             filePath, samples.size());

    return true;
}

// ── Emulate (TX) a decoded result ──────────────────────────────

PPProtocol* ProtoPirateModule::findProtocolByName(const char* name) {
    if (!name) return nullptr;
    for (auto& d : decoders_) {
        if (strcmp(d->getName(), name) == 0) {
            return d.get();
        }
    }
    return nullptr;
}

bool ProtoPirateModule::emulate(const PPDecodeResult& result,
                                 int ccModule, int repeatCount) {
    if (!mutex_) {
        ESP_LOGE(TAG, "emulate: not initialized");
        notifyTxStatus(3, 1);  // error: not initialized
        return false;
    }

    if (ccModule < 0 || ccModule >= CC1101_NUM_MODULES) {
        ESP_LOGE(TAG, "emulate: invalid module %d", ccModule);
        notifyTxStatus(3, 2);  // error: bad module
        return false;
    }

    // Find protocol encoder
    PPProtocol* proto = findProtocolByName(result.protocolName);
    if (!proto) {
        ESP_LOGE(TAG, "emulate: unknown protocol '%s'",
                 result.protocolName ? result.protocolName : "null");
        notifyTxStatus(3, 3);  // error: unknown protocol
        return false;
    }

    if (!proto->canEmulate()) {
        ESP_LOGW(TAG, "emulate: protocol '%s' does not support TX", proto->getName());
        notifyTxStatus(3, 4);  // error: protocol cannot emulate
        return false;
    }

    // Generate pulse data from the protocol encoder
    std::vector<PPPulse> pulses = proto->generatePulseData(result);
    if (pulses.empty()) {
        ESP_LOGE(TAG, "emulate: generatePulseData returned empty for '%s'", proto->getName());
        notifyTxStatus(3, 5);  // error: empty pulse data
        return false;
    }

    ESP_LOGI(TAG, "emulate: %s, %zu pulses, %d repeats on module %d",
             result.protocolName, pulses.size(), repeatCount, ccModule);

    // If currently decoding on this module, stop first
    bool wasDecoding = (state_ == PPState::Decoding && activeModule_ == ccModule);
    if (wasDecoding) {
        ESP_LOGI(TAG, "emulate: pausing decode on module %d for TX", ccModule);
        stopDecode();
        vTaskDelay(pdMS_TO_TICKS(50));
    }

    // Check module is idle (might be used by another feature)
    if (CC1101Worker::getState(ccModule) != CC1101State::Idle) {
        // Try to go idle
        CC1101Worker::goIdle(ccModule);
        vTaskDelay(pdMS_TO_TICKS(100));
        if (CC1101Worker::getState(ccModule) != CC1101State::Idle) {
            ESP_LOGE(TAG, "emulate: module %d not idle after goIdle", ccModule);
            notifyTxStatus(3, 6);  // error: module busy
            return false;
        }
    }

    notifyTxStatus(1);  // transmitting

    // Determine frequency in Hz and configure CC1101 for TX
    float freqMHz = (result.frequency > 0) ? result.frequency : activeFrequency_;
    if (freqMHz <= 0) freqMHz = 433.92f;

    // Use external CC1101 module references for TX config
    // (moduleCC1101State is declared extern in CC1101_Module.h,
    //  already included via CC1101_Worker.h → CC1101_Module.h)
    moduleCC1101State[ccModule].backupConfig()
        .setTransmitConfig(freqMHz, MODULATION_ASK_OOK, 0)
        .initConfig();

    vTaskDelay(pdMS_TO_TICKS(10));

    int outputPin = moduleCC1101State[ccModule].getOutputPin();

    // Transmit the pulses (blocking, with repeats)
    for (int rep = 0; rep < repeatCount; rep++) {
        for (auto& p : pulses) {
            if (p.duration > 0) {
                digitalWrite(outputPin, HIGH);
                delayMicroseconds((uint32_t)p.duration);
            } else if (p.duration < 0) {
                digitalWrite(outputPin, LOW);
                delayMicroseconds((uint32_t)(-p.duration));
            }
        }
        // Ensure pin goes LOW between repeats
        digitalWrite(outputPin, LOW);
        if (rep < repeatCount - 1) {
            delayMicroseconds(10000);  // 10 ms gap between repeats
        }
        taskYIELD();
    }

    // Restore CC1101 config
    moduleCC1101State[ccModule].restoreConfig();
    moduleCC1101State[ccModule].setSidle();

    ESP_LOGI(TAG, "emulate: TX complete for '%s' (%d repeats)", result.protocolName, repeatCount);
    notifyTxStatus(2);  // done

    // Restart decoding if it was active before
    if (wasDecoding) {
        ESP_LOGI(TAG, "emulate: restarting decode on module %d at %.2f MHz",
                 ccModule, freqMHz);
        vTaskDelay(pdMS_TO_TICKS(100));
        startDecode(ccModule, freqMHz);
    }

    return true;
}

// ── Save decoded result to SD card ──────────────────────────────

bool ProtoPirateModule::saveCapture(const PPDecodeResult& result,
                                     std::string& outPath) {
    if (!mutex_) {
        ESP_LOGE(TAG, "saveCapture: not initialized");
        notifySaveResult(false, "");
        return false;
    }

    // Find protocol encoder
    PPProtocol* proto = findProtocolByName(result.protocolName);
    if (!proto) {
        ESP_LOGE(TAG, "saveCapture: unknown protocol '%s'",
                 result.protocolName ? result.protocolName : "null");
        notifySaveResult(false, "");
        return false;
    }

    // Generate pulse data
    std::vector<PPPulse> pulses = proto->generatePulseData(result);
    if (pulses.empty()) {
        ESP_LOGW(TAG, "saveCapture: empty pulse data, saving metadata only");
    }

    // Ensure /DATA/PROTOPIRATE/ directory exists
    static const char* PP_DIR = "/DATA/PROTOPIRATE";
    if (!SD.exists(PP_DIR)) {
        if (!SD.mkdir(PP_DIR)) {
            // Try creating parent first
            if (!SD.exists("/DATA")) SD.mkdir("/DATA");
            if (!SD.mkdir(PP_DIR)) {
                ESP_LOGE(TAG, "saveCapture: failed to create %s", PP_DIR);
                notifySaveResult(false, "");
                return false;
            }
        }
        ESP_LOGI(TAG, "saveCapture: created directory %s", PP_DIR);
    }

    // Generate filename: ProtoName_Serial_NNNN.sub
    // Replace spaces/slashes in protocol name
    char safeName[32];
    size_t ni = 0;
    const char* pn = result.protocolName ? result.protocolName : "Unknown";
    for (size_t i = 0; pn[i] && ni < sizeof(safeName) - 1; i++) {
        char c = pn[i];
        if (c == ' ' || c == '/' || c == '\\') c = '_';
        safeName[ni++] = c;
    }
    safeName[ni] = '\0';

    // Find next available file number
    char filePath[128];
    int fileNum = 1;
    for (; fileNum <= 9999; fileNum++) {
        snprintf(filePath, sizeof(filePath), "%s/%s_%04d.sub", PP_DIR, safeName, fileNum);
        if (!SD.exists(filePath)) break;
    }
    if (fileNum > 9999) {
        ESP_LOGE(TAG, "saveCapture: too many files for protocol '%s'", safeName);
        notifySaveResult(false, "");
        return false;
    }

    // Convert PPPulse vector to unsigned long vector for FlipperSubFile
    std::vector<unsigned long> samples;
    samples.reserve(pulses.size());
    for (auto& p : pulses) {
        samples.push_back((unsigned long)std::abs(p.duration));
    }

    // Determine frequency
    float freqMHz = (result.frequency > 0) ? result.frequency : activeFrequency_;
    if (freqMHz <= 0) freqMHz = 433.92f;

    // Determine preset from protocol
    const char* presetName = result.presetName ? result.presetName : "Ook650";

    // Write .sub file
    File file = SD.open(filePath, FILE_WRITE);
    if (!file) {
        ESP_LOGE(TAG, "saveCapture: failed to open %s for writing", filePath);
        notifySaveResult(false, "");
        return false;
    }

    std::vector<byte> emptyCustom;
    FlipperSubFile::generateRaw(file, std::string(presetName), emptyCustom, samples, freqMHz);
    file.close();

    outPath = filePath;
    ESP_LOGI(TAG, "saveCapture: saved to %s (%zu samples)", filePath, samples.size());
    notifySaveResult(true, filePath);
    return true;
}

// ── TX/Save notification helpers ────────────────────────────────

void ProtoPirateModule::notifyTxStatus(uint8_t state, uint8_t errCode) {
    uint8_t buf[3];
    buf[0] = MSG_PP_TX_STATUS;
    buf[1] = state;
    buf[2] = errCode;
    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::SignalDetected, buf, 3);
}

void ProtoPirateModule::notifySaveResult(bool success, const char* path) {
    uint8_t buf[130];
    size_t pos = 0;
    buf[pos++] = MSG_PP_SAVE_RESULT;
    buf[pos++] = success ? 1 : 0;
    uint8_t pathLen = path ? (uint8_t)std::min(strlen(path), (size_t)127) : 0;
    buf[pos++] = pathLen;
    if (pathLen > 0) {
        memcpy(buf + pos, path, pathLen);
        pos += pathLen;
    }
    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::SignalDetected, buf, pos);
}
