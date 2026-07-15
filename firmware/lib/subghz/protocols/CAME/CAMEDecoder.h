#ifndef CAME_DECODER_H
#define CAME_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * CAMEDecoder — real-time feed() decoder for the CAME protocol (and its
 * variants: AIRFORCE, CAME_24, PRASTEL_25, PRASTEL_42).
 *
 * Matches the Flipper Zero implementation in lib/subghz/protocols/came.c.
 *
 * CAME OOK encoding:
 *   Bit 0: LOW = te_short, HIGH = te_long
 *   Bit 1: LOW = te_long,  HIGH = te_short
 *
 * Frame layout:
 *   - Preamble: a long LOW of ~te_short * 56 us
 *   - Start bit: a HIGH of ~te_short us
 *   - Data bits (12 / 18 / 24 / 25 / 42)
 *   - End of frame: a LOW of >= te_short * 4 us
 */
class CAMEDecoder {
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
    CAMEDecoder();
    ~CAMEDecoder();

    enum State : uint8_t {
        StepReset,
        StepFoundStartBit,
        StepSaveDuration,
        StepCheckDuration,
    };

    // Protocol timing constants (microseconds), matching Flipper's
    // subghz_protocol_came_const.
    static constexpr uint32_t TE_SHORT       = 320;
    static constexpr uint32_t TE_LONG        = 640;
    static constexpr uint32_t TE_DELTA       = 150;
    static constexpr uint8_t  MIN_COUNT_BIT  = 12;
    static constexpr uint32_t PREAMBLE_GUARD_TE = 56;

    // Accepted frame bit counts (besides MIN_COUNT_BIT).
    static constexpr uint8_t AIRFORCE_COUNT_BIT    = 18;
    static constexpr uint8_t CAME_24_COUNT_BIT     = 24;
    static constexpr uint8_t PRASTEL_25_COUNT_BIT = 25;
    static constexpr uint8_t PRASTEL_42_COUNT_BIT = 42;

    // SubGhzProtocolDecoderBase MUST be the first member so that a
    // SubGhzProtocolDecoderBase* cast of the decoder instance is valid
    // (matches the Flipper Zero pattern in lib/subghz/protocols/base.h).
    SubGhzProtocolDecoderBase base_;

    State    state_;
    uint64_t decode_data_;
    uint8_t  decode_count_bit_;
    uint32_t te_last_;
};

extern const SubGhzProtocolDecoderVTable came_decoder_vtable;

#endif // CAME_DECODER_H
