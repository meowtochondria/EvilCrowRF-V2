#pragma once
/**
 * @file PPFordV0.h
 * @brief Ford V0 key fob protocol decoder/encoder.
 *
 * Differential Manchester: te_short=250µs, te_long=500µs, 64-bit.
 * GF(2) matrix CRC, BS calculation, XOR obfuscation.
 * Ported from ProtoPirate ford_v0.c
 */

#include "PPProtocol.h"

class PPFordV0 : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "Ford V0";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {250, 500, 100, 64};
        return t;
    }

    void reset() override {
        resetDecoder();
        key1_ = 0;
        key2_ = 0;
        key1Bits_ = 0;
        key2Bits_ = 0;
        prevBit_ = 0;
        phase_ = 0;
        burstCount_ = 0;
        collectingKey2_ = false;
    }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (DURATION_DIFF(duration, t.te_long * 2) > t.te_delta * 2) return false;
            parserStep_ = StepCheckPreamble;
            headerCount_ = 1;
            key1_ = 0; key2_ = 0;
            key1Bits_ = 0; key2Bits_ = 0;
            collectingKey2_ = false;
            break;

        case StepCheckPreamble:
            if (DURATION_DIFF(duration, t.te_long * 2) <= t.te_delta * 2) {
                headerCount_++;
                if (headerCount_ >= 4) {
                    parserStep_ = StepWaitSync;
                }
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepWaitSync:
            if (!level && duration > 3000 && duration < 4000) {
                // 3500µs gap = sync
                parserStep_ = StepDecodeKey1;
                key1Bits_ = 0;
                key1_ = 0;
                prevBit_ = 0;
                phase_ = 0;
            } else {
                parserStep_ = StepReset;
            }
            break;

        case StepDecodeKey1: {
            bool isShort = DURATION_DIFF(duration, t.te_short) <= t.te_delta;
            bool isLong  = DURATION_DIFF(duration, t.te_long) <= t.te_delta;

            if (isLong) {
                prevBit_ = 1 - prevBit_;
                key1_ = (key1_ << 1) | prevBit_;
                key1Bits_++;
            } else if (isShort) {
                if (phase_ == 0) {
                    phase_ = 1;
                } else {
                    key1_ = (key1_ << 1) | prevBit_;
                    key1Bits_++;
                    phase_ = 0;
                }
            } else {
                if (key1Bits_ >= 63) {
                    parserStep_ = StepDecodeKey2;
                    key2Bits_ = 0;
                    key2_ = 0;
                    phase_ = 0;
                } else {
                    parserStep_ = StepReset;
                }
                return false;
            }

            if (key1Bits_ >= 63) {
                parserStep_ = StepDecodeKey2;
                key2Bits_ = 0;
                key2_ = 0;
            }
            break;
        }

        case StepDecodeKey2: {
            bool isShort = DURATION_DIFF(duration, t.te_short) <= t.te_delta;
            bool isLong  = DURATION_DIFF(duration, t.te_long) <= t.te_delta;

            if (isLong) {
                prevBit_ = 1 - prevBit_;
                key2_ = (key2_ << 1) | prevBit_;
                key2Bits_++;
            } else if (isShort) {
                if (phase_ == 0) {
                    phase_ = 1;
                } else {
                    key2_ = (key2_ << 1) | prevBit_;
                    key2Bits_++;
                    phase_ = 0;
                }
            } else {
                if (key2Bits_ >= 16) {
                    return decodeFord();
                }
                parserStep_ = StepReset;
                return false;
            }

            if (key2Bits_ >= 16) {
                return decodeFord();
            }
            break;
        }
        }
        return false;
    }

    std::vector<PPPulse> generatePulseData(const PPDecodeResult& r) override {
        std::vector<PPPulse> pulses;
        auto& t = getTiming();

        // 4 preamble long-pulse pairs
        for (int i = 0; i < 4; i++) {
            pulses.push_back({(int32_t)(t.te_long * 2)});
            pulses.push_back({-(int32_t)(t.te_long * 2)});
        }

        // Short + gap
        pulses.push_back({(int32_t)t.te_short});
        pulses.push_back({-3500});

        // Encode key1 (63 bits) + key2 (16 bits) differential Manchester
        uint8_t prev = 0;
        auto encodeBit = [&](uint8_t bit) {
            if (bit != prev) {
                pulses.push_back({bit ? (int32_t)t.te_long : -(int32_t)t.te_long});
            } else {
                pulses.push_back({prev ? (int32_t)t.te_short : -(int32_t)t.te_short});
                pulses.push_back({prev ? (int32_t)t.te_short : -(int32_t)t.te_short});
            }
            prev = bit;
        };

        for (int i = 62; i >= 0; i--) encodeBit((r.data >> i) & 1);
        for (int i = 15; i >= 0; i--) encodeBit((r.data2 >> i) & 1);

        pulses.push_back({-4000});
        return pulses;
    }

