#pragma once
/**
 * @file PPSuzuki.h
 * @brief Suzuki key fob protocol decoder/encoder.
 *
 * PWM encoding: te_short=250µs, te_long=500µs, 64-bit, 350-pair preamble.
 * Ported from ProtoPirate suzuki.c
 */

#include "PPProtocol.h"

class PPSuzuki : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Suzuki";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {250, 500, 99, 64};
        return t;
    }

    void reset() override {
        resetDecoder();
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_short) > t.te_delta) return false;
            decodeData_ = 0;
            decodeCountBit_ = 0;
            parserStep_ = StepCountPreamble;
            headerCount_ = 0;
            break;

        case StepCountPreamble:
            if (level) {
                if (headerCount_ >= 300) {
                    if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                        parserStep_ = StepDecodeData;
                        addBit(1);
                    }
                }
            } else {
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    teLast_ = duration;
                    headerCount_++;
                } else {
                    parserStep_ = StepReset;
                }
            }
            break;

        case StepDecodeData:
            if (level) {
                // PWM: short HIGH = 0, long HIGH = 1
                if (duration < t.te_long) {
                    uint32_t diffLong = (t.te_long > duration) ? (t.te_long - duration) : (duration - t.te_long);
                    if (diffLong > t.te_delta) {
                        uint32_t diffShort = DURATION_DIFF(duration, t.te_short);
                        if (diffShort <= t.te_delta) addBit(0);
                    } else {
                        addBit(1);
                    }
                } else {
                    uint32_t diffLong = duration - t.te_long;
                    if (diffLong <= t.te_delta) addBit(1);
                }
            } else {
                // Check for gap (end of frame)
                uint32_t diffGap = DURATION_DIFF(duration, GAP_TIME);
                if (diffGap <= GAP_DELTA) {
                    if (decodeCountBit_ == 64) {
                        return extractData();
                    }
                    parserStep_ = StepReset;
                }
            }
            break;
        }
        return false;
    }

    std::vector<PPPulse> generatePulseData(const PPDecodeResult& r) override {
        std::vector<PPPulse> pulses;
        auto& t = getTiming();

        // Preamble: 350 short HIGH/LOW pairs
        for (int i = 0; i < PREAMBLE_COUNT; i++) {
            pulses.push_back({(int32_t)t.te_short});
            pulses.push_back({-(int32_t)t.te_short});
        }

        // Data bits (MSB first)
        for (int bit = 63; bit >= 0; bit--) {
            if ((r.data >> bit) & 1) {
                pulses.push_back({(int32_t)t.te_long});
            } else {
                pulses.push_back({(int32_t)t.te_short});
            }
            pulses.push_back({-(int32_t)t.te_short});
        }

        // Gap
        pulses.push_back({-(int32_t)GAP_TIME});
        return pulses;
    }

private:
    static constexpr uint32_t PREAMBLE_COUNT = 350;
    static constexpr uint32_t GAP_TIME       = 2000;
    static constexpr uint32_t GAP_DELTA      = 399;

    enum {
        StepReset = 0,
        StepCountPreamble,
        StepDecodeData,
    };

    static const char* getButtonName(uint8_t btn) {
        switch (btn) {
        case 1:  return "Panic";
        case 2:  return "Boot";
        case 3:  return "Lock";
        case 4:  return "Unlock";
        default: return "Unknown";
        }
    }

    bool extractData() {
        result_.data = decodeData_;
        result_.dataBits = 64;
        result_.protocolName = PROTOCOL_NAME;

        uint32_t dataHigh = (uint32_t)(decodeData_ >> 32);
        uint32_t dataLow  = (uint32_t)decodeData_;

        result_.serial  = ((dataHigh & 0xFFF) << 16) | (dataLow >> 16);
        result_.button  = (dataLow >> 12) & 0xF;
        result_.counter = (dataHigh << 4) >> 16;
        result_.crc     = (decodeData_ >> 4) & 0xFF;
        result_.crcValid = true;  // No CRC validation in original
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPSuzuki)
