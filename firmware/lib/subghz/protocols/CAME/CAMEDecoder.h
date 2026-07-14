#ifndef CAME_DECODER_H
#define CAME_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * CAMEDecoder — real-time feed() decoder for CAME protocol (used in European garage doors).
 *
 * CAME OOK encoding:
 *   Bit 0: HIGH for 1×TE, LOW for 3×TE
 *   Bit 1: HIGH for 3×TE, LOW for 1×TE
 *
 * Typical CAME frame: 4-bit preamble (4×TE HIGH/LOW pairs) + 24-28 data bits
 * + sync bit.
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
    uint8_t expected_bits_;
    uint32_t last_high_dur_;
    uint32_t expected_preamble_min_;

    static constexpr float TE_TOLERANCE = 0.40f;
    static constexpr uint32_t TE_MIN = 100;
    static constexpr uint32_t TE_MAX = 2000;
    static constexpr uint8_t DEFAULT_BITS = 28;
};

extern const SubGhzProtocolDecoderVTable came_decoder_vtable;

#endif // CAME_DECODER_H