private:
    uint64_t key1_ = 0;
    uint16_t key2_ = 0;
    uint16_t key1Bits_ = 0;
    uint16_t key2Bits_ = 0;
    uint8_t prevBit_ = 0;
    uint8_t phase_ = 0;
    uint8_t burstCount_ = 0;
    bool collectingKey2_ = false;

    enum {
        StepReset = 0,
        StepCheckPreamble,
        StepWaitSync,
        StepDecodeKey1,
        StepDecodeKey2,
    };

    /// GF(2) CRC matrix (64 bytes, exact values from original ford_v0.c)
    static constexpr uint8_t CRC_MATRIX[64] = {
        0xDA, 0xB5, 0x55, 0x6A, 0xAA, 0xAA, 0xAA, 0xD5,
        0xB6, 0x6C, 0xCC, 0xD9, 0x99, 0x99, 0x99, 0xB3,
        0x71, 0xE3, 0xC3, 0xC7, 0x87, 0x87, 0x87, 0x8F,
        0x0F, 0xE0, 0x3F, 0xC0, 0x7F, 0x80, 0x7F, 0x80,
        0x00, 0x1F, 0xFF, 0xC0, 0x00, 0x7F, 0xFF, 0x80,
        0x00, 0x00, 0x00, 0x3F, 0xFF, 0xFF, 0xFF, 0x80,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7F,
        0x23, 0x12, 0x94, 0x84, 0x35, 0xF4, 0x55, 0x84,
    };

    static uint8_t popcount8(uint8_t x) {
        uint8_t count = 0;
        while (x) { count += x & 1; x >>= 1; }
        return count;
    }

    /// Compute GF(2) matrix CRC (exact port of ford_v0_calculate_crc)
    /// @param buf  buffer; CRC is computed over buf[1..8]
    static uint8_t computeCrc(const uint8_t* buf) {
        uint8_t crc = 0;
        for (int row = 0; row < 8; row++) {
            uint8_t xor_sum = 0;
            for (int col = 0; col < 8; col++) {
                xor_sum ^= (CRC_MATRIX[row * 8 + col] & buf[col + 1]);
            }
            if (popcount8(xor_sum) & 1) {
                crc |= (1 << row);
            }
        }
        return crc;
    }

    /// Verify CRC (exact port of ford_v0_verify_crc)
    static bool verifyCrc(uint64_t key1, uint16_t key2) {
        uint8_t buf[16] = {0};
        for (int i = 0; i < 8; ++i) {
            buf[i] = (uint8_t)(key1 >> (56 - i * 8));
        }
        buf[8] = (uint8_t)(key2 >> 8);

        uint8_t calculated = computeCrc(buf);
        uint8_t received   = (uint8_t)(key2 & 0xFF) ^ 0x80;
        return (calculated == received);
    }

    /// Decode Ford V0 (exact port of decode_ford_v0)
    bool decodeFord() {
        uint8_t buf[13] = {0};

        // Unpack key1 big-endian (NO inversion)
        for (int i = 0; i < 8; ++i) {
            buf[i] = (uint8_t)(key1_ >> (56 - i * 8));
        }
        buf[8] = (uint8_t)(key2_ >> 8);   // BS byte
        buf[9] = (uint8_t)(key2_ & 0xFF); // CRC byte

        // BS parity calculation
        uint8_t tmp = buf[8];
        uint8_t bs  = tmp;
        uint8_t parity = 0;
        uint8_t parity_any = (tmp != 0);
        while (tmp) {
            parity ^= (tmp & 1);
            tmp >>= 1;
        }
        buf[11] = parity_any ? parity : 0;

        // XOR deobfuscation (conditional byte and limit)
        uint8_t xor_byte;
        uint8_t limit;
        if (buf[11]) {
            xor_byte = buf[7];
            limit = 7;
        } else {
            xor_byte = buf[6];
            limit = 6;
        }

        for (int idx = 1; idx < limit; ++idx) {
            buf[idx] ^= xor_byte;
        }

        if (buf[11] == 0) {
            buf[7] ^= xor_byte;
        }

        // Mixed byte swap (buf[6] ↔ buf[7] interleaved)
        uint8_t orig_b7 = buf[7];
        buf[7]  = (orig_b7 & 0xAA)  | (buf[6] & 0x55);
        uint8_t mixed = (buf[6] & 0xAA) | (orig_b7 & 0x55);
        buf[12] = mixed;
        buf[6]  = mixed;

        // Serial: 32-bit from buf[1..4] (LE read → byte-swap to BE)
        uint32_t serial_le = ((uint32_t)buf[1]) |
                             ((uint32_t)buf[2] << 8) |
                             ((uint32_t)buf[3] << 16) |
                             ((uint32_t)buf[4] << 24);
        uint32_t serial = ((serial_le & 0xFF) << 24) |
                          (((serial_le >> 8)  & 0xFF) << 16) |
                          (((serial_le >> 16) & 0xFF) << 8) |
                          ((serial_le >> 24) & 0xFF);

        // Button: high nibble of buf[5]
        uint8_t button = (buf[5] >> 4) & 0x0F;

        // Counter: 20-bit from buf[5..7]
        uint32_t counter = ((uint32_t)(buf[5] & 0x0F) << 16) |
                           ((uint32_t)buf[6] << 8) |
                           buf[7];

        // BS magic
        uint8_t bsMagic = bs + ((bs & 0x80) ? 0x80 : 0) -
                          (button << 4) - (uint8_t)(counter & 0xFF);

        // CRC verification
        bool crcValid = verifyCrc(key1_, key2_);

        result_.data = key1_;
        result_.data2 = key2_;
        result_.dataBits = 64;
        result_.protocolName = PROTOCOL_NAME;
        result_.serial = serial;
        result_.button = button;
        result_.counter = counter;
        result_.bsMagic = bsMagic;
        result_.crc = (uint8_t)(key2_ & 0xFF);
        result_.crcValid = crcValid;
        result_.canEmulate = true;
        result_.encrypted = false;

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPFordV0)
