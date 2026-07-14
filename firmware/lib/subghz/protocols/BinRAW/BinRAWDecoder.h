#ifndef BIN_RAW_DECODER_H
#define BIN_RAW_DECODER_H

#include <stdint.h>
#include <cstddef>
#include "../../SubGhzProtocolBase.h"
#include "../../SubGhzTypes.h"

// ============================================================
// Constants — ported from Flipper Zero lib/subghz/protocols/bin_raw.c (lines 17-25)
// DO NOT CHANGE: these are the result of extensive empirical tuning.
// ============================================================

/// Raw sample buffer (max pulse samples to accumulate before validation)
#define BIN_RAW_BUF_RAW_SIZE        2048
/// Decoded bit buffer (max bits after TE quantization)
#define BIN_RAW_BUF_DATA_SIZE       512
/// Initial adaptive RSSI threshold (dBm)
#define BIN_RAW_THRESHOLD_RSSI      -85.0f
/// Margin above adaptive threshold to start/stop capture (dB)
#define BIN_RAW_DELTA_RSSI          7.0f
/// Number of duration classes for clustering
#define BIN_RAW_SEARCH_CLASSES      20
/// Minimum occurrences of a duration class to be considered valid TE
#define BIN_RAW_TE_MIN_COUNT        40
/// Minimum raw samples required to run structural validation
#define BIN_RAW_BUF_MIN_DATA_COUNT  128
/// Maximum packet divisions when splitting at gaps
#define BIN_RAW_MAX_MARKUP_COUNT    20

// Threshold min/max clamp for adaptive threshold
#define BIN_RAW_THRESHOLD_RSSI_MIN  -100.0f
#define BIN_RAW_THRESHOLD_RSSI_MAX  -30.0f

// ============================================================
// Enums — ported from bin_raw.c lines 46-60
// ============================================================

enum class BinRAWDecoderStep : uint8_t {
    Reset = 0,   ///< Waiting for RSSI trigger
    Write,       ///< Actively accumulating raw samples from feed()
    BufFull,     ///< Buffer full (maxed out before RSSI dropped)
    NoParse,     ///< Permanently disabled / no decoding
};

enum class BinRAWType : uint8_t {
    Unknown = 0,
    NoGap,           ///< No inter-packet gap found
    Gap,             ///< Has gap but not yet classified
    GapRecurring,    ///< Adjacent same-length packets match exactly (fixed code)
    GapRolling,      ///< Every-N-th packets match (rolling code)
    GapUnknown,      ///< Same-length packets but no exact match
};

// ============================================================
// Packet markup — ported from bin_raw.c lines 62-66
// ============================================================

struct BinRAWMarkup {
    uint16_t byte_bias;  ///< Byte offset in data[] for this packet
    uint16_t bit_count;  ///< Bit count of this packet
};

// ============================================================
// Main decoder class — ported from bin_raw.c lines 68-79
// ============================================================

class SubGhzProtocolDecoderBinRAW {
public:
    // ---- Public interface (conforms to SubGhzProtocolDecoderVTable) ----

    /** Allocate and initialize. Returns pointer to instance. */
    static void* alloc();

    /** Free instance. */
    static void freeInstance(void* context);

    /**
     * Feed a level/duration pair from the receiver fan-out.
     * Only accumulates samples during BinRAWDecoderStepWrite.
     * Port of subghz_protocol_decoder_bin_raw_feed() (bin_raw.c:384-395).
     */
    static void feed(void* context, bool level, uint32_t duration_us);

    /** Reset decoder to initial state. */
    static void resetInstance(void* context);

    /** Get hash of decoded data. */
    static uint8_t getHashData(void* context);

    /** Serialize decoded signal to file. */
    static void serialize(void* context, fs::File& file);

    /** Deserialize from file (for loading saved BinRAW captures). */
    static bool deserialize(void* context, fs::File& file);

    /**
     * Feed live RSSI value to drive the adaptive threshold state machine.
     * Port of subghz_protocol_decoder_bin_raw_data_input_rssi() (bin_raw.c:884-963).
     * Must be called periodically (~50-100ms) with current RSSI.
     */
    static void inputRssi(void* context, float rssi);

    // ---- V-table for use with SubGhzReceiver ----
    static const SubGhzProtocolDecoderVTable* vTable();

    // ---- Public state (accessible for querying from worker) ----

    BinRAWDecoderStep parser_step;
    uint32_t te;                       ///< Detected timing element (µs)
    float adaptive_threshold_rssi;     ///< Current noise floor estimate
    uint32_t generic_data_count_bit;   ///< Total decoded bit count

    // ---- Stubs for protocol flags ----
    static constexpr SubGhzProtocolFlag PROTOCOL_FLAG =
        static_cast<SubGhzProtocolFlag>(
            SubGhzProtocolFlag_433 |
            SubGhzProtocolFlag_315 |
            SubGhzProtocolFlag_868 |
            SubGhzProtocolFlag_AM |
            SubGhzProtocolFlag_FM |
            SubGhzProtocolFlag_BinRAW |
            SubGhzProtocolFlag_Load |
            SubGhzProtocolFlag_Save |
            SubGhzProtocolFlag_Send);

private:
    friend class SubGhzProtocolDecoderBinRAWTest;  // for unit testing

    // ---- Private state ----
    int32_t* data_raw_;            ///< [BIN_RAW_BUF_RAW_SIZE] raw samples (±duration in µs)
    uint8_t* data_;                ///< [BIN_RAW_BUF_RAW_SIZE] decoded bits
    BinRAWMarkup data_markup_[BIN_RAW_MAX_MARKUP_COUNT];
    size_t data_raw_ind_;          ///< Current write index into data_raw_
    SubGhzProtocolDecoderBase base_;

    // ---- Private constructor/destructor ----
    SubGhzProtocolDecoderBinRAW();
    ~SubGhzProtocolDecoderBinRAW();

    // ---- Structural validation (bin_raw.c:401-882) ----
    bool checkRemoteController();

    // ---- Duration clustering helpers ----
    struct DurationClass {
        float data;     ///< Running average duration
        uint16_t count; ///< Occurrence count
    };

    void sortClassesByCount(DurationClass* classes, size_t count);
    int findGapIndex(const DurationClass* classes, uint32_t gap, uint32_t gapDelta, size_t rawCount);
};

// ---- V-table instance declaration ----
extern const SubGhzProtocolDecoderVTable binraw_decoder_vtable;

#endif // BIN_RAW_DECODER_H
