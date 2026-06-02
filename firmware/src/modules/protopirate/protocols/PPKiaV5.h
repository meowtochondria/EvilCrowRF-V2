#pragma once
/**
 * @file PPKiaV5.h
 * @brief Kia V5 key fob protocol decoder (decode only).
 *
 * Manchester encoding: te_short=400µs, te_long=800µs, 64-bit.
 * Custom "mixer" cipher (18 rounds) for counter decryption.
 * Ported from ProtoPirate kia_v5.c
 */

#include "PPProtocol.h"

class PPKiaV5 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Kia V5";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return false; }  // Decode only

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {400, 800, 150, 64};
        return t;
    }

    void reset() override {
        resetDecoder();
        savedKey_ = 0;
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_short) > t.te_delta) return false;
            parserStep_ = StepCheckPreamble;
            headerCount_ = 1;
            decodeData_ = 0;
            decodeCountBit_ = 0;
            break;

        case StepCheckPreamble:
            if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                headerCount_++;
            } else if (headerCount_ >= 40 &&
                       DURATION_DIFF(duration, t.te_long) <= t.te_delta && level) {
                parserStep_ = StepData;
                addBit(1);
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepData: {
            bool isShort = DURATION_DIFF(duration, t.te_short) <= t.te_delta;
            bool isLong  = DURATION_DIFF(duration, t.te_long) <= t.te_delta;

            if (isShort) {
                if (halfPulse_) {
                    addBit(level ? 1 : 0);
                    halfPulse_ = false;
                } else {
                    halfPulse_ = true;
                }
            } else if (isLong) {
                addBit(level ? 1 : 0);
                halfPulse_ = false;
            } else {
                // Invalid duration — process if enough bits
                if (decodeCountBit_ >= 64) {
                    return extractData();
                }
                parserStep_ = StepReset;
                return false;
            }

            if (decodeCountBit_ == 64) {
                savedKey_ = decodeData_;
                // Continue collecting to check for more bits
            }
            if (decodeCountBit_ > 67) {
                // Overflow — extract at 64 bits
                decodeData_ = savedKey_;
                decodeCountBit_ = 64;
                return extractData();
            }
            break;
        }
        }
        return false;
    }

private:
    uint64_t savedKey_ = 0;
    bool halfPulse_ = false;

    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepData,
    };

    /// Kia V5 "mixer" cipher decode (18 rounds, 8 steps each)
    static uint16_t mixerDecode(uint32_t encrypted, uint64_t key) {
        uint8_t s[4];
        s[0] = (encrypted >> 0) & 0xFF;
        s[1] = (encrypted >> 8) & 0xFF;
        s[2] = (encrypted >> 16) & 0xFF;
        s[3] = (encrypted >> 24) & 0xFF;

        uint8_t k[8];
        for (int i = 0; i < 8; i++) {
            k[i] = (key >> (i * 8)) & 0xFF;
        }

        // 18 rounds of mixing, reverse direction
        for (int round = 17; round >= 0; round--) {
            uint8_t ki = k[round % 8];

            // 8 steps of unmixing
            s[3] ^= s[2];
            s[2] ^= s[1];
            s[1] ^= s[0];
            s[0] ^= ki;

            // Rotate right
            uint8_t tmp = s[3];
            s[3] = s[2];
            s[2] = s[1];
            s[1] = s[0];
            s[0] = tmp;
        }

        return (uint16_t)((s[1] << 8) | s[0]);
    }

    bool extractData() {
        result_.data = decodeData_;
        result_.dataBits = 64;
        result_.protocolName = PROTOCOL_NAME;

        // Reverse each byte
        uint64_t yek = 0;
        for (int i = 0; i < 8; i++) {
            uint8_t b = (decodeData_ >> (i * 8)) & 0xFF;
            yek |= ((uint64_t)pp_reverse8(b)) << (i * 8);
        }

        result_.serial  = (uint32_t)((yek >> 32) & 0x0FFFFFFF);
        result_.button  = (yek >> 60) & 0x0F;
        uint32_t encrypted = (uint32_t)(yek & 0xFFFFFFFF);
        result_.counter = mixerDecode(encrypted, kiaV5Key_);
        result_.crc     = decodeData_ & 0x07;  // 3-bit CRC from overflow
        result_.crcValid = true;  // No standard CRC validation
        result_.canEmulate = false;
        result_.encrypted = true;

        parserStep_ = StepReset;
        return true;
    }

    static uint64_t kiaV5Key_;

public:
    static void setKey(uint64_t key) { kiaV5Key_ = key; }
};

inline uint64_t PPKiaV5::kiaV5Key_ = 0;

PP_REGISTER_PROTOCOL(PPKiaV5)
