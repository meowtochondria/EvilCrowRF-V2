#pragma once
/**
 * @file PPKiaV0.h
 * @brief Kia V0 key fob protocol decoder/encoder.
 *
 * PWM encoding: te_short=250µs, te_long=500µs, 61-bit, CRC8 poly 0x7F.
 * Ported from ProtoPirate kia_v0.c
 */

#include "PPProtocol.h"

class PPKiaV0 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Kia V0";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {250, 500, 100, 61};
        return t;
    }

    void reset() override { resetDecoder(); }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_short) > t.te_delta) return false;
            decodeData_ = 0;
            decodeCountBit_ = 0;
            parserStep_ = StepCheckPreamble;
            headerCount_ = 0;
            break;

        case StepCheckPreamble:
            if (level) {
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    headerCount_++;
                } else if (headerCount_ >= 30 &&
                           DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    // Sync long pulse after preamble
                    parserStep_ = StepSaveDuration;
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    // Normal preamble LOW
                } else if (DURATION_DIFF(duration, t.te_long) <= t.te_delta &&
                           headerCount_ >= 30) {
                    // Sync long gap
                    parserStep_ = StepDecodeData;
                } else {
                    parserStep_ = StepReset;
                }
            }
            break;

        case StepSaveDuration:
            if (!level) {
                teLast_ = duration;
                parserStep_ = StepDecodeData;
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepDecodeData:
            if (level) {
                // PWM: short = 0, long = 1
                if (DURATION_DIFF(duration, t.te_short) <= t.te_delta) {
                    addBit(0);
                } else if (DURATION_DIFF(duration, t.te_long) <= t.te_delta) {
                    addBit(1);
                } else {
                    // End of data
                    if (decodeCountBit_ >= t.min_count_bit) {
                        return extractData();
                    }
                    parserStep_ = StepReset;
                }

                if (decodeCountBit_ >= t.min_count_bit) {
                    return extractData();
                }
            } else {
                // LOW pulse — just track duration
                if (duration > t.te_long * 3) {
                    // Long gap = end
                    if (decodeCountBit_ >= t.min_count_bit) {
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

        // Preamble: 32 short pairs
        for (int i = 0; i < 32; i++) {
            pulses.push_back({(int32_t)t.te_short});
            pulses.push_back({-(int32_t)t.te_short});
        }

        // Sync: long HIGH + long LOW
        pulses.push_back({(int32_t)t.te_long});
        pulses.push_back({-(int32_t)t.te_long});

        // Data bits (MSB first, 61 data bits: bit 60 down to 0)
        for (int bit = 60; bit >= 0; bit--) {
            if ((r.data >> bit) & 1) {
                pulses.push_back({(int32_t)t.te_long});
            } else {
                pulses.push_back({(int32_t)t.te_short});
            }
            pulses.push_back({-(int32_t)t.te_short});
        }

        pulses.push_back({-2000});
        return pulses;
    }

private:
    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepSaveDuration,
        StepDecodeData,
    };

    /// CRC8 with polynomial 0x7F
    static uint8_t crc8(uint64_t data, uint8_t startBit, uint8_t endBit) {
        uint8_t crc = 0;
        for (int i = startBit; i >= (int)endBit; i--) {
            uint8_t bit = (data >> i) & 1;
            if ((crc >> 7) ^ bit) {
                crc = (crc << 1) ^ 0x7F;
            } else {
                crc <<= 1;
            }
        }
        return crc;
    }

    bool extractData() {
        result_.data = decodeData_;
        result_.dataBits = decodeCountBit_;
        result_.protocolName = PROTOCOL_NAME;

        // Bit layout (61 bits):
        // [60..57] reserved, [55..40] counter, [39..12] serial, [11..8] button, [7..0] CRC
        result_.counter = (decodeData_ >> 40) & 0xFFFF;
        result_.serial  = (decodeData_ >> 12) & 0x0FFFFFFF;
        result_.button  = (decodeData_ >> 8) & 0x0F;
        result_.crc     = decodeData_ & 0xFF;

        // Validate CRC: computed over bits 8-55 (6 bytes worth)
        uint8_t computed = crc8(decodeData_, 55, 8);
        result_.crcValid = (computed == result_.crc);
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPKiaV0)
