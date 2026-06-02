#pragma once
/**
 * @file KeeloqCipher.h
 * @brief KeeLoq cipher implementation (528 rounds).
 *
 * Ported from ProtoPirate / Flipper Zero keeloq_common.c
 * Supports: Simple, Normal, and Magic learning modes.
 */

#include <cstdint>

// Arduino defines bit(b) as a macro — undefine to avoid conflict
#ifdef bit
#undef bit
#endif

namespace keeloq {

/// Non-Linear Function lookup table
static constexpr uint32_t NLF = 0x3A5C742E;

/// Extract bit n from x
static inline uint32_t bit(uint64_t x, uint8_t n) {
    return (uint32_t)((x >> n) & 1);
}

/// 5-bit NLF input extraction
static inline uint32_t g5(uint32_t x, uint8_t a, uint8_t b, uint8_t c, uint8_t d, uint8_t e) {
    return bit(x, a) + bit(x, b) * 2 + bit(x, c) * 4 + bit(x, d) * 8 + bit(x, e) * 16;
}

/**
 * KeeLoq Encrypt (528 rounds)
 * @param data 0xBSSSCCCC — B(4bit) button, S(10bit) serial&0x3FF, C(16bit) counter
 * @param key  64-bit manufacture key
 * @return encrypted 32-bit ciphertext
 */
static inline uint32_t encrypt(uint32_t data, uint64_t key) {
    uint32_t x = data;
    for (uint32_t r = 0; r < 528; r++) {
        x = (x >> 1) ^ ((bit(x, 0) ^ bit(x, 16) ^ (uint32_t)bit(key, r & 63) ^
                          bit(NLF, g5(x, 1, 9, 20, 26, 31)))
                         << 31);
    }
    return x;
}

/**
 * KeeLoq Decrypt (528 rounds)
 * @param data encrypted 32-bit ciphertext
 * @param key  64-bit manufacture key
 * @return 0xBSSSCCCC decrypted plaintext
 */
static inline uint32_t decrypt(uint32_t data, uint64_t key) {
    uint32_t x = data;
    for (uint32_t r = 0; r < 528; r++) {
        x = (x << 1) ^ bit(x, 31) ^ bit(x, 15) ^
            (uint32_t)bit(key, (15 - r) & 63) ^
            bit(NLF, g5(x, 0, 8, 19, 25, 30));
    }
    return x;
}

/**
 * Normal Learning — derive per-device key from serial + manufacture key
 * @param serial 28-bit serial number
 * @param key    64-bit manufacture key
 * @return 64-bit device-specific key
 */
static inline uint64_t normalLearning(uint32_t serial, uint64_t key) {
    uint32_t data = serial & 0x0FFFFFFF;
    uint32_t k1 = decrypt(data | 0x20000000, key);
    uint32_t k2 = decrypt(data | 0x60000000, key);
    return ((uint64_t)k2 << 32) | k1;
}

/**
 * Magic XOR Type1 Learning
 * @param serial 28-bit serial number
 * @param xorVal 64-bit magic XOR value
 * @return 64-bit device-specific key
 */
static inline uint64_t magicXorType1(uint32_t serial, uint64_t xorVal) {
    uint32_t data = serial & 0x0FFFFFFF;
    return (((uint64_t)data << 32) | data) ^ xorVal;
}

/**
 * Magic Serial Type1 Learning
 */
static inline uint64_t magicSerialType1(uint32_t serial, uint64_t man) {
    return (man & 0xFFFFFFFF) | ((uint64_t)serial << 40) |
           ((uint64_t)(((serial & 0xFF) + ((serial >> 8) & 0xFF)) & 0xFF) << 32);
}

/**
 * Magic Serial Type2 Learning
 */
static inline uint64_t magicSerialType2(uint32_t data, uint64_t man) {
    uint8_t* p = (uint8_t*)&data;
    uint8_t* m = (uint8_t*)&man;
    m[7] = p[0];
    m[6] = p[1];
    m[5] = p[2];
    m[4] = p[3];
    return man;
}

/**
 * Magic Serial Type3 Learning
 */
static inline uint64_t magicSerialType3(uint32_t serial, uint64_t man) {
    return (man & 0xFFFFFFFFFF000000ULL) | (serial & 0xFFFFFF);
}

/// Learning type constants
enum LearningType : uint8_t {
    LEARNING_UNKNOWN = 0,
    LEARNING_SIMPLE  = 1,
    LEARNING_NORMAL  = 2,
    LEARNING_MAGIC_XOR_TYPE_1    = 4,
    LEARNING_MAGIC_SERIAL_TYPE_1 = 6,
    LEARNING_MAGIC_SERIAL_TYPE_2 = 7,
    LEARNING_MAGIC_SERIAL_TYPE_3 = 8,
};

}  // namespace keeloq
