#ifndef SUB_GHZ_TYPES_H
#define SUB_GHZ_TYPES_H

#include <stdint.h>

/**
 * Protocol capability flags (bitmask).
 * Ported from Flipper Zero lib/subghz/types.h (lines 115-127).
 * Controls which decoders are active in the receiver fan-out, and
 * describes protocol capabilities.
 */
enum SubGhzProtocolFlag : uint32_t {
    SubGhzProtocolFlag_RAW       = (1 << 0),  ///< RAW decoder (fallback)
    SubGhzProtocolFlag_Decodable = (1 << 1),  ///< Known/decodable protocol
    SubGhzProtocolFlag_315       = (1 << 2),  ///< Operates on 315 MHz
    SubGhzProtocolFlag_433       = (1 << 3),  ///< Operates on 433 MHz
    SubGhzProtocolFlag_868       = (1 << 4),  ///< Operates on 868 MHz
    SubGhzProtocolFlag_AM        = (1 << 5),  ///< ASK/OOK modulation
    SubGhzProtocolFlag_FM        = (1 << 6),  ///< 2FSK/GFSK modulation
    SubGhzProtocolFlag_Save      = (1 << 7),  ///< Can be saved to file
    SubGhzProtocolFlag_Load      = (1 << 8),  ///< Can be loaded from file
    SubGhzProtocolFlag_Send      = (1 << 9),  ///< Can be transmitted
    SubGhzProtocolFlag_BinRAW    = (1 << 10), ///< BinRAW universal decoder
};

/**
 * Decoder parser step result status.
 * Returned by decoder feed/reset operations.
 */
enum class SubGhzProtocolStatus : int8_t {
    Ok = 0,
    Error = -1,
    ErrorParserBitCount = -7,
    ErrorParserTe = -9,
    ErrorParserOthers = -10,
    ErrorEncoderGetUpload = -12,
};

#endif // SUB_GHZ_TYPES_H
