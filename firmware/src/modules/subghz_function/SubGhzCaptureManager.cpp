#include "SubGhzCaptureManager.h"
#include "esp_log.h"
#include "protocols/BinRAW/BinRAWDecoder.h"
#include "AllProtocols.h"  // Registers all real-time decoders + file parsers via static initializer
#include <SD.h>
#include <cstdio>
#include <cstring>
#include "esp_timer.h"

static const char* TAG = "SubGhzCaptureManager";

SubGhzCaptureManager g_subghzCaptureManager;

SubGhzCaptureManager::SubGhzCaptureManager()
    : signalCapturedCb_(nullptr)
{
    for (int i = 0; i < CC1101_NUM_MODULES; i++) {
        streamBuffers_[i] = nullptr;
        receivers_[i] = nullptr;
        glitchFilters_[i].accumulator = LevelDuration::make(false, 0);
        glitchFilters_[i].filter_duration = 30;  // 30 µs default (Flipper value)
        glitchFilters_[i].firstEdgeValid = false;
        lastDecodeTimeMs_[i] = 0;
        rawEdgeCount_[i] = 0;
    }
}

SubGhzCaptureManager::~SubGhzCaptureManager() {
    for (int i = 0; i < CC1101_NUM_MODULES; i++) {
        if (streamBuffers_[i]) {
            vStreamBufferDelete(streamBuffers_[i]);
            streamBuffers_[i] = nullptr;
        }
        delete receivers_[i];
        receivers_[i] = nullptr;
    }
}

void SubGhzCaptureManager::init() {
    // All heap resources (stream buffers + receivers) are now deferred to
    // ensureReceiver(), called when a capture first starts. This avoids
    // fragmenting the boot-time heap and breaking the SoftAP DHCP server.
    ESP_LOGI(TAG, "Capture manager initialized (all resources deferred to capture start)");
}

void SubGhzCaptureManager::ensureReceiver(int module) {
    if (module < 0 || module >= CC1101_NUM_MODULES) return;
    if (receivers_[module]) return;  // already created

    // Create stream buffer for ISR→worker handoff (deferred from boot)
    if (!streamBuffers_[module]) {
        streamBuffers_[module] = xStreamBufferCreate(
            STREAM_BUFFER_SIZE,
            sizeof(LevelDuration));
        if (!streamBuffers_[module]) {
            ESP_LOGE(TAG, "Failed to create stream buffer for module %d", module);
        }
    }

    // Create receiver
    receivers_[module] = new SubGhzReceiver();

    // Register all decoders from the registry into this receiver.
    // Decoder instances are static (see each protocol's alloc()), so this
    // only builds the slot vector — minimal heap use, done at capture start.
    const auto& allDecoders = SubGhzProtocolDecoderRegistry::instance().all();
    for (const auto& [name, entry] : allDecoders) {
        receivers_[module]->registerDecoder(
            name.c_str(),
            entry.flag,
            entry.vtable);
    }

    // Set the global callback on the receiver
    receivers_[module]->setRxCallback(onSignalDecoded, this);

    // Apply the stored filter mask (may have been set before capture started)
    receivers_[module]->setFilter(filter_);

    ESP_LOGI(TAG, "Receiver created for module %d with %zu decoders",
             module, allDecoders.size());
}

void SubGhzCaptureManager::setFilter(SubGhzProtocolFlag filter) {
    filter_ = filter;  // stored so lazily-created receivers pick it up
    for (int i = 0; i < CC1101_NUM_MODULES; i++) {
        if (receivers_[i]) {
            receivers_[i]->setFilter(filter);
        }
    }
}

bool IRAM_ATTR SubGhzCaptureManager::isrPush(int module, bool level, uint32_t duration_us) {
    if (module < 0 || module >= CC1101_NUM_MODULES || !streamBuffers_[module]) {
        return false;
    }

    LevelDuration ld = LevelDuration::make(level, duration_us);
    BaseType_t higherPriWoken = pdFALSE;
    size_t sent = xStreamBufferSendFromISR(
        streamBuffers_[module],
        &ld,
        sizeof(ld),
        &higherPriWoken);

    if (sent != sizeof(ld)) {
        return false;  // buffer full
    }

    if (higherPriWoken) {
        portYIELD_FROM_ISR();
    }
    return true;
}

void IRAM_ATTR SubGhzCaptureManager::isrSignalOverrun(int module) {
    if (module < 0 || module >= CC1101_NUM_MODULES || !streamBuffers_[module]) {
        return;
    }

    LevelDuration reset = LevelDuration::reset();
    BaseType_t higherPriWoken = pdFALSE;
    xStreamBufferSendFromISR(streamBuffers_[module], &reset, sizeof(reset), &higherPriWoken);

    if (higherPriWoken) {
        portYIELD_FROM_ISR();
    }
}

