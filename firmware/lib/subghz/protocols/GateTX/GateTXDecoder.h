#ifndef GATETX_DECODER_H
#define GATETX_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * GateTXDecoder — real-time feed() decoder for Gate TX protocol (universal gate/garage).
 *
 * Gate TX OOK encoding:
 *   Bit 0: HIGH for 1×TE, LOW for 2×TE
 *   Bit 1: HIGH for 2×TE, LOW for 1×TE
 */
class GateTXDecoder {
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
    GateTXDecoder();
    ~GateTXDecoder();

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
    static constexpr uint32_t PREAMBLE_MIN = 800;
};

extern const SubGhzProtocolDecoderVTable gatetx_decoder_vtable;

#endif // GATETX_DECODER_H
