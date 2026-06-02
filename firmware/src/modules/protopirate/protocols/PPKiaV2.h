#pragma once
/**
 * @file PPKiaV2.h
 * @brief Kia V2 key fob protocol decoder/encoder.
 *
 * Manchester encoding: te_short=500µs, te_long=1000µs, 53-bit, CRC4.
 * Ported from ProtoPirate kia_v2.c
 */

#include "PPProtocol.h"

class PPKiaV2 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Kia V2";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {500, 1000, 150, 51};
        return t;
    }

    void reset() override {
        resetDecoder();
        manchesterState_ = 0;
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
            } else if (headerCount_ >= 100 &&
                       DURATION_DIFF(duration, t.te_short) <= t.te_delta && level) {
                parserStep_ = StepCollectRawBits;
                addBit(1);
                manchesterState_ = 1;
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepCollectRawBits: {
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
                if (decodeCountBit_ >= t.min_count_bit) {
                    return extractData();
                }
                parserStep_ = StepReset;
                return false;
            }

            if (decodeCountBit_ >= 53) {
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

        // Preamble: 120 long pairs
        for (int i = 0; i < 120; i++) {
            pulses.push_back({(int32_t)t.te_long});
            pulses.push_back({-(int32_t)t.te_long});
        }

        // Manchester encode
        for (int bit = 52; bit >= 0; bit--) {
            bool val = (r.data >> bit) & 1;
            if (val) {
                pulses.push_back({(int32_t)t.te_short});
                pulses.push_back({-(int32_t)t.te_short});
            } else {
                pulses.push_back({-(int32_t)t.te_short});
                pulses.push_back({(int32_t)t.te_short});
            }
        }

        pulses.push_back({-3000});
        return pulses;
    }

private:
    uint8_t manchesterState_ = 0;
    bool halfPulse_ = false;

    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepCollectRawBits,
    };

    /// CRC4 for Kia V2: XOR all nibbles of data bytes, then +1, mask to 4 bits
    static uint8_t crc4(uint64_t data) {
        uint8_t crc = 0;
        // Process 7 bytes (56 bits covers the 53-bit data with padding)
        for (int i = 0; i < 7; i++) {
            uint8_t b = (uint8_t)(data >> (i * 8));
            crc ^= (b & 0x0F) ^ (b >> 4);
        }
        return (crc + 1) & 0x0F;
    }

    bool extractData() {
        result_.data = decodeData_;
        result_.dataBits = decodeCountBit_;
        result_.protocolName = PROTOCOL_NAME;

        // Data extraction:
        // serial = (data >> 20), btn = (data >> 16) & 0x0F
        // raw_count = (data >> 4) & 0xFFF
        // cnt = ((raw_count >> 4) | (raw_count << 8)) & 0xFFF
        result_.serial = (uint32_t)(decodeData_ >> 20);
        result_.button = (decodeData_ >> 16) & 0x0F;
        uint16_t rawCount = (decodeData_ >> 4) & 0xFFF;
        result_.counter = ((rawCount >> 4) | (rawCount << 8)) & 0xFFF;
        result_.crc = decodeData_ & 0x0F;

        // CRC validation
        uint8_t computed = crc4(decodeData_ >> 4);
        result_.crcValid = (computed == result_.crc);
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPKiaV2)
