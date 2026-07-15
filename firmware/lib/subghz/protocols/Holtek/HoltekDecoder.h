#ifndef HOLTEK_DECODER_H
#define HOLTEK_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * HoltekDecoder — real-time feed() decoder for Holtek HT12X protocol.
 *
 * Matches the Flipper Zero implementation in
 * lib/subghz/protocols/holtek_ht12x.c.
 *
 * Holtek HT12X OOK encoding:
 *   Bit 0: LOW=te_short, HIGH=te_long
 *   Bit 1: LOW=te_long,  HIGH=te_short
 *
 * Frame: 12 bits total. Preamble: long LOW (~28×te_short) followed by a
 * start bit (HIGH ~= te_short). A repeat frame must confirm the previous
 * decoded data before the callback fires.
 */
class HoltekDecoder {
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
    HoltekDecoder();
    ~HoltekDecoder();

    enum State : uint8_t {
        StepReset = 0,
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
    uint64_t last_data_;
    uint32_t te_;
    uint32_t te_last_;

    static constexpr uint32_t TE_SHORT = 320;
    static constexpr uint32_t TE_LONG = 640;
    static constexpr uint32_t TE_DELTA = 200;
    static constexpr uint32_t MIN_COUNT_BIT = 12;
    static constexpr uint32_t PREAMBLE_GUARD_TE = 28;
    static constexpr uint32_t PREAMBLE_GUARD_DELTA_TE = 20;
};

extern const SubGhzProtocolDecoderVTable holtek_decoder_vtable;

#endif // HOLTEK_DECODER_H