void SubGhzCaptureManager::process(int module, float currentRssi) {
    if (module < 0 || module >= CC1101_NUM_MODULES || !receivers_[module]) {
        return;
    }

    SubGhzReceiver* receiver = receivers_[module];
    GlitchFilter& gf = glitchFilters_[module];
    StreamBufferHandle_t sb = streamBuffers_[module];

    int drained = 0;

    // Edge log counter — limits how many edges we log per signal to avoid flooding.
    static uint32_t edgeLogCount[CC1101_NUM_MODULES] = {0, 0};

    // Diagnostic: log every ~100 calls how many edges drained.
    // This helps confirm the pipeline is alive and receiving data.
    static uint32_t processCallCount[CC1101_NUM_MODULES] = {0, 0};
    static uint32_t totalEdgesDrained[CC1101_NUM_MODULES] = {0, 0};
    processCallCount[module]++;

    // Drain the stream buffer
    LevelDuration ld;
    int sinceYield = 0;
    while (xStreamBufferReceive(sb, &ld, sizeof(ld), 0) == sizeof(ld)) {
        drained++;
        // Cooperative yield every ~32 edges so a noisy RF environment
        // does not starve IDLE0 of CPU time and trip the 5 s TWDT.
        if ((++sinceYield & 0x1F) == 0) {
            taskYIELD();
        }

        if (ld.isReset()) {
            // Signal-end sentinel (sent by isrSignalOverrun when the gap
            // between edges exceeds MAX_SIGNAL_DURATION). Reset decoders
            // and clear the RAW edge buffer for the next signal.
            ESP_LOGD(TAG, "Signal end on module %d (drained %d edges) — resetting decoders",
                     module, drained);
            receiver->reset();
            gf.accumulator = LevelDuration::make(false, 0);
            gf.firstEdgeValid = false;
            rawEdgeCount_[module] = 0;
            // Reset edge log counter so the next signal's edges are logged.
            edgeLogCount[module] = 0;
            continue;
        }

        bool level = ld.getLevel();
        uint32_t duration = ld.getDuration();

        // ---- Glitch filter (port of Flipper's subghz_worker_thread_callback)
        // 1. Merge pulses shorter than filter_duration
        // 2. Coalesce consecutive same-level samples
        //
        // On the very first edge we encounter, there is no real accumulated
        // level to compare against — the accumulator starts as (false, 0).
        // So instead of emitting a spurious (0, duration=0) edge, we just
        // seed the accumulator with the first real edge.
        if (!gf.firstEdgeValid) {
            gf.accumulator = LevelDuration::make(level, duration);
            gf.firstEdgeValid = true;
            continue;
        }

        if ((duration < gf.filter_duration) ||
            (gf.accumulator.getLevel() == level)) {
            // Merge: accumulate duration
            uint32_t accumulated = gf.accumulator.getDuration() + duration;
            gf.accumulator = LevelDuration::make(gf.accumulator.getLevel(), accumulated);
        } else if (gf.accumulator.getLevel() != level) {
            // Level changed — emit the accumulated edge.
            // Log the first few edges per signal for diagnostics.
            if (edgeLogCount[module] < 10) {
                ESP_LOGD(TAG, "Edge: module=%d level=%d duration=%lu us",
                         module, (int)gf.accumulator.getLevel(),
                         (unsigned long)gf.accumulator.getDuration());
                edgeLogCount[module]++;
            }
            // Accumulate the emitted edge for RAW_Data export
            // (positive = HIGH, negative = LOW).
            // Uses fixed-size C array — no heap allocation.
            if (rawEdgeCount_[module] < MAX_RAW_EDGES) {
                rawEdges_[module][rawEdgeCount_[module]++] =
                    gf.accumulator.getLevel()
                        ? static_cast<int>(gf.accumulator.getDuration())
                        : -static_cast<int>(gf.accumulator.getDuration());
            }

            receiver->decode(
                gf.accumulator.getLevel(),
                gf.accumulator.getDuration());

            // Start new accumulation
            gf.accumulator = LevelDuration::make(level, duration);
        }
    }

    // Diagnostic: log edge rate periodically (~every 2 seconds).
    if ((processCallCount[module] % 200) == 0 && drained > 0) {
        ESP_LOGI(TAG, "Module %d: %u edges drained this cycle, %u total over %u calls",
                 module, (unsigned)drained,
                 (unsigned)totalEdgesDrained[module],
                 (unsigned)processCallCount[module]);
    }
    totalEdgesDrained[module] += drained;

    // Every ~50ms, feed RSSI to the BinRAW decoder for adaptive threshold tracking
    static uint32_t lastRssiFeed[CC1101_NUM_MODULES] = {0, 0};
    uint32_t now = xTaskGetTickCount() * portTICK_PERIOD_MS;
    if (now - lastRssiFeed[module] >= 50) {
        void* binrawInstance = receiver->getDecoderInstance("BinRAW");
        if (binrawInstance) {
            SubGhzProtocolDecoderBinRAW::inputRssi(binrawInstance, currentRssi);
        }
        lastRssiFeed[module] = now;
    }
}

