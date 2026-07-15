#ifndef GATETX_DECODER_H
#define GATETX_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * GateTXDecoder — real-time feed() decoder for Gate TX protocol.
 *
 * Ported from Flipper Zero lib/subghz/protocols/gate_tx.c.
 *
 * Gate TX OOK encoding (Flipper constants):
 *   Bit 0: LOW  for 1×TE_SHORT, HIGH for 1×TE_LONG   (LOW short,  HIGH long)
 *   Bit 1: LOW  for 1×TE_LONG,  HIGH for 1×TE_SHORT  (LOW long,   HIGH short)
 *   Preamble:  a long LOW (~47×TE_SHORT) followed by a HIGH "start bit" of TE_LONG.
 *   End of frame: LOW ≥ 10×TE_SHORT + te_delta   (long inter-frame gap).
 *
 * State machine (matches Flipper):
 *   StepReset          — wait for the long preamble LOW.
 *   StepFoundStartBit  — wait for the HIGH start bit (te_long ± 3×te_delta).
 *   StepSaveDuration   — save the LOW duration of a bit; if it's long enough
 *                        (≥ 10×TE_SHORT + te_delta) → end of frame; otherwise
 *                        advance to StepCheckDuration.
 *   StepCheckDuration  — wait for the HIGH half; classify the bit using the
 *                        saved LOW duration (te_last_) vs the current HIGH
 *                        duration against TE_SHORT/TE_LONG.
 *
 * Unlike Princeton, GateTX does NOT require repeat confirmation — the callback
 * fires on the first fully-decoded frame.
 */
class GateTXDecoder {
public:
    /** Allocate instance. Returns pointer to GateTXDecoder. */
    static void* alloc();

    /** Free instance. */
    static void freeInstance(void* context);

    /**
     * Feed a level/duration pair.
     * @param context     Pointer to GateTXDecoder instance
     * @param level       Signal level (true = HIGH, false = LOW)
     * @param duration_us Duration in microseconds
     */
    static void feed(void* context, bool level, uint32_t duration_us);

    /** Reset decoder state. */
    static void resetInstance(void* context);

    /** Get hash of decoded key. */
    static uint8_t getHashData(void* context);

    /** Serialize decoded key to file (.sub format). */
    static void serialize(void* context, fs::File& file);

    /** Deserialize from file (uses existing GateTXProtocol). */
    static bool deserialize(void* context, fs::File& file);

    /** Get the v-table for use with SubGhzReceiver. */
    static const SubGhzProtocolDecoderVTable* vTable();

    /** Protocol flag. */
    static constexpr SubGhzProtocolFlag PROTOCOL_FLAG =
        static_cast<SubGhzProtocolFlag>(
            SubGhzProtocolFlag_433 |
            SubGhzProtocolFlag_315 |
            SubGhzProtocolFlag_AM |
            SubGhzProtocolFlag_Decodable |
            SubGhzProtocolFlag_Load |
            SubGhzProtocolFlag_Save |
            SubGhzProtocolFlag_Send);

private:
    GateTXDecoder();
    ~GateTXDecoder();

    // SubGhzProtocolDecoderBase MUST be the first member so that a
    // SubGhzProtocolDecoderBase* cast of the decoder instance is valid
    // (matches the Flipper Zero pattern in lib/subghz/protocols/base.h).
    SubGhzProtocolDecoderBase base_;

    enum State : uint8_t {
        StepReset,            ///< Waiting for preamble LOW.
        StepFoundStartBit,    ///< Waiting for HIGH start bit after preamble.
        StepSaveDuration,     ///< Saving LOW duration of next bit.
        StepCheckDuration,    ///< Classifying bit from LOW+HIGH pair.
    };

    State state_;

    // ---- Decoded data (mirrors Flipper's SubGhzBlockDecoder + SubGhzBlockGeneric) ----
    uint64_t decode_data_;      ///< Accumulated key bits (shifted in MSB-first).
    uint8_t  decode_count_bit_; ///< Bits decoded in the current frame.
    uint32_t te_last_;          ///< Duration of the most recent LOW pulse (for bit classification).

    // ---- Flipper protocol constants (lib/subghz/protocols/gate_tx.c) ----
    static constexpr uint32_t TE_SHORT           = 350;  ///< Short pulse (1×TE) — µs
    static constexpr uint32_t TE_LONG            = 700;  ///< Long pulse  (2×TE) — µs
    static constexpr uint32_t TE_DELTA           = 100;  ///< Tolerance for matching — µs
    static constexpr uint8_t  MIN_COUNT_BIT      = 24;   ///< Bits required before callback fires.
    static constexpr uint32_t PREAMBLE_GUARD_TE  = 47;   ///< Preamble LOW duration = TE_SHORT * PREAMBLE_GUARD_TE.
};

/** V-table declaration. */
extern const SubGhzProtocolDecoderVTable gatetx_decoder_vtable;

#endif // GATETX_DECODER_H