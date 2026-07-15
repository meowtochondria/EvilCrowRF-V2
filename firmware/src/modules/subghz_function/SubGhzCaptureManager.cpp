#include "SubGhzCaptureManager.h"
#include "esp_log.h"
#include "protocols/BinRAW/BinRAWDecoder.h"
#include <SD.h>
#include <cstdio>
#include <cstring>

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
    // Create one stream buffer and receiver per module
    for (int i = 0; i < CC1101_NUM_MODULES; i++) {
        // Create stream buffer (ISR → worker handoff)
        streamBuffers_[i] = xStreamBufferCreate(
            STREAM_BUFFER_SIZE,          // total buffer size (bytes)
            sizeof(LevelDuration)        // trigger level (bytes)
        );
        if (!streamBuffers_[i]) {
            ESP_LOGE(TAG, "Failed to create stream buffer for module %d", i);
            continue;
        }

        // Create receiver
        receivers_[i] = new SubGhzReceiver();

        // Register all decoders from the registry into this receiver
        const auto& allDecoders = SubGhzProtocolDecoderRegistry::instance().all();
        for (const auto& [name, entry] : allDecoders) {
            receivers_[i]->registerDecoder(
                name.c_str(),
                entry.flag,
                entry.vtable);
        }

        // Set the global callback on the receiver
        receivers_[i]->setRxCallback(onSignalDecoded, this);

        // Default filter: BinRAW + Decodable (known protocols)
        receivers_[i]->setFilter(
            static_cast<SubGhzProtocolFlag>(
                SubGhzProtocolFlag_BinRAW |
                SubGhzProtocolFlag_Decodable));

        ESP_LOGI(TAG, "Capture manager initialized for module %d with %zu decoders",
                 i, allDecoders.size());
    }
}

void SubGhzCaptureManager::setFilter(SubGhzProtocolFlag filter) {
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

    // Drain the stream buffer
    LevelDuration ld;
    while (xStreamBufferReceive(sb, &ld, sizeof(ld), 0) == sizeof(ld)) {
        drained++;

        if (ld.isReset()) {
            // Signal-end sentinel (sent by isrSignalOverrun when the gap
            // between edges exceeds MAX_SIGNAL_DURATION). Reset decoders.
            ESP_LOGW(TAG, "Signal end on module %d (drained %d edges) — resetting decoders",
                     module, drained);
            receiver->reset();
            gf.accumulator = LevelDuration::make(false, 0);
            // Reset edge log counter so the next signal's edges are logged.
            edgeLogCount[module] = 0;
            continue;
        }

        bool level = ld.getLevel();
        uint32_t duration = ld.getDuration();

        // ---- Glitch filter (port of Flipper's subghz_worker_thread_callback)
        // 1. Merge pulses shorter than filter_duration
        // 2. Coalesce consecutive same-level samples
        if ((duration < gf.filter_duration) ||
            (gf.accumulator.getLevel() == level)) {
            // Merge: accumulate duration
            uint32_t accumulated = gf.accumulator.getDuration() + duration;
            gf.accumulator = LevelDuration::make(gf.accumulator.getLevel(), accumulated);
        } else if (gf.accumulator.getLevel() != level) {
            // Level changed — emit the accumulated edge.
            // Log the first few edges per signal for diagnostics.
            if (edgeLogCount[module] < 10) {
                ESP_LOGI(TAG, "Edge: module=%d level=%d duration=%lu us",
                         module, (int)gf.accumulator.getLevel(),
                         (unsigned long)gf.accumulator.getDuration());
                edgeLogCount[module]++;
            }
            receiver->decode(
                gf.accumulator.getLevel(),
                gf.accumulator.getDuration());

            // Start new accumulation
            gf.accumulator = LevelDuration::make(level, duration);
        }
    }

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

void SubGhzCaptureManager::reset() {
    for (int i = 0; i < CC1101_NUM_MODULES; i++) {
        if (receivers_[i]) {
            receivers_[i]->reset();
        }
        if (streamBuffers_[i]) {
            xStreamBufferReset(streamBuffers_[i]);
        }
        glitchFilters_[i].accumulator = LevelDuration::make(false, 0);
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

    // ---- Phase 7: Save decoded signal to SD card ----
    // Build filename: /DATA/SIGNALS/<protocol>_<random>.sub
    char filename[128];
    {
        // Generate 8-char random string
        const char* hexChars = "0123456789ABCDEF";
        char randStr[9];
        for (int i = 0; i < 8; i++) {
            randStr[i] = hexChars[esp_random() % 16];
        }
        randStr[8] = '\0';
        snprintf(filename, sizeof(filename), "/DATA/SIGNALS/%s_%s.sub",
                 decoder->protocol_name, randStr);
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
    file.close();

    ESP_LOGI(TAG, "💾 Decoded signal saved: %s", filename);

    // Fire the application-level callback with the filename
    if (self->signalCapturedCb_) {
        self->signalCapturedCb_(foundModule, decoder->protocol_name);
    }
}
