#pragma once
/**
 * @file PPKiaV6.h
 * @brief Kia V6 key fob protocol decoder (decode only).
 *
 * Manchester encoding: te_short=200µs, te_long=400µs, 144-bit, AES-128.
 * Requires keystore A and B for decryption.
 * Ported from ProtoPirate kia_v6.c
 */

#include "PPProtocol.h"
#include <mbedtls/aes.h>

class PPKiaV6 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Kia V6";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return false; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {200, 400, 100, 144};
        return t;
    }

    void reset() override {
        resetDecoder();
        part1Hi_ = 0; part1Lo_ = 0;
        part2Hi_ = 0; part2Lo_ = 0;
        part3_ = 0;
        preambleCount_ = 0;
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case State0_Reset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_short) > t.te_delta) return false;
            parserStep_ = State1_WaitPreamble;
            preambleCount_ = 1;
            decodeData_ = 0;
            decodeCountBit_ = 0;
            decodeHi_ = 0;
            break;

        case State1_WaitPreamble:
            if (!level) {
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    preambleCount_++;
                } else if (preambleCount_ >= 601 &&
                           DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    parserStep_ = State2_WaitLongHigh;
                } else {
                    parserStep_ = State0_Reset;
                }
            } else {
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    preambleCount_++;
                } else {
                    parserStep_ = State0_Reset;
                }
            }
            break;

        case State2_WaitLongHigh:
            if (level) {
                // Add initial sync bits: 1,1,0,1
                addBitHiLo(1); addBitHiLo(1); addBitHiLo(0); addBitHiLo(1);
                parserStep_ = State3_Data;
            } else {
                parserStep_ = State0_Reset;
            }
            break;

        case State3_Data: {
            bool isShort = DURATION_DIFF(duration, t.te_short) <= t.te_delta;
            bool isLong  = DURATION_DIFF(duration, t.te_long) <= t.te_delta;

            if (isShort) {
                if (halfPulse_) {
                    addBitHiLo(level ? 1 : 0);
                    halfPulse_ = false;
                } else {
                    halfPulse_ = true;
                }
            } else if (isLong) {
                addBitHiLo(level ? 1 : 0);
                halfPulse_ = false;
            } else {
                if (decodeCountBit_ >= 144) {
                    return decryptAndExtract();
                }
                parserStep_ = State0_Reset;
                return false;
            }

            // Checkpoints
            if (decodeCountBit_ == 64) {
                part1Hi_ = decodeHi_;
                part1Lo_ = decodeData_;
                // Invert for next section
                decodeHi_ = 0;
                decodeData_ = 0;
            } else if (decodeCountBit_ == 128) {
                part2Hi_ = decodeHi_;
                part2Lo_ = decodeData_;
                decodeHi_ = 0;
                decodeData_ = 0;
            } else if (decodeCountBit_ >= 144) {
                part3_ = (uint16_t)(decodeData_ & 0xFFFF);
                return decryptAndExtract();
            }
            break;
        }
        }
        return false;
    }

private:
    uint64_t decodeHi_ = 0;
    uint64_t part1Hi_ = 0, part1Lo_ = 0;
    uint64_t part2Hi_ = 0, part2Lo_ = 0;
    uint16_t part3_ = 0;
    uint32_t preambleCount_ = 0;
    bool halfPulse_ = false;

    enum {
        State0_Reset = 0,
        State1_WaitPreamble,
        State2_WaitLongHigh,
        State3_Data,
    };

    void addBitHiLo(uint8_t bit) {
        if (decodeCountBit_ < 64) {
            // Store in decodeHi_:decodeData_ as 128-bit shift register
            decodeHi_ = (decodeHi_ << 1) | ((decodeData_ >> 63) & 1);
            decodeData_ = (decodeData_ << 1) | bit;
        } else {
            decodeHi_ = (decodeHi_ << 1) | ((decodeData_ >> 63) & 1);
            decodeData_ = (decodeData_ << 1) | bit;
        }
        decodeCountBit_++;
    }

    /// CRC-8 (poly 0x07, init 0xFF)
    static uint8_t crc8(const uint8_t* data, size_t len) {
        uint8_t crc = 0xFF;
        for (size_t i = 0; i < len; i++) {
            crc ^= data[i];
            for (int j = 0; j < 8; j++) {
                if (crc & 0x80)
                    crc = (crc << 1) ^ 0x07;
                else
                    crc <<= 1;
            }
        }
        return crc;
    }

    bool decryptAndExtract() {
        // Assemble 16-byte encrypted block from parts
        uint8_t encrypted[16];
        for (int i = 0; i < 8; i++) {
            encrypted[i]     = (part1Hi_ >> ((7 - i) * 8)) & 0xFF;
            encrypted[8 + i] = (part1Lo_ >> ((7 - i) * 8)) & 0xFF;
        }

        // Derive AES key from keystore
        uint8_t aesKey[16];
        uint64_t keyA = kiaV6KeyA_;
        uint64_t keyB = kiaV6KeyB_;
        for (int i = 0; i < 8; i++) {
            aesKey[i]     = ((keyA >> ((7 - i) * 8)) & 0xFF) ^ XOR_MASK_HIGH[i];
            aesKey[8 + i] = ((keyB >> ((7 - i) * 8)) & 0xFF) ^ XOR_MASK_LOW[i];
        }

        // AES-128 decrypt
        uint8_t decrypted[16];
        mbedtls_aes_context aes;
        mbedtls_aes_init(&aes);
        mbedtls_aes_setkey_dec(&aes, aesKey, 128);
        mbedtls_aes_crypt_ecb(&aes, MBEDTLS_AES_DECRYPT, encrypted, decrypted);
        mbedtls_aes_free(&aes);

        // Extract fields from decrypted block
        result_.serial = ((uint32_t)decrypted[4] << 16) |
                         ((uint32_t)decrypted[5] << 8) |
                         decrypted[6];
        result_.button = decrypted[7];
        result_.counter = ((uint32_t)decrypted[8] << 24) |
                          ((uint32_t)decrypted[9] << 16) |
                          ((uint32_t)decrypted[10] << 8) |
                          decrypted[11];

        // CRC validation
        uint8_t rxCrc = decrypted[15];
        uint8_t calcCrc = crc8(decrypted, 15);
        result_.crc = rxCrc;
        result_.crcValid = (rxCrc == calcCrc);

        result_.data = part1Lo_;
        result_.data2 = part2Lo_;
        result_.dataBits = 144;
        result_.protocolName = PROTOCOL_NAME;
        result_.canEmulate = false;
        result_.encrypted = true;

        parserStep_ = State0_Reset;
        return true;
    }

    static constexpr uint8_t XOR_MASK_HIGH[8] = {0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A};
    static constexpr uint8_t XOR_MASK_LOW[8]  = {0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5, 0x5A, 0xA5};

    static uint64_t kiaV6KeyA_;
    static uint64_t kiaV6KeyB_;

public:
    static void setKeys(uint64_t keyA, uint64_t keyB) {
        kiaV6KeyA_ = keyA;
        kiaV6KeyB_ = keyB;
    }
};

inline uint64_t PPKiaV6::kiaV6KeyA_ = 0;
inline uint64_t PPKiaV6::kiaV6KeyB_ = 0;

PP_REGISTER_PROTOCOL(PPKiaV6)
