#include "SubGhzCaptureManager.h"
#include "esp_log.h"
#include "protocols/BinRAW/BinRAWDecoder.h"

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

    // Drain the stream buffer
    LevelDuration ld;
    while (xStreamBufferReceive(sb, &ld, sizeof(ld), 0) == sizeof(ld)) {
        drained++;

        if (ld.isReset()) {
            // Overrun — reset all decoders
            ESP_LOGW(TAG, "Buffer overrun on module %d — resetting decoders", module);
            receiver->reset();
            gf.accumulator = LevelDuration::make(false, 0);
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
            // Level changed — emit the accumulated edge
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

    // Fire the application-level callback
    if (self->signalCapturedCb_) {
        // We don't know which module — search for the decoder
        for (int m = 0; m < CC1101_NUM_MODULES; m++) {
            if (self->receivers_[m] &&
                self->receivers_[m]->getDecoderByName(decoder->protocol_name) == decoder)
            {
                self->signalCapturedCb_(m, decoder->protocol_name);
                break;
            }
        }
    }
}
