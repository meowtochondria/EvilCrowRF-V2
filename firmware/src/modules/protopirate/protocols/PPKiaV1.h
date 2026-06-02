#pragma once
/**
 * @file PPKiaV1.h
 * @brief Kia V1 key fob protocol decoder/encoder.
 *
 * Manchester encoding: te_short=800µs, te_long=1600µs, 57-bit, CRC4.
 * Ported from ProtoPirate kia_v1.c
 */

#include "PPProtocol.h"

class PPKiaV1 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Kia V1";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {800, 1600, 200, 56};
        return t;
    }

    void reset() override {
        resetDecoder();
        manchesterPrev_ = false;
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_long) > t.te_delta) return false;
            parserStep_ = StepCheckPreamble;
            headerCount_ = 1;
            decodeData_ = 0;
            decodeCountBit_ = 0;
            break;

        case StepCheckPreamble:
            if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                headerCount_++;
                if (!level && headerCount_ >= 80) {
                    // After enough preamble, look for short pulse to start data
                    parserStep_ = StepWaitData;
                }
            } else if (headerCount_ >= 80 &&
                       DURATION_DIFF(duration, t.te_short) <= t.te_delta && level) {
                parserStep_ = StepDecodeData;
                manchesterPrev_ = true;
                addBit(1);
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepWaitData:
            if (level && DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                parserStep_ = StepDecodeData;
                manchesterPrev_ = true;
                addBit(1);
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepDecodeData: {
            bool isShort = DURATION_DIFF(duration, t.te_short) <= t.te_delta;
            bool isLong  = DURATION_DIFF(duration, t.te_long) <= t.te_delta;

            if (isLong) {
                // Long pulse = transition = different bit
                manchesterPrev_ = !manchesterPrev_;
                addBit(manchesterPrev_ ? 1 : 0);
            } else if (isShort) {
                // Short pulse = half clock, need second half
                if (halfBit_) {
                    // Second half of manchester bit — same as prev
                    addBit(manchesterPrev_ ? 1 : 0);
                    halfBit_ = false;
                } else {
                    halfBit_ = true;
                }
            } else {
                // Invalid duration — check if we have enough data
                if (decodeCountBit_ >= getTiming().min_count_bit) {
                    return extractData();
                }
                parserStep_ = StepReset;
                return false;
            }

            if (decodeCountBit_ >= 57) {
                return extractData();
            }
            break;
        }
        }
        return false;
    }

    std::vector<PPPulse> generatePulseData(const PPDecodeResult& r) override {
        std::vector<PPPulse> pulses;
        auto& t = getTiming();

        // Preamble: 90 long HIGH/LOW pairs
        for (int i = 0; i < 90; i++) {
            pulses.push_back({(int32_t)t.te_long});
            pulses.push_back({-(int32_t)t.te_long});
        }

        // Manchester encode data bits
        bool prev = true;
        for (int bit = 56; bit >= 0; bit--) {
            bool val = (r.data >> bit) & 1;
            if (val == prev) {
                // Same: short-short
                pulses.push_back({(int32_t)t.te_short});
                pulses.push_back({-(int32_t)t.te_short});
            } else {
                // Different: long
                pulses.push_back({val ? (int32_t)t.te_long : -(int32_t)t.te_long});
            }
            prev = val;
        }

        pulses.push_back({-3000});
        return pulses;
    }

private:
    bool manchesterPrev_ = false;
    bool halfBit_ = false;

    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepWaitData,
        StepDecodeData,
    };

    /// CRC4 calculation specific to Kia V1
    static uint8_t crc4(uint64_t data, uint8_t bitCount, uint8_t offset) {
        uint8_t crc = 0;
        uint8_t bytes = (bitCount + 7) / 8;
        for (uint8_t i = 0; i < bytes; i++) {
            uint8_t b = (uint8_t)(data >> ((bytes - 1 - i) * 8));
            crc ^= (b & 0x0F) ^ (b >> 4);
        }
        return (crc + offset) & 0x0F;
    }

    bool extractData() {
        result_.data = decodeData_;
        result_.dataBits = decodeCountBit_;
        result_.protocolName = PROTOCOL_NAME;

        // Bit layout (57 bits):
        // serial = data >> 24, btn = (data >> 16) & 0xFF
        // cnt = ((data >> 4) & 0xF) << 8 | ((data >> 8) & 0xFF)
        result_.serial  = (uint32_t)(decodeData_ >> 24);
        result_.button  = (decodeData_ >> 16) & 0xFF;
        uint16_t rawCnt = (decodeData_ >> 4) & 0xFFF;
        result_.counter = ((rawCnt & 0x0F) << 8) | ((rawCnt >> 4) & 0xFF);
        result_.crc     = decodeData_ & 0x0F;

        // CRC validation
        uint8_t cntHigh = (result_.counter >> 8) & 0xFF;
        uint8_t offset = 1;
        if (cntHigh == 0 && result_.counter >= 0x098) {
            offset = result_.button;
        }
        uint8_t computed = crc4(decodeData_ >> 4, 53, offset);
        result_.crcValid = (computed == result_.crc);
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPKiaV1)
