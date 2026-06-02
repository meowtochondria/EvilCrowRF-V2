#pragma once
/**
 * @file Aut64Cipher.h
 * @brief AUT64 block cipher — faithful port from ProtoPirate aut64.c
 *
 * 12 rounds, 8-byte block, 8-byte key, 8-byte P-box, 16-byte S-box.
 * CRITICAL: only message[7] is transformed per round (Feistel-like).
 * Reference: USENIX Security 2016, Garcia et al.
 */

#include <cstdint>
#include <cstring>

namespace aut64 {

static constexpr int NUM_ROUNDS  = 12;
static constexpr int BLOCK_SIZE  = 8;
static constexpr int KEY_SIZE    = 8;
static constexpr int PBOX_SIZE   = 8;
static constexpr int SBOX_SIZE   = 16;
static constexpr int PACKED_SIZE = 16;

/// AUT64 key structure
struct Key {
    uint8_t index;
    uint8_t key[KEY_SIZE];
    uint8_t pbox[PBOX_SIZE];
    uint8_t sbox[SBOX_SIZE];
};

// =====================================================================
//  Round permutation tables — byte-level reorder indices
//  Exact values from original aut64.c (NOT simple rotations!)
// =====================================================================

// table_ln: controls lower-nibble key-nibble selection order per round
static const uint8_t table_ln[12][8] = {
    {4,5,6,7,0,1,2,3},  // Round  0
    {5,4,7,6,1,0,3,2},  // Round  1
    {6,7,4,5,2,3,0,1},  // Round  2
    {7,6,5,4,3,2,1,0},  // Round  3
    {0,1,2,3,4,5,6,7},  // Round  4
    {1,0,3,2,5,4,7,6},  // Round  5
    {2,3,0,1,6,7,4,5},  // Round  6
    {3,2,1,0,7,6,5,4},  // Round  7
    {5,4,7,6,1,0,3,2},  // Round  8
    {4,5,6,7,0,1,2,3},  // Round  9
    {7,6,5,4,3,2,1,0},  // Round 10
    {6,7,4,5,2,3,0,1},  // Round 11
};

// table_un: controls upper-nibble key-nibble selection order per round
static const uint8_t table_un[12][8] = {
    {1,0,3,2,5,4,7,6},  // Round  0
    {0,1,2,3,4,5,6,7},  // Round  1
    {3,2,1,0,7,6,5,4},  // Round  2
    {2,3,0,1,6,7,4,5},  // Round  3
    {5,4,7,6,1,0,3,2},  // Round  4
    {4,5,6,7,0,1,2,3},  // Round  5
    {7,6,5,4,3,2,1,0},  // Round  6
    {6,7,4,5,2,3,0,1},  // Round  7
    {3,2,1,0,7,6,5,4},  // Round  8
    {2,3,0,1,6,7,4,5},  // Round  9
    {1,0,3,2,5,4,7,6},  // Round 10
    {0,1,2,3,4,5,6,7},  // Round 11
};

/// GF(2^4) multiplication offset table (identical to original)
static const uint8_t table_offset[256] = {
    0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,0x0,
    0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x7,0x8,0x9,0xA,0xB,0xC,0xD,0xE,0xF,
    0x0,0x2,0x4,0x6,0x8,0xA,0xC,0xE,0x3,0x1,0x7,0x5,0xB,0x9,0xF,0xD,
    0x0,0x3,0x6,0x5,0xC,0xF,0xA,0x9,0xB,0x8,0xD,0xE,0x7,0x4,0x1,0x2,
    0x0,0x4,0x8,0xC,0x3,0x7,0xB,0xF,0x6,0x2,0xE,0xA,0x5,0x1,0xD,0x9,
    0x0,0x5,0xA,0xF,0x7,0x2,0xD,0x8,0xE,0xB,0x4,0x1,0x9,0xC,0x3,0x6,
    0x0,0x6,0xC,0xA,0xB,0xD,0x7,0x1,0x5,0x3,0x9,0xF,0xE,0x8,0x2,0x4,
    0x0,0x7,0xE,0x9,0xF,0x8,0x1,0x6,0xD,0xA,0x3,0x4,0x2,0x5,0xC,0xB,
    0x0,0x8,0x3,0xB,0x6,0xE,0x5,0xD,0xC,0x4,0xF,0x7,0xA,0x2,0x9,0x1,
    0x0,0x9,0x1,0x8,0x2,0xB,0x3,0xA,0x4,0xD,0x5,0xC,0x6,0xF,0x7,0xE,
    0x0,0xA,0x7,0xD,0xE,0x4,0x9,0x3,0xF,0x5,0x8,0x2,0x1,0xB,0x6,0xC,
    0x0,0xB,0x5,0xE,0xA,0x1,0xF,0x4,0x7,0xC,0x2,0x9,0xD,0x6,0x8,0x3,
    0x0,0xC,0xB,0x7,0x5,0x9,0xE,0x2,0xA,0x6,0x1,0xD,0xF,0x3,0x4,0x8,
    0x0,0xD,0x9,0x4,0x1,0xC,0x8,0x5,0x2,0xF,0xB,0x6,0x3,0xE,0xA,0x7,
    0x0,0xE,0xF,0x1,0xD,0x3,0x2,0xC,0x9,0x7,0x6,0x8,0x4,0xA,0xB,0x5,
    0x0,0xF,0xD,0x2,0x9,0x6,0x4,0xB,0x1,0xE,0xC,0x3,0x8,0x7,0x5,0xA,
};

/// Default substitution table
static const uint8_t table_sub[16] = {
    0x0,0x1,0x9,0xE,0xD,0xB,0x7,0x6,0xF,0x2,0xC,0x5,0xA,0x4,0x3,0x8,
};

// =====================================================================
//  Internal helper functions — exact port of aut64.c
// =====================================================================

/// Look up GF(2^4) offset: table_offset[(keyValue << 4) | nibble]
static inline uint8_t keyNibble(
    const Key& key, uint8_t nibble, const uint8_t table[], uint8_t iteration) {
    uint8_t keyValue = key.key[table[iteration]];
    uint8_t offset = (keyValue << 4) | nibble;
    return table_offset[offset];
}

/// Compute round key from the first 7 bytes of state
static inline uint8_t roundKey(const Key& key, const uint8_t state[], uint8_t roundN) {
    uint8_t result_hi = 0, result_lo = 0;
    for (int i = 0; i < BLOCK_SIZE - 1; i++) {
        result_hi ^= keyNibble(key, state[i] >> 4,    table_un[roundN], i);
        result_lo ^= keyNibble(key, state[i] & 0x0F,  table_ln[roundN], i);
    }
    return (result_hi << 4) | result_lo;
}

/// Final-byte nibble value: table_sub[key[table[7]]] << 4
static inline uint8_t finalByteNibble(const Key& key, const uint8_t table[]) {
    uint8_t keyValue = key.key[table[BLOCK_SIZE - 1]];
    return table_sub[keyValue] << 4;
}

/// Encrypt: find x s.t. table_offset[offset + x] == nibble (inverse lookup)
static inline uint8_t encryptFinalByteNibble(
    const Key& key, uint8_t nibble, const uint8_t table[]) {
    uint8_t offset = finalByteNibble(key, table);
    for (int i = 0; i < 16; i++) {
        if (table_offset[offset + i] == nibble) return i;
    }
    return 0;
}

/// Encrypt compress: XOR round key with inverse-lookup of final byte
static inline uint8_t encryptCompress(
    const Key& key, const uint8_t state[], uint8_t roundN) {
    uint8_t rk = roundKey(key, state, roundN);
    uint8_t result_hi = rk >> 4;
    uint8_t result_lo = rk & 0x0F;
    result_hi ^= encryptFinalByteNibble(key, state[BLOCK_SIZE - 1] >> 4,    table_un[roundN]);
    result_lo ^= encryptFinalByteNibble(key, state[BLOCK_SIZE - 1] & 0x0F,  table_ln[roundN]);
    return (result_hi << 4) | result_lo;
}

/// Decrypt: forward lookup for final byte nibble
static inline uint8_t decryptFinalByteNibble(
    const Key& key, uint8_t nibble, const uint8_t table[], uint8_t result) {
    uint8_t offset = finalByteNibble(key, table);
    return table_offset[(result ^ nibble) + offset];
}

/// Decrypt compress
static inline uint8_t decryptCompress(
    const Key& key, const uint8_t state[], uint8_t roundN) {
    uint8_t rk = roundKey(key, state, roundN);
    uint8_t result_hi = rk >> 4;
    uint8_t result_lo = rk & 0x0F;
    result_hi = decryptFinalByteNibble(
        key, state[BLOCK_SIZE - 1] >> 4,   table_un[roundN], result_hi);
    result_lo = decryptFinalByteNibble(
        key, state[BLOCK_SIZE - 1] & 0x0F, table_ln[roundN], result_lo);
    return (result_hi << 4) | result_lo;
}

/// S-box substitution on a single byte using the key's sbox
static inline uint8_t substitute(const Key& key, uint8_t byte) {
    return (key.sbox[byte >> 4] << 4) | key.sbox[byte & 0x0F];
}

/// Permute bytes using the key's P-box
static inline void permuteBytes(const Key& key, uint8_t state[]) {
    uint8_t result[PBOX_SIZE] = {0};
    for (int i = 0; i < PBOX_SIZE; i++) {
        result[key.pbox[i]] = state[i];
    }
    memcpy(state, result, PBOX_SIZE);
}

/// Permute bits within a single byte using the key's P-box
static inline uint8_t permuteBits(const Key& key, uint8_t byte) {
    uint8_t result = 0;
    for (int i = 0; i < 8; i++) {
        if (byte & (1 << i)) {
            result |= (1 << key.pbox[i]);
        }
    }
    return result;
}

/// Compute inverse of a permutation box
static inline void reverseBox(uint8_t* reversed, const uint8_t* box, size_t len) {
    for (size_t i = 0; i < len; i++) {
        for (size_t j = 0; j < len; j++) {
            if (box[j] == i) { reversed[i] = j; break; }
        }
    }
}

// =====================================================================
//  Public API
// =====================================================================

/**
 * AUT64 Encrypt — 12 rounds, forward direction.
 * Uses INVERSE key (reversed pbox, sbox).
 * Per round: permuteBytes → encryptCompress → substitute → permuteBits → substitute.
 * ONLY message[7] is modified per round (bytes 0-6 are state).
 */
static inline void encrypt(const Key& key, uint8_t message[]) {
    Key reverseKey;
    memcpy(reverseKey.key, key.key, KEY_SIZE);
    reverseBox(reverseKey.pbox, key.pbox, PBOX_SIZE);
    reverseBox(reverseKey.sbox, key.sbox, SBOX_SIZE);

    for (int i = 0; i < NUM_ROUNDS; i++) {
        permuteBytes(reverseKey, message);
        message[7] = encryptCompress(reverseKey, message, i);
        message[7] = substitute(reverseKey, message[7]);
        message[7] = permuteBits(reverseKey, message[7]);
        message[7] = substitute(reverseKey, message[7]);
    }
}

/**
 * AUT64 Decrypt — 12 rounds, reverse direction.
 * Uses FORWARD key.
 * Per round: substitute → permuteBits → substitute → decryptCompress → permuteBytes.
 * ONLY message[7] is modified per round.
 */
static inline void decrypt(const Key& key, uint8_t message[]) {
    for (int i = NUM_ROUNDS - 1; i >= 0; i--) {
        message[7] = substitute(key, message[7]);
        message[7] = permuteBits(key, message[7]);
        message[7] = substitute(key, message[7]);
        message[7] = decryptCompress(key, message, i);
        permuteBytes(key, message);
    }
}

/**
 * Pack key struct into 16 bytes (original aut64_pack format).
 */
static inline void pack(uint8_t dest[], const Key& src) {
    dest[0] = src.index;

    for (int i = 0; i < (int)sizeof(src.key) / 2; i++) {
        dest[i + 1] = (src.key[i * 2] << 4) | src.key[i * 2 + 1];
    }

    uint32_t pbox = 0;
    for (int i = 0; i < (int)sizeof(src.pbox); i++) {
        pbox = (pbox << 3) | src.pbox[i];
    }
    dest[5] = pbox >> 16;
    dest[6] = (pbox >> 8) & 0xFF;
    dest[7] = pbox & 0xFF;

    for (int i = 0; i < (int)sizeof(src.sbox) / 2; i++) {
        dest[i + 8] = (src.sbox[i * 2] << 4) | src.sbox[i * 2 + 1];
    }
}

/**
 * Unpack 16 bytes into key struct (original aut64_unpack format).
 */
static inline void unpack(Key& dest, const uint8_t src[]) {
    dest.index = src[0];

    for (int i = 0; i < (int)sizeof(dest.key) / 2; i++) {
        dest.key[i * 2]     = src[i + 1] >> 4;
        dest.key[i * 2 + 1] = src[i + 1] & 0xF;
    }

    uint32_t pbox = ((uint32_t)src[5] << 16) | ((uint32_t)src[6] << 8) | src[7];
    for (int i = (int)sizeof(dest.pbox) - 1; i >= 0; i--) {
        dest.pbox[i] = pbox & 0x7;
        pbox >>= 3;
    }

    for (int i = 0; i < (int)sizeof(dest.sbox) / 2; i++) {
        dest.sbox[i * 2]     = src[i + 8] >> 4;
        dest.sbox[i * 2 + 1] = src[i + 8] & 0xF;
    }
}

}  // namespace aut64

