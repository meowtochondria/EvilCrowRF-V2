#ifndef SUB_GHZ_PROTOCOL_BASE_H
#define SUB_GHZ_PROTOCOL_BASE_H

#include <stdint.h>
#include <cstddef>
#include "SubGhzTypes.h"

namespace fs { class File; }

/**
 * LevelDuration — packed (level, duration_us) pair for ISR→worker handoff.
 *
 * Ported from Flipper Zero lib/toolbox/level_duration.h.
 *
 *   - Bit 31: level (1 = HIGH, 0 = LOW)
 *   - Bits 30..0: duration in microseconds
 *   - Special value 0xFFFFFFFF = reset/overrun sentinel
 */
struct LevelDuration {
    uint32_t data;

    static LevelDuration make(bool level, uint32_t duration) {
        LevelDuration ld;
        ld.data = (level ? 0x80000000UL : 0) | (duration & 0x7FFFFFFFUL);
        return ld;
    }

    /** Overrun sentinel — tells the worker that data was lost. */
    static LevelDuration reset() {
        LevelDuration ld;
        ld.data = 0xFFFFFFFFUL;
        return ld;
    }

    bool isReset() const {
        return data == 0xFFFFFFFFUL;
    }

    bool getLevel() const {
        return (data & 0x80000000UL) != 0;
    }

    uint32_t getDuration() const {
        return data & 0x7FFFFFFFUL;
    }
};

/**
 * SubGhzProtocolDecoderBase — per-decoder state + callback.
 *
 * Each protocol decoder gets one of these as its base struct.
 * When a decoder successfully identifies a valid frame it calls
 * the callback, which dispatches to the application layer
 * (subghz_receiver_rx_callback in the Flipper design).
 *
 * Ported from Flipper Zero lib/subghz/protocols/base.h.
 */
struct SubGhzProtocolDecoderBase;

/** Callback invoked when a decoder successfully decodes a signal. */
typedef void (*SubGhzProtocolDecoderRxCallback)(
    SubGhzProtocolDecoderBase* decoder, void* context);

struct SubGhzProtocolDecoderBase {
    const char*        protocol_name;
    SubGhzProtocolFlag flag;

    /** Called when this decoder successfully decodes a frame. */
    SubGhzProtocolDecoderRxCallback callback;
    void*                           callback_context;
};

/**
 * SubGhzProtocolDecoderVTable — C-style polymorphism for real-time decoders.
 *
 * Each protocol registers one of these so the receiver fan-out can call
 * alloc/free/feed/reset without knowing the concrete type.
 *
 * Ported from Flipper Zero lib/subghz/types.h (struct SubGhzProtocolDecoder).
 */
typedef void* (*SubGhzDecoderAlloc)();
typedef void  (*SubGhzDecoderFree)(void* context);
typedef void  (*SubGhzDecoderFeed)(void* context, bool level, uint32_t duration_us);
typedef void  (*SubGhzDecoderReset)(void* context);
typedef uint8_t (*SubGhzDecoderGetHash)(void* context);
typedef void  (*SubGhzDecoderSerialize)(void* context, fs::File& file);
typedef bool  (*SubGhzDecoderDeserialize)(void* context, fs::File& file);

struct SubGhzProtocolDecoderVTable {
    SubGhzDecoderAlloc      alloc;
    SubGhzDecoderFree       free;
    SubGhzDecoderFeed       feed;
    SubGhzDecoderReset      reset;
    SubGhzDecoderGetHash    get_hash_data;
    SubGhzDecoderSerialize  serialize;
    SubGhzDecoderDeserialize deserialize;
};

/**
 * Helper: set the decoder callback on a base struct.
 * Ported from Flipper base.c: subghz_protocol_decoder_base_set_decoder_callback.
 */
inline void subghz_protocol_decoder_base_set_callback(
    SubGhzProtocolDecoderBase* base,
    SubGhzProtocolDecoderRxCallback callback,
    void* context)
{
    base->callback = callback;
    base->callback_context = context;
}

#endif // SUB_GHZ_PROTOCOL_BASE_H
