#ifndef SUB_GHZ_CAPTURE_MANAGER_H
#define SUB_GHZ_CAPTURE_MANAGER_H

#include <stdint.h>
#include <freertos/FreeRTOS.h>
#include <freertos/stream_buffer.h>
#include "SubGhzReceiver.h"
#include "SubGhzProtocolBase.h"
#include "SubGhzProtocolDecoderRegistry.h"
#include "modules/CC1101_driver/CC1101_Module.h"

/**
 * SubGhzCaptureManager — manages the real-time decoder pipeline.
 *
 * Owns:
 *   - One StreamBuffer per CC1101 module for ISR→worker handoff
 *   - One SubGhzReceiver per module (with all protocol decoder slots)
 *   - Glitch filter state (30 µs merge + same-level coalescing)
 *
 * Call from the worker loop:
 *   captureManager.process(module, currentRssi);
 *
 * The ISR callback pushes LevelDuration into the StreamBuffer.
 * process() drains it, applies the glitch filter, and feeds the receiver.
 */
class SubGhzCaptureManager {
public:
    SubGhzCaptureManager();
    ~SubGhzCaptureManager();

    /**
     * Initialize all decoder slots from the registry.
     * Call once at startup from CC1101Worker::init().
     */
    void init();

    /**
     * Set the filter mask for which decoders receive data.
     * Default: BinRAW | Decodable (known protocols + BinRAW).
     */
    void setFilter(SubGhzProtocolFlag filter);

    /**
     * Feed a level/duration pair from the ISR.
     * Called from the ISR context (IRAM_ATTR safe — uses xStreamBufferSendFromISR).
     */
    bool IRAM_ATTR isrPush(int module, bool level, uint32_t duration_us);

    /**
     * Signal a buffer overrun from the ISR.
     */
    void IRAM_ATTR isrSignalOverrun(int module);

    /**
     * Process the decoder pipeline for a given module.
     * Call from the worker loop (every tick).
     * @param module        CC1101 module index (0 or 1)
     * @param currentRssi   Current RSSI from the CC1101 (for BinRAW adaptive gate)
     */
    void process(int module, float currentRssi);

    /**
     * Reset all decoders (e.g., on mode change).
     */
    void reset();

    /**
     * Get the receiver for a module (for accessing specific decoders like BinRAW).
     */
    SubGhzReceiver* getReceiver(int module) { return receivers_[module]; }

    /** Get the StreamBuffer handle for ISR use. */
    StreamBufferHandle_t getStreamBuffer(int module) { return streamBuffers_[module]; }

    /** Callback fired when any decoder decodes a valid signal. */
    using SignalCapturedCallback = void (*)(int module, const char* protocol);
    void setSignalCapturedCallback(SignalCapturedCallback cb) { signalCapturedCb_ = cb; }

private:
    static constexpr size_t STREAM_BUFFER_SIZE = 4096 * sizeof(LevelDuration);

    StreamBufferHandle_t streamBuffers_[CC1101_NUM_MODULES];
    SubGhzReceiver* receivers_[CC1101_NUM_MODULES];

    /**
     * Glitch filter state (per module).
     * Merges pulses shorter than filter_duration and coalesces same-level runs.
     */
    struct GlitchFilter {
        LevelDuration accumulator;
        uint16_t filter_duration;  ///< Pulses shorter than this are merged (µs)
    };
    GlitchFilter glitchFilters_[CC1101_NUM_MODULES];

    SignalCapturedCallback signalCapturedCb_;

    /** Internal trampoline for decoder callbacks. */
    static void onSignalDecoded(SubGhzProtocolDecoderBase* decoder, void* context);
};

/** Global singleton. */
extern SubGhzCaptureManager g_subghzCaptureManager;

#endif // SUB_GHZ_CAPTURE_MANAGER_H
