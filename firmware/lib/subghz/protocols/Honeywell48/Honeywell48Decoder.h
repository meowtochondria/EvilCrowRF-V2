#ifndef HONEYWELL48_DECODER_H
#define HONEYWELL48_DECODER_H

#include <stdint.h>
#include "../SubGhzProtocolBase.h"
#include "../SubGhzTypes.h"

/**
 * Honeywell48Decoder — real-time feed() decoder for Honeywell 48-bit protocol.
 *
 * Honeywell 48-bit OOK encoding:
 *   Bit 0: HIGH for 1×TE, LOW for 3×TE
 *   Bit 1: HIGH for 3×TE, LOW for 1×TE
 *
 * Frame: 48-bit key with Manchester-like encoding.
 * Preamble: 12×TE HIGH + 4×TE LOW.
 */
class Honeywell48Decoder {
public:
    static void* alloc();
    static void freeInstance(void* context);
    static void feed(void* context, bool level, uint32_t duration_us);
    static void resetInstance(void* context);
    static uint8_t getHashData(void* context);
    static void serialize(void* context, class File& file);
    static bool deserialize(void* context, class File& file);
    static const SubGhzProtocolDecoderVTable* vTable();

    static constexpr SubGhzProtocolFlag PROTOCOL_FLAG =
        static_cast<SubGhzProtocolFlag>(
            SubGhzProtocolFlag_433 | SubGhzProtocolFlag_315 |
            SubGhzProtocolFlag_AM | SubGhzProtocolFlag_Decodable |
            SubGhzProtocolFlag_Load | SubGhzProtocolFlag_Save | SubGhzProtocolFlag_Send);

private:
    Honeywell48Decoder();
    ~Honeywell48Decoder();

    enum State : uint8_t {
        WAIT_PREAMBLE,
        WAIT_TE,
        DECODE_BITS,
        DONE
    };

    State state_;
    SubGhzProtocolDecoderBase base_;

    uint32_t te_;
    uint64_t key_;
    uint8_t bit_count_;
    uint32_t last_high_dur_;

    static constexpr float TE_TOLERANCE = 0.40f;
    static constexpr uint32_t TE_MIN = 100;
    static constexpr uint32_t TE_MAX = 2000;
    static constexpr uint8_t EXPECTED_BITS = 48;
    static constexpr uint32_t PREAMBLE_MIN = 3000;  // 12×TE at 500us = 6000us
};

extern const SubGhzProtocolDecoderVTable honeywell48_decoder_vtable;

#endif // HONEYWELL48_DECODER_H
