#ifndef HOLTEK_DECODER_H
#define HOLTEK_DECODER_H

#include <stdint.h>
#include "../SubGhzProtocolBase.h"
#include "../SubGhzTypes.h"

/**
 * HoltekDecoder — real-time feed() decoder for Holtek HT12X protocol.
 *
 * Holtek HT12X OOK encoding:
 *   Bit 0: HIGH for 1×TE, LOW for 3×TE
 *   Bit 1: HIGH for 3×TE, LOW for 1×TE
 *
 * Frame: 12-bit address + 4-bit data = 16 bits total.
 * Preamble: 12×TE HIGH + 4×TE LOW.
 */
class HoltekDecoder {
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
    HoltekDecoder();
    ~HoltekDecoder();

    enum State : uint8_t { WAIT_PREAMBLE, WAIT_TE, DECODE_BITS, DONE };
    State state_;
    SubGhzProtocolDecoderBase base_;
    uint32_t te_;
    uint16_t address_;
    uint8_t data_val_;
    uint8_t bit_count_;
    uint32_t last_high_dur_;

    static constexpr float TE_TOLERANCE = 0.40f;
    static constexpr uint32_t TE_MIN = 100;
    static constexpr uint32_t TE_MAX = 2000;
    static constexpr uint32_t PREAMBLE_MIN = 3000;  // 12×TE at 500us = 6000us
};

extern const SubGhzProtocolDecoderVTable holtek_decoder_vtable;

#endif // HOLTEK_DECODER_H
