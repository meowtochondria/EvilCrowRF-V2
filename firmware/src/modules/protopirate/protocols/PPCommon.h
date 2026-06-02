#pragma once
/**
 * @file PPCommon.h
 * @brief Common definitions and helpers for ProtoPirate protocol decoders.
 *
 * Ported from the Flipper Zero ProtoPirate project to ESP32 C++.
 * All protocol decoders share these macros, types, and utility functions.
 */

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <Arduino.h>

// ============================================================================
// TIMING HELPERS
// ============================================================================

/// Absolute difference between two unsigned durations
static inline uint32_t DURATION_DIFF(uint32_t a, uint32_t b) {
    return (a > b) ? (a - b) : (b - a);
}

// ============================================================================
// BIT MANIPULATION
// ============================================================================

/// Reverse bits in a byte (MSB <-> LSB)
static inline uint8_t pp_reverse8(uint8_t byte) {
    byte = ((byte & 0xF0) >> 4) | ((byte & 0x0F) << 4);
    byte = ((byte & 0xCC) >> 2) | ((byte & 0x33) << 2);
    byte = ((byte & 0xAA) >> 1) | ((byte & 0x55) << 1);
    return byte;
}

/// Reverse bits in a 32-bit word
static inline uint32_t pp_reverse32(uint32_t val) {
    uint32_t result = 0;
    for (int i = 0; i < 32; i++) {
        result = (result << 1) | (val & 1);
        val >>= 1;
    }
    return result;
}

/// Reverse bits in a 64-bit word
static inline uint64_t pp_reverse64(uint64_t val) {
    uint64_t result = 0;
    for (int i = 0; i < 64; i++) {
        result = (result << 1) | (val & 1);
        val >>= 1;
    }
    return result;
}

/// Extract a single bit from position n
static inline uint8_t pp_bit(uint64_t x, uint8_t n) {
    return (x >> n) & 1;
}

// ============================================================================
// MODULATION TYPES
// ============================================================================

/// Modulation/encoding type used by a protocol
enum class PPModulation : uint8_t {
    PWM,                ///< Pulse Width Modulation (short=0, long=1)
    Manchester,         ///< Manchester encoding (transition-based)
    DiffManchester,     ///< Differential Manchester
};

// ============================================================================
// PROTOCOL TIMING CONSTANTS
// ============================================================================

/// Timing constants for a protocol, mirrors Flipper's SubGhzBlockConst
struct PPTimingConst {
    uint32_t te_short;       ///< Short pulse duration (us)
    uint32_t te_long;        ///< Long pulse duration (us)
    uint32_t te_delta;       ///< Timing tolerance (us)
    uint32_t min_count_bit;  ///< Minimum bits for valid decode
};

// ============================================================================
// PROTOCOL TIMING REGISTRY (for timing analysis)
// ============================================================================

/// Timing definition for the Timing Tuner feature
struct PPProtocolTiming {
    const char* name;
    uint32_t te_short;
    uint32_t te_long;
    uint32_t te_delta;
    uint32_t min_count_bit;
};

// ============================================================================
// PRESET MAPPING
// ============================================================================

/// Convert a Flipper-style preset name to short name
static inline const char* pp_preset_to_short(const char* preset) {
    if (!preset) return "AM650";
    if (strstr(preset, "Ook650") || strstr(preset, "OOK650")) return "AM650";
    if (strstr(preset, "Ook270") || strstr(preset, "OOK270")) return "AM270";
    if (strstr(preset, "2FSKDev238") || strstr(preset, "Dev238")) return "FM238";
    if (strstr(preset, "2FSKDev12K") || strstr(preset, "Dev12K")) return "FM12K";
    if (strstr(preset, "2FSKDev476") || strstr(preset, "Dev476")) return "FM476";
    if (strcmp(preset, "AM650") == 0) return "AM650";
    if (strcmp(preset, "AM270") == 0) return "AM270";
    if (strcmp(preset, "FM238") == 0) return "FM238";
    return "AM650";
}

// ============================================================================
// HASH HELPER
// ============================================================================

/// Simple hash for decoded data (for dedup in history)
static inline uint8_t pp_hash_data(uint64_t data, uint8_t bit_count) {
    uint8_t hash = 0;
    uint8_t bytes = (bit_count + 7) / 8;
    for (uint8_t i = 0; i < bytes; i++) {
        hash ^= (uint8_t)(data >> (i * 8));
    }
    return hash;
}
