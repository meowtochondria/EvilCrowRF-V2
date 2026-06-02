#pragma once
/**
 * @file PPProtocol.h
 * @brief Base class for all ProtoPirate protocol decoders/encoders.
 *
 * Each protocol implements:
 *   - feed(level, duration) → state machine decoding
 *   - reset() → reset decoder state
 *   - getResult() → return decoded fields
 *   - getName() → protocol name string
 *   - generatePulseData() → for TX (optional)
 */

#include "PPCommon.h"
#include <vector>
#include <functional>
#include <memory>

// ============================================================================
// DECODE RESULT
// ============================================================================

/// Result of a successful protocol decode
struct PPDecodeResult {
    const char* protocolName = nullptr; ///< Protocol name string
    uint64_t data        = 0;          ///< Raw decoded data (up to 64-bit)
    uint64_t data2       = 0;          ///< Second data word (for >64-bit protocols)
    uint16_t dataBits    = 0;          ///< Number of bits decoded
    uint32_t serial      = 0;          ///< Extracted serial number
    uint8_t  button      = 0;          ///< Button code
    uint32_t counter     = 0;          ///< Rolling counter
    uint8_t  crc         = 0;          ///< CRC/checksum value
    bool     crcValid    = false;      ///< CRC validation result
    const char* type     = nullptr;    ///< Sub-protocol type string (e.g. "VAG type 1")
    uint8_t  keyIndex    = 0;          ///< Key/keystore index used for decrypt
    uint32_t bsMagic     = 0;          ///< BS field (Ford)
    bool     encrypted   = false;      ///< Signal uses encryption
    bool     canEmulate  = false;      ///< Protocol supports TX/emulation
    uint32_t frequency   = 433920000;  ///< Frequency in Hz
    const char* presetName = "AM650";  ///< Modulation preset name

    /// Format result as human-readable text
    void formatString(char* buf, size_t bufLen) const;
};

// ============================================================================
// PULSE DATA (for TX)
// ============================================================================

/// Single pulse entry for transmission
struct PPPulse {
    int32_t duration;  ///< Positive = HIGH, negative = LOW (in µs)
};

// ============================================================================
// BASE PROTOCOL CLASS
// ============================================================================

class PPProtocol {
public:
    virtual ~PPProtocol() = default;

    /// Feed a single pulse to the decoder state machine
    /// @param level true=HIGH, false=LOW
    /// @param duration pulse duration in microseconds
    /// @return true if a complete message was decoded
    virtual bool feed(bool level, uint32_t duration) = 0;

    /// Reset decoder state machine
    virtual void reset() = 0;

    /// Get the last decoded result
    virtual const PPDecodeResult& getResult() const { return result_; }

    /// Get protocol name
    virtual const char* getName() const = 0;

    /// Get timing constants
    virtual const PPTimingConst& getTiming() const = 0;

    /// Check if this protocol supports TX/emulation
    virtual bool canEmulate() const { return false; }

    /// Generate pulse data for transmission (optional)
    /// @param result The decode result to re-encode
    /// @return Vector of pulse durations (positive=HIGH, negative=LOW)
    virtual std::vector<PPPulse> generatePulseData(const PPDecodeResult& result) {
        return {};  // Default: no TX support
    }

    /// Get hash of current decoded data (for dedup)
    uint8_t getHash() const {
        return pp_hash_data(result_.data, result_.dataBits);
    }

protected:
    PPDecodeResult result_;

    // Common decoder state fields (mirrors Flipper's SubGhzBlockDecoder)
    uint64_t decodeData_    = 0;
    uint32_t decodeCountBit_ = 0;
    uint32_t parserStep_    = 0;
    uint32_t teLast_        = 0;
    uint16_t headerCount_   = 0;

    /// Shift a bit into the decode register
    void addBit(uint8_t bit) {
        decodeData_ = (decodeData_ << 1) | bit;
        decodeCountBit_++;
    }

    /// Reset common decoder state
    void resetDecoder() {
        decodeData_ = 0;
        decodeCountBit_ = 0;
        parserStep_ = 0;
        teLast_ = 0;
        headerCount_ = 0;
    }
};

// ============================================================================
// PROTOCOL REGISTRY
// ============================================================================

/// Factory function type
using PPProtocolCreator = std::unique_ptr<PPProtocol>(*)();

/// Protocol registry entry
struct PPProtocolEntry {
    const char* name;
    PPProtocolCreator creator;
};

/// Get the global list of all registered ProtoPirate protocols
const std::vector<PPProtocolEntry>& ppGetRegisteredProtocols();

/// Register a protocol (called at static init time)
void ppRegisterProtocol(const char* name, PPProtocolCreator creator);

/// Helper macro to auto-register a protocol
#define PP_REGISTER_PROTOCOL(ClassName) \
    static std::unique_ptr<PPProtocol> create_##ClassName() { \
        return std::make_unique<ClassName>(); \
    } \
    static struct ClassName##_Registrar { \
        ClassName##_Registrar() { \
            ppRegisterProtocol(ClassName::PROTOCOL_NAME, create_##ClassName); \
        } \
    } ClassName##_registrar_instance;
