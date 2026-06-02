#pragma once
/**
 * @file PPSubaru.h
 * @brief Subaru key fob protocol decoder/encoder.
 *
 * PWM encoding: te_short=800µs, te_long=1600µs, 64-bit.
 * Counter decryption via bit-rotation scheme.
 * Ported from ProtoPirate subaru.c
 */

#include "PPProtocol.h"

class PPSubaru : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Subaru";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {800, 1600, 200, 64};
        return t;
    }

    void reset() override {
        resetDecoder();
        bitCount_ = 0;
        key_ = 0;
        memset(keyBytes_, 0, sizeof(keyBytes_));
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (level) {
                // Look for long preamble HIGH
                if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    parserStep_ = StepCheckPreamble;
                    headerCount_ = 1;
                }
            }
            break;

        case StepCheckPreamble:
            if (!level) {
                if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    headerCount_++;
                } else if (headerCount_ >= 8 && duration > 2500) {
                    // Sync gap found after enough preamble
                    parserStep_ = StepSaveDuration;
                    bitCount_ = 0;
                    key_ = 0;
                    memset(keyBytes_, 0, sizeof(keyBytes_));
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    headerCount_++;
                } else {
                    parserStep_ = StepReset;
                }
            }
            break;

        case StepSaveDuration:
            if (level) {
                teLast_ = duration;
                parserStep_ = StepCheckDuration;
            } else {
                // Long gap means end of frame
                if (duration > 3000 && bitCount_ >= 64) {
                    return processData();
                }
                parserStep_ = StepReset;
            }
            break;

        case StepCheckDuration:
            if (!level) {
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta ||
                    DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    // PWM: short HIGH = 1, long HIGH = 0
                    uint8_t bit = (DURATION_DIFF(teLast_, t.te_short) <= t.te_delta) ? 1 : 0;
                    if (bitCount_ < 64) {
                        keyBytes_[bitCount_ / 8] |= (bit << (7 - (bitCount_ % 8)));
                        key_ = (key_ << 1) | bit;
                    }
                    bitCount_++;
                    parserStep_ = StepSaveDuration;
                } else if (duration > 3000) {
                    if (bitCount_ >= 64) {
                        return processData();
                    }
                    parserStep_ = StepReset;
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                parserStep_ = StepReset;
            }
            break;
        }
        return false;
    }

    std::vector<PPPulse> generatePulseData(const PPDecodeResult& r) override {
        std::vector<PPPulse> pulses;
        auto& t = getTiming();

        // Preamble: 80 long HIGH/LOW pairs.
        // Last LOW is extended to form the sync gap (>2500µs)
        // so it lands at an odd index (LOW position in the alternating scheme).
        for (int i = 0; i < 80; i++) {
            pulses.push_back({(int32_t)t.te_long});
            if (i < 79) {
                pulses.push_back({-(int32_t)t.te_long});
            } else {
                pulses.push_back({-4000});  // Sync gap (LOW)
            }
        }

        // Data bits (MSB first, 64 bits)
        for (int bit = 63; bit >= 0; bit--) {
            if ((r.data >> bit) & 1) {
                pulses.push_back({(int32_t)t.te_short});  // Short HIGH = 1
            } else {
                pulses.push_back({(int32_t)t.te_long});   // Long HIGH = 0
            }
            pulses.push_back({-(int32_t)t.te_short});
        }

        // End: short HIGH + long LOW gap to trigger processData
        pulses.push_back({(int32_t)t.te_short});
        pulses.push_back({-4000});
        return pulses;
    }

private:
    uint32_t bitCount_ = 0;
    uint64_t key_ = 0;
    uint8_t keyBytes_[8] = {};

    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepSaveDuration,
        StepCheckDuration,
    };

    static const char* getButtonName(uint8_t btn) {
        switch (btn) {
        case 1:  return "Lock";
        case 2:  return "Unlock";
        case 4:  return "Trunk";
        case 8:  return "Panic";
        default: return "Unknown";
        }
    }

    /// Subaru counter decryption via bit-rotation
    uint16_t decodeCounter() {
        uint8_t* kb = keyBytes_;

        // Extract lo byte from scattered bits
        uint8_t lo = ((kb[4] >> 4) & 0x0F) | ((kb[7] << 4) & 0xF0);

        // Shift registers from key bytes
        uint8_t ser0 = kb[3];
        uint8_t ser1 = kb[1];
        uint8_t ser2 = kb[2];

        // Rotate left by (4 + lo) positions
        uint8_t rotAmount = (4 + lo) & 7;
        ser0 = (ser0 << rotAmount) | (ser0 >> (8 - rotAmount));
        ser1 = (ser1 << rotAmount) | (ser1 >> (8 - rotAmount));
        ser2 = (ser2 << rotAmount) | (ser2 >> (8 - rotAmount));

        uint8_t t1 = ser0 ^ ser1;
        uint8_t t2 = t1 ^ ser2;

        uint8_t hi = t2;
        return (uint16_t)((hi << 8) | lo);
    }

    bool processData() {
        result_.data = key_;
        result_.dataBits = 64;
        result_.protocolName = PROTOCOL_NAME;

        // Extract serial from key bytes
        result_.serial = ((uint32_t)keyBytes_[0] << 16) |
                         ((uint32_t)keyBytes_[1] << 8) |
                         keyBytes_[2];
        result_.button = (keyBytes_[5] >> 4) & 0x0F;
        result_.counter = decodeCounter();
        result_.crc = 0;
        result_.crcValid = true;
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPSubaru)