void SubGhzCaptureManager::freeReceiver(int module) {
    if (module < 0 || module >= CC1101_NUM_MODULES) return;
    if (!receivers_[module]) return;  // already freed

    delete receivers_[module];  // ~SubGhzReceiver clears decoder slots (static instances, no-op free)
    receivers_[module] = nullptr;

    // Free the stream buffer now that capture has stopped
    if (streamBuffers_[module]) {
        vStreamBufferDelete(streamBuffers_[module]);
        streamBuffers_[module] = nullptr;
    }

    ESP_LOGI(TAG, "Receiver and stream buffer freed for module %d", module);
}

void SubGhzCaptureManager::reset() {
    for (int i = 0; i < CC1101_NUM_MODULES; i++) {
        if (receivers_[i]) {
            receivers_[i]->reset();
        }
        if (streamBuffers_[i]) {
            xStreamBufferReset(streamBuffers_[i]);
        }
        glitchFilters_[i].accumulator = LevelDuration::make(false, 0);
        glitchFilters_[i].firstEdgeValid = false;
    }
}

void SubGhzCaptureManager::onSignalDecoded(
    SubGhzProtocolDecoderBase* decoder, void* context)
{
    auto* self = static_cast<SubGhzCaptureManager*>(context);
    if (!self || !decoder) return;

    ESP_LOGI(TAG, "✅ Signal decoded: protocol='%s'", decoder->protocol_name);

    // Find which module + slot fired the callback
    int foundModule = -1;
    void* instance = nullptr;
    const SubGhzProtocolDecoderVTable* vtable = nullptr;

    for (int m = 0; m < CC1101_NUM_MODULES; m++) {
        if (self->receivers_[m] &&
            self->receivers_[m]->getSlotByBase(decoder, instance, vtable))
        {
            foundModule = m;
            break;
        }
    }

    if (foundModule < 0 || !instance || !vtable) {
        ESP_LOGW(TAG, "Could not find slot for decoded signal");
        return;
    }

    // ---- Debounce: skip if we already saved a signal < 500 ms ago on this module ----
    // RF remotes transmit the same frame multiple times per button press (Princeton
    // sends ~5 repeats). Each repeat triggers the decoder callback independently,
    // but we only want one .sub file per physical button press.
    uint32_t nowMs = millis();
    if (self->lastDecodeTimeMs_[foundModule] != 0 &&
        (nowMs - self->lastDecodeTimeMs_[foundModule]) < 500) {
        return;
    }
    self->lastDecodeTimeMs_[foundModule] = nowMs;

    // ---- Phase 7: Save decoded signal to SD card ----
    // Build filename: /DATA/SIGNALS/<timestamp>_<protocol>.sub
    // Uses esp_timer_get_time() (microseconds since boot) so filenames
    // are always unique and monotonically increasing regardless of NTP
    // sync status. If RTC time is available later, the app can rename.
    char filename[128];
    {
        uint64_t now = esp_timer_get_time() / 1000000ULL;
        snprintf(filename, sizeof(filename), "/DATA/SIGNALS/%llu_%s.sub",
                 (unsigned long long)now, decoder->protocol_name);
    }

    // Ensure directory exists
    if (!SD.exists("/DATA/SIGNALS")) {
        SD.mkdir("/DATA/SIGNALS");
    }

    fs::File file = SD.open(filename, FILE_WRITE);
    if (!file) {
        ESP_LOGE(TAG, "Failed to create file: %s", filename);
        return;
    }

    // Write standard .sub header
    file.println("Filetype: Flipper SubGhz RAW File");
    file.println("Version: 1");
    file.print("Frequency: ");
    file.print(433920000);  // TODO: pass actual frequency from recording config
    file.println();
    file.println("Preset: FuriHalSubGhzPresetOok650Async");

    // Write protocol-specific data via decoder's serialize()
    if (vtable->serialize) {
        vtable->serialize(instance, file);
    } else {
        file.print("Protocol: ");
        file.println(decoder->protocol_name);
    }

    file.println();

    // ---- Append RAW_Data from the glitch-filter output buffer ----
    // This makes the .sub file replayable via the RAW streaming transmit
    // path, regardless of which protocol decoder matched the signal.
    // The buffer is populated in process() for every emitted edge and
    // cleared on Signal-end or after this write.
    {
        size_t n = self->rawEdgeCount_[foundModule];
        if (n > 0) {
            int* raw = self->rawEdges_[foundModule];
            file.print("RAW_Data: ");
            for (size_t i = 0; i < n; i++) {
                file.print(raw[i]);
                file.print(' ');
                if ((i + 1) % 64 == 0 && (i + 1) < n) {
                    file.println();
                    file.print("RAW_Data: ");
                }
            }
            file.println();
            self->rawEdgeCount_[foundModule] = 0;
        }
    }

    file.close();

    ESP_LOGI(TAG, "💾 Decoded signal saved: %s", filename);

    // Fire the application-level callback with the filename
    if (self->signalCapturedCb_) {
        self->signalCapturedCb_(foundModule, decoder->protocol_name);
    }
}
