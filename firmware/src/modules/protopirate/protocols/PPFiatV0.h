#pragma once
/**
 * @file PPFiatV0.h
 * @brief Fiat V0 key fob protocol decoder/encoder.
 *
 * Differential Manchester encoding: te_short=200µs, te_long=400µs, 64+6 bit.
 * Ported from ProtoPirate fiat_v0.c
 */

#include "PPProtocol.h"

class PPFiatV0 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Fiat V0";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {200, 400, 100, 64};
        return t;
    }

    void reset() override {
        resetDecoder();
        btnBits_ = 0;
        btnCount_ = 0;
        prevBit_ = 0;
        phase_ = 0;
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_short) > t.te_delta) return false;
            parserStep_ = StepCountPreamble;
            headerCount_ = 1;
            decodeData_ = 0;
            decodeCountBit_ = 0;
            btnBits_ = 0;
            btnCount_ = 0;
            break;

        case StepCountPreamble:
            if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                headerCount_++;
            } else if (headerCount_ >= 140) {
                // Look for gap (~800µs) marking end of preamble
                if (!level && DURATION_DIFF(duration, GAP_TIME) <= GAP_DELTA) {
                    parserStep_ = StepDecodeData;
                    prevBit_ = 0;
                    phase_ = 0;
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepDecodeData: {
            bool isShort = DURATION_DIFF(duration, t.te_short) <= t.te_delta;
            bool isLong  = DURATION_DIFF(duration, t.te_long) <= t.te_delta;

            if (isLong) {
                // Long pulse = transition = bit change
                prevBit_ = 1 - prevBit_;
                if (decodeCountBit_ < 64) {
                    addBit(prevBit_);
                } else {
                    btnBits_ = (btnBits_ << 1) | prevBit_;
                    btnCount_++;
                }
            } else if (isShort) {
                if (phase_ == 0) {
                    phase_ = 1;
                } else {
                    // Two shorts = no transition = same bit
                    if (decodeCountBit_ < 64) {
                        addBit(prevBit_);
                    } else {
                        btnBits_ = (btnBits_ << 1) | prevBit_;
                        btnCount_++;
                    }
                    phase_ = 0;
                }
            } else {
                // Invalid or end of frame
                if (decodeCountBit_ >= 64) {
                    return extractData();
                }
                parserStep_ = StepReset;
                return false;
            }

            if (decodeCountBit_ >= 64 && btnCount_ >= 6) {
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

        // Preamble: 150 short pairs
        for (int i = 0; i < 150; i++) {
            pulses.push_back({(int32_t)t.te_short});
            pulses.push_back({-(int32_t)t.te_short});
        }

        // Gap
        pulses.push_back({-(int32_t)GAP_TIME});

        // Differential Manchester encode (64 data bits + 6 button bits)
        uint8_t prev = 0;
        auto encodeBit = [&](uint8_t bit) {
            if (bit != prev) {
                // Transition: long pulse
                pulses.push_back({bit ? (int32_t)t.te_long : -(int32_t)t.te_long});
            } else {
                // No transition: two short pulses
                pulses.push_back({prev ? (int32_t)t.te_short : -(int32_t)t.te_short});
                pulses.push_back({prev ? (int32_t)t.te_short : -(int32_t)t.te_short});
            }
            prev = bit;
        };

        for (int i = 63; i >= 0; i--) encodeBit((r.data >> i) & 1);
        uint8_t btnToSend = r.button >> 1;
        for (int i = 5; i >= 0; i--) encodeBit((btnToSend >> i) & 1);

        pulses.push_back({-2000});
        return pulses;
    }

private:
    uint8_t btnBits_ = 0;
    uint8_t btnCount_ = 0;
    uint8_t prevBit_ = 0;
    uint8_t phase_ = 0;

    static constexpr uint32_t GAP_TIME  = 800;
    static constexpr uint32_t GAP_DELTA = 200;

    enum {
        StepReset = 0,
        StepCountPreamble,
        StepDecodeData,
    };

    bool extractData() {
        result_.data = decodeData_;
        result_.dataBits = 64;
        result_.protocolName = PROTOCOL_NAME;

        // data = (cnt << 32) | serial
        result_.serial  = (uint32_t)(decodeData_ & 0xFFFFFFFF);
        result_.counter = (uint32_t)(decodeData_ >> 32);
        result_.button  = (btnBits_ << 1) | 1;  // Button fixup from original
        result_.crc = 0;
        result_.crcValid = true;
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPFiatV0)
