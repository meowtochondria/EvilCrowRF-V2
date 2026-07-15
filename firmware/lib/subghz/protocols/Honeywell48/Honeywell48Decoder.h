#ifndef HONEYWELL48_DECODER_H
#define HONEYWELL48_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * Honeywell48Decoder — real-time feed() decoder for Honeywell 48-bit protocol.
 *
 * Matches the Flipper Zero honeywell_wdb implementation:
 *   Bit 0: HIGH=te_short, LOW=te_long
 *   Bit 1: HIGH=te_long,  LOW=te_short
 *   Frame start: LOW pulse ~3*te_short
 *   Frame end:   HIGH pulse ~3*te_short
 *   Parity: LSB of decode_data == parity(decode_data >> 1, 47)
 */
class Honeywell48Decoder {
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
    Honeywell48Decoder();
    ~Honeywell48Decoder();

    enum State : uint8_t {
        StepReset,
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

    static constexpr uint32_t TE_SHORT = 160;
    static constexpr uint32_t TE_LONG = 320;
    static constexpr uint32_t TE_DELTA = 60;
    static constexpr uint8_t MIN_COUNT_BIT = 48;
    static constexpr uint32_t PREAMBLE_GUARD_TE = 3;
};

extern const SubGhzProtocolDecoderVTable honeywell48_decoder_vtable;

#endif // HONEYWELL48_DECODER_H
