#ifndef NICEFLO_DECODER_H
#define NICEFLO_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * NiceFloDecoder — real-time feed() decoder for Nice FLO protocol.
 *
 * Nice FLO OOK encoding (asymmetric):
 *   Bit 0: HIGH for 1×TE, LOW for 2×TE
 *   Bit 1: HIGH for 3×TE, LOW for 1×TE
 *
 * Frame: 24-bit typical (Button + Serial).
 * Preamble: 8×TE HIGH + 4×TE LOW.
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

    enum State : uint8_t { WAIT_PREAMBLE, WAIT_TE, DECODE_BITS, DONE };
    State state_;
    SubGhzProtocolDecoderBase base_;
    uint32_t te_;
    uint64_t key_;
    uint8_t bit_count_;
    uint8_t expected_bits_;
    uint32_t last_high_dur_;

    static constexpr float TE_TOLERANCE = 0.40f;
    static constexpr uint32_t TE_MIN = 100;
    static constexpr uint32_t TE_MAX = 2000;
    static constexpr uint8_t DEFAULT_BITS = 24;
    static constexpr uint32_t PREAMBLE_MIN = 1200;
};

extern const SubGhzProtocolDecoderVTable niceflo_decoder_vtable;

#endif // NICEFLO_DECODER_H
