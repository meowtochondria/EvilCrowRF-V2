#pragma once
/**
 * @file PPScherKhan.h
 * @brief Scher-Khan Magicar key fob protocol decoder.
 *
 * PWM: te_short=750µs, te_long=1100µs, variable-length (35-82 bits).
 * No encryption/CRC. Decode only.
 * Ported from ProtoPirate scher_khan.c
 */

#include "PPProtocol.h"

class PPScherKhan : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Scher-Khan";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return false; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {750, 1100, 160, 35};
        return t;
    }

    void reset() override {
        resetDecoder();
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            // Look for preamble: HIGH pulse of te_short*2 (1500µs)
            if (level &&
                DURATION_DIFF(duration, t.te_short * 2) < t.te_delta) {
                parserStep_ = StepCheckPreamble;
                teLast_ = duration;
                headerCount_ = 0;
            }
            break;

        case StepCheckPreamble:
            if (level) {
                // Accept double-short or short HIGH pulses
                if (DURATION_DIFF(duration, t.te_short * 2) < t.te_delta ||
                    DURATION_DIFF(duration, t.te_short) < t.te_delta) {
                    teLast_ = duration;
                } else {
                    parserStep_ = StepReset;
                }
            } else {
                // LOW pulse
                if (DURATION_DIFF(duration, t.te_short * 2) < t.te_delta ||
                    DURATION_DIFF(duration, t.te_short) < t.te_delta) {
                    if (DURATION_DIFF(teLast_, t.te_short * 2) < t.te_delta) {
                        // Found header pair
                        headerCount_++;
                    } else if (DURATION_DIFF(teLast_, t.te_short) < t.te_delta) {
                        // Found start bit
                        if (headerCount_ >= 2) {
                            parserStep_ = StepSaveDuration;
                            decodeData_ = 0;
                            decodeCountBit_ = 1;
                        } else {
                            parserStep_ = StepReset;
                        }
                    } else {
                        parserStep_ = StepReset;
                    }
                } else {
                    parserStep_ = StepReset;
                }
            }
            break;

        case StepSaveDuration:
            if (level) {
                // Stop bit: long HIGH pulse
                if (duration >= (t.te_delta * 2UL + t.te_long)) {
                    parserStep_ = StepReset;
                    if (decodeCountBit_ >= t.min_count_bit) {
                        return extractData();
                    }
                    decodeCountBit_ = 0;
                    decodeData_ = 0;
                } else {
                    teLast_ = duration;
                    parserStep_ = StepCheckDuration;
                }
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepCheckDuration:
            if (!level) {
                if (DURATION_DIFF(teLast_, t.te_short) < t.te_delta &&
                    DURATION_DIFF(duration, t.te_short) < t.te_delta) {
                    addBit(0);
                    parserStep_ = StepSaveDuration;
                } else if (DURATION_DIFF(teLast_, t.te_long) < t.te_delta &&
                           DURATION_DIFF(duration, t.te_long) < t.te_delta) {
                    addBit(1);
                    parserStep_ = StepSaveDuration;
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

    std::vector<PPPulse> generatePulseData(const PPDecodeResult&) override {
        // No encoder for Scher-Khan
        return {};
    }

private:
    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepSaveDuration,
        StepCheckDuration,
    };

    void addBit(uint8_t b) {
        decodeData_ = (decodeData_ << 1) | b;
        decodeCountBit_++;
    }

    bool extractData() {
        // Classify by bit count (like original)
        const char* subType = "Unknown";
        uint32_t serial = 0;
        uint8_t btn = 0;
        uint32_t cnt = 0;

        switch (decodeCountBit_) {
        case 35:
            subType = "MAGIC CODE, Static";
            break;
        case 51:
            subType = "MAGIC CODE, Dynamic";
            serial = ((decodeData_ >> 24) & 0xFFFFFF0) |
                     ((decodeData_ >> 20) & 0x0F);
            btn = (decodeData_ >> 24) & 0x0F;
            cnt = decodeData_ & 0xFFFF;
            break;
        case 57:
            subType = "MAGIC CODE PRO/PRO2";
            break;
        case 63:
            subType = "MAGIC CODE, Response";
            break;
        case 64:
            subType = "MAGICAR, Response";
            break;
        case 81:
        case 82:
            subType = "MAGIC CODE PRO, Response";
            break;
        default:
            break;
        }

        result_.data = decodeData_;
        result_.dataBits = decodeCountBit_;
        result_.protocolName = PROTOCOL_NAME;
        result_.serial = serial;
        result_.button = btn;
        result_.counter = cnt;
        result_.encrypted = false;
        result_.canEmulate = false;
        result_.type = subType;

        return true;
    }
};

PP_REGISTER_PROTOCOL(PPScherKhan)
