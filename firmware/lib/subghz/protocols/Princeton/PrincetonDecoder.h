#ifndef PRINCETON_DECODER_H
#define PRINCETON_DECODER_H

#include <stdint.h>
#include "../SubGhzProtocolBase.h"
#include "../SubGhzTypes.h"

/**
 * PrincetonDecoder — real-time feed() decoder for Princeton protocol.
 *
 * Decodes Princeton-style OOK/ASK remote signals:
 *   - Short HIGH pulse = short LOW pulse  → bit 0  (1×TE high, 1×TE low, but
 *     actually Princeton uses: short = TE high + 3×TE low = bit 0,
 *     long = 3×TE high + TE low = bit 1)
 *
 * The decoder detects the preamble (long HIGH > 1000 µs), measures TE,
 * then decodes bits until all expected bits are captured.
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
    static void serialize(void* context, class File& file);

    /** Deserialize from file (uses existing PrincetonProtocol). */
    static bool deserialize(void* context, class File& file);

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

    enum State : uint8_t {
        WAIT_PREAMBLE,  ///< Waiting for long HIGH preamble
        WAIT_TE,        ///< Measuring TE from first low-high edge
        DECODE_BITS,    ///< Decoding bits
        DONE            ///< Frame complete
    };

    State state_;
    SubGhzProtocolDecoderBase base_;

    // Configuration
    uint8_t expected_bits_;  ///< Number of bits to decode (default 24)
    uint32_t te_;            ///< Measured timing element in µs

    // Decoding state
    uint64_t key_;           ///< Accumulated decoded key
    uint8_t bit_count_;      ///< Bits decoded so far
    uint32_t last_high_dur_; ///< Duration of the last HIGH pulse (for bit decoding)

    // Timing tolerance
    static constexpr float TE_TOLERANCE = 0.40f;   ///< ±40% tolerance for pulse matching
    static constexpr uint32_t PREAMBLE_MIN = 800;   ///< Minimum preamble HIGH (µs)
    static constexpr uint32_t TE_MIN = 100;          ///< Minimum valid TE (µs)
    static constexpr uint32_t TE_MAX = 1500;         ///< Maximum valid TE (µs)
    static constexpr uint8_t DEFAULT_BITS = 24;      ///< Default Princeton bit count
};

/** V-table declaration. */
extern const SubGhzProtocolDecoderVTable princeton_decoder_vtable;

#endif // PRINCETON_DECODER_H
