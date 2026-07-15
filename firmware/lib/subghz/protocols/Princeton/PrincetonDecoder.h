#ifndef PRINCETON_DECODER_H
#define PRINCETON_DECODER_H

#include <stdint.h>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

/**
 * PrincetonDecoder — real-time feed() decoder for Princeton protocol.
 *
 * Ported from Flipper Zero lib/subghz/protocols/princeton.c.
 *
 * Princeton is OOK with the following encoding:
 *   Bit 0: HIGH for 1×TE, LOW for 3×TE
 *   Bit 1: HIGH for 3×TE, LOW for 1×TE
 *   Preamble: HIGH for 36×TE followed by a guard LOW (~30×TE).
 *   Frame ends with a long LOW guard (>= 2×TE_long).
 *
 * State machine (matches Flipper):
 *   StepReset        — wait for a long LOW (~36×TE) marking the preamble guard.
 *   StepSaveDuration — wait for HIGH; save its duration as te_last and accumulate.
 *   StepCheckDuration — wait for LOW; if long enough → end of frame, else
 *                       classify the bit by comparing te_last (HIGH) and current
 *                       (LOW) against te_short/te_long.
 *
 * The callback only fires when two consecutive frames decode to the same key,
 * mirroring Flipper's `last_data == decode_data && last_data` guard.
 */
class PrincetonDecoder {
public:
    /** Allocate instance. Returns pointer to PrincetonDecoder. */
    static void* alloc();

    /** Free instance. */
    static void freeInstance(void* context);

    /**
     * Feed a level/duration pair.
     * @param context     Pointer to PrincetonDecoder instance
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

    /** Deserialize from file (uses existing PrincetonProtocol). */
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
    PrincetonDecoder();
    ~PrincetonDecoder();

    // SubGhzProtocolDecoderBase MUST be the first member so that a
    // SubGhzProtocolDecoderBase* cast of the decoder instance is valid
    // (matches the Flipper Zero pattern in lib/subghz/protocols/base.h).
    SubGhzProtocolDecoderBase base_;

    enum State : uint8_t {
        StepReset,           ///< Waiting for preamble guard LOW.
        StepSaveDuration,    ///< Saving HIGH duration of next bit.
        StepCheckDuration,   ///< Classifying bit from HIGH+LOW pair, or end-of-frame.
    };

    State state_;

    // ---- Decoded data (mirrors Flipper's SubGhzBlockDecoder + SubGhzBlockGeneric) ----
    uint64_t decode_data_;     ///< Accumulated key bits (shifted in MSB-first).
    uint8_t  decode_count_bit_; ///< Bits decoded in the current frame.

    uint64_t last_data_;       ///< Previous frame's key — required to confirm a repeat.
    uint32_t te_;              ///< Running sum of pulse durations (used to compute avg TE).
    uint32_t te_last_;         ///< Duration of the most recent HIGH pulse (for bit classification).

    // ---- Flipper protocol constants (lib/subghz/protocols/princeton.c) ----
    static constexpr uint32_t TE_SHORT           = 390;  ///< Short pulse (1×TE) — µs
    static constexpr uint32_t TE_LONG            = 1170; ///< Long pulse  (3×TE) — µs
    static constexpr uint32_t TE_DELTA           = 300;  ///< Tolerance for matching — µs
    static constexpr uint8_t  MIN_COUNT_BIT      = 24;   ///< Bits required before callback fires.
    static constexpr uint32_t PREAMBLE_GUARD_TE  = 36;   ///< Preamble LOW duration = TE_SHORT * PREAMBLE_GUARD_TE.
    };

    /** V-table declaration. */
    extern const SubGhzProtocolDecoderVTable princeton_decoder_vtable;

    #endif // PRINCETON_DECODER_H