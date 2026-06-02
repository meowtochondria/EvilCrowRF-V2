#pragma once
/**
 * @file PPKiaV3V4.h
 * @brief Kia V3/V4 key fob protocol decoder.
 *
 * PWM encoding: te_short=400µs, te_long=800µs, 68-bit, KeeLoq encrypted.
 * V3 uses inverted bytes, V4 does not. Differentiator is sync pulse polarity.
 * Ported from ProtoPirate kia_v3_v4.c
 */

#include "PPProtocol.h"
#include "KeeloqCipher.h"

class PPKiaV3V4 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Kia V3/V4";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {400, 800, 150, 68};
        return t;
    }

    void reset() override {
        resetDecoder();
        isV3Sync_ = false;
        bufIdx_ = 0;
        memset(rawBuf_, 0, sizeof(rawBuf_));
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_short) > t.te_delta) return false;
            parserStep_ = StepCheckPreamble;
            headerCount_ = 1;
            bufIdx_ = 0;
            memset(rawBuf_, 0, sizeof(rawBuf_));
            decodeCountBit_ = 0;
            break;

        case StepCheckPreamble:
            if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                headerCount_++;
            } else if (headerCount_ >= 8) {
                // Sync pulse: duration between 1000-1500µs
                if (duration >= 1000 && duration <= 1500) {
                    if (level) {
                        isV3Sync_ = false;  // V4
                    } else {
                        isV3Sync_ = true;   // V3
                    }
                    parserStep_ = StepCollectRawBits;
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepCollectRawBits:
            if (level) {
                // PWM: short HIGH = 0, long HIGH = 1
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    if (bufIdx_ < 68) {
                        // Bit 0
                        bufIdx_++;
                    }
                    decodeCountBit_++;
                } else if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    if (bufIdx_ < 68) {
                        rawBuf_[bufIdx_ / 8] |= (1 << (7 - (bufIdx_ % 8)));
                        bufIdx_++;
                    }
                    decodeCountBit_++;
                } else if (duration >= 1000) {
                    // Next sync or end
                    if (bufIdx_ >= 68) {
                        return processBuffer();
                    }
                    parserStep_ = StepReset;
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                // LOW pulse — check for long gap (end of frame)
                if (duration > t.te_long * 3) {
                    if (bufIdx_ >= 68) {
                        return processBuffer();
                    }
                    parserStep_ = StepReset;
                }
            }
            break;
        }
        return false;
    }

private:
    bool isV3Sync_ = false;
    uint8_t rawBuf_[9] = {};  // 68 bits = 9 bytes
    uint16_t bufIdx_ = 0;

    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepCollectRawBits,
    };

    /// CRC4 for V3/V4: XOR all nibbles of 8 bytes
    static uint8_t crc4(const uint8_t* data, uint8_t len) {
        uint8_t crc = 0;
        for (uint8_t i = 0; i < len; i++) {
            crc ^= (data[i] & 0x0F) ^ (data[i] >> 4);
        }
        return crc & 0x0F;
    }

    bool processBuffer() {
        uint8_t b[9];
        memcpy(b, rawBuf_, 9);

        // V3: invert all bytes
        if (isV3Sync_) {
            for (int i = 0; i < 9; i++) b[i] = ~b[i];
        }

        result_.protocolName = PROTOCOL_NAME;
        result_.dataBits = 68;

        // CRC from top nibble of byte 8
        uint8_t rxCrc = (b[8] >> 4) & 0x0F;
        uint8_t calcCrc = crc4(b, 8);
        result_.crc = rxCrc;
        result_.crcValid = (rxCrc == calcCrc);

        // Extract encrypted block: bytes 0-3 reversed
        uint32_t encrypted = ((uint32_t)pp_reverse8(b[3]) << 24) |
                             ((uint32_t)pp_reverse8(b[2]) << 16) |
                             ((uint32_t)pp_reverse8(b[1]) << 8) |
                             pp_reverse8(b[0]);

        // Extract serial: bytes 4-7
        uint32_t serial = ((uint32_t)(pp_reverse8(b[7]) & 0xF0) << 20) |
                          ((uint32_t)pp_reverse8(b[6]) << 16) |
                          ((uint32_t)pp_reverse8(b[5]) << 8) |
                          pp_reverse8(b[4]);

        // Button from byte 7
        uint8_t btn = (pp_reverse8(b[7]) & 0xF0) >> 4;

        result_.serial = serial;
        result_.button = btn;
        result_.encrypted = true;

        // KeeLoq decrypt
        uint32_t decrypted = keeloq::decrypt(encrypted, kiaMfKey_);
        uint8_t decBtn = (decrypted >> 28) & 0x0F;
        uint16_t decCnt = decrypted & 0xFFFF;

        // Validate: decrypted button should match button field
        if (decBtn == btn) {
            result_.counter = decCnt;
            result_.canEmulate = true;
        } else {
            result_.counter = 0;
            result_.canEmulate = false;
        }

        // Store full data
        result_.data = ((uint64_t)b[0] << 56) | ((uint64_t)b[1] << 48) |
                       ((uint64_t)b[2] << 40) | ((uint64_t)b[3] << 32) |
                       ((uint64_t)b[4] << 24) | ((uint64_t)b[5] << 16) |
                       ((uint64_t)b[6] << 8)  | b[7];

        parserStep_ = StepReset;
        return true;
    }

    // KIA manufacture key (loaded at init time, default placeholder)
    static uint64_t kiaMfKey_;

public:
    /// Set the KIA manufacture key (loaded from keystore)
    static void setMfKey(uint64_t key) { kiaMfKey_ = key; }
};

// Static member initialization
inline uint64_t PPKiaV3V4::kiaMfKey_ = 0;

PP_REGISTER_PROTOCOL(PPKiaV3V4)
