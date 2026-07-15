#ifndef NICEFLO_DECODER_H
#define NICEFLO_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * NiceFloDecoder — real-time feed() decoder for Nice FLO protocol.
 *
 * Matches the Flipper Zero implementation in
 * lib/subghz/protocols/nice_flo.c.
 *
 * Nice FLO OOK encoding (asymmetric):
 *   Bit 0: LOW=te_short, HIGH=te_long
 *   Bit 1: LOW=te_long,  HIGH=te_short
 *
 * Frame: 12 to 24 bits.
 * Preamble: LOW for te_short*36.
 */
class NiceFloDecoder {
public:
    static void* alloc();
    static void freeInstance(void* context);
    static void feed(void* context, bool level, uint32_t duration_us);
    static void resetInstance(void* context);
    static uint8_t getHashData(void* context);
    static void serialize(void* context, fs::File& file);
    static bool deserialize(void* context, fs::File& file);
    static const SubGhzProtocolDecoderVTable* vTable();

    static constexpr SubGhzProtocolFlag PROTOCOL_FLAG =
        static_cast<SubGhzProtocolFlag>(
            SubGhzProtocolFlag_433 | SubGhzProtocolFlag_315 |
            SubGhzProtocolFlag_AM | SubGhzProtocolFlag_Decodable |
            SubGhzProtocolFlag_Load | SubGhzProtocolFlag_Save | SubGhzProtocolFlag_Send);

private:
    NiceFloDecoder();
    ~NiceFloDecoder();

    enum State : uint8_t {
        StepReset,
        StepFoundStartBit,
        StepSaveDuration,
        StepCheckDuration,
    };

    // SubGhzProtocolDecoderBase MUST be the first member so that a
    // SubGhzProtocolDecoderBase* cast of the decoder instance is valid
    // (matches the Flipper Zero pattern in lib/subghz/protocols/base.h).
    SubGhzProtocolDecoderBase base_;

    State state_;
    uint64_t decode_data_;
    uint8_t decode_count_bit_;
    uint32_t te_last_;

    static constexpr uint32_t TE_SHORT = 700;
    static constexpr uint32_t TE_LONG = 1400;
    static constexpr uint32_t TE_DELTA = 200;
    static constexpr uint8_t MIN_COUNT_BIT = 12;
    static constexpr uint32_t PREAMBLE_GUARD_TE = 36;
};

extern const SubGhzProtocolDecoderVTable niceflo_decoder_vtable;

#endif // NICEFLO_DECODER_H
