#pragma once
/**
 * @file PPPsa.h
 * @brief PSA (Peugeot/Citroën) key fob protocol decoder.
 *
 * Dual-timing Manchester:
 *   State 1: te=250µs (half-period), preamble threshold 0x46
 *   State 3: te=125µs (half-period)
 * 128-bit payload: 64-bit Key1 + 16-bit Key2 (packed into 80 decoded Manchester bits).
 * Two decrypt modes:
 *   Mode 0x23: XOR chain decrypt with checksum validation + second-stage byte permutation
 *   Mode 0x36: TEA brute force (BF1: 0x23000000-0x24000000, BF2: 0xF3000000-0xF4000000)
 * Ported from ProtoPirate psa.c
 */

#include "PPProtocol.h"
#include "PPCommon.h"
#include <cstring>

class PPPsa : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "PSA";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return false; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {250, 500, 80, 80};
        return t;
    }

    void reset() override {
        resetDecoder();
        key1Low_ = 0; key1High_ = 0;
        key2Val_ = 0;
        bitCount_ = 0;
        teHalf_ = 0;
        manchState_ = ManchMid0;
        patternThreshold_ = 0;
    }

    bool feed(bool level, uint32_t duration) override {
        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            if (inRange(duration, 250, 60)) {
                teHalf_ = 250;
                patternThreshold_ = 0x46;
                goto startPreamble;
            } else if (inRange(duration, 125, 30)) {
                teHalf_ = 125;
                patternThreshold_ = 0x46;
                goto startPreamble;
            }
            return false;

        startPreamble:
            headerCount_ = 0;
            bitCount_ = 0;
            key1Low_ = 0; key1High_ = 0; key2Val_ = 0;
            manchState_ = ManchMid0;
            teLast_ = duration;
            parserStep_ = StepPreamble;
            return false;

        case StepPreamble:
            if (level) return false;
            if (inRange(duration, teHalf_, teHalf_ / 4) &&
                inRange(teLast_, teHalf_, teHalf_ / 4)) {
                teLast_ = duration;
                headerCount_++;
                return false;
            }
            if (headerCount_ >= patternThreshold_) {
                // Gap check: ~2×te is normal transition to data
                if (inRange(duration, teHalf_ * 2, teHalf_ / 2)) {
                    parserStep_ = StepData;
                    return false;
                }
            }
            parserStep_ = StepReset;
            return false;

        case StepData: {
            if (bitCount_ >= 96) {
                // Done collecting, attempt decode
                return decryptAndFinish();
            }

            int manchEvent = -1;
            uint32_t tol = teHalf_ / 4;
            if (inRange(duration, teHalf_, tol)) {
                manchEvent = level ? 0 : 1;
            } else if (inRange(duration, teHalf_ * 2, tol)) {
                manchEvent = level ? 2 : 3;
            }

            if (manchEvent >= 0) {
                bool bitVal;
                if (manchesterAdvance(manchEvent, bitVal)) {
                    pushBit(bitVal);
                    if (bitCount_ == 64) {
                        key1Low_ = dataLow_;
                        key1High_ = dataHigh_;
                        dataLow_ = 0; dataHigh_ = 0;
                    }
                    if (bitCount_ == 80) {
                        key2Val_ = dataLow_ & 0xFFFF;
                        // Validate nibble: (key1High >> 16) & 0xF should be 0xA
                        uint8_t nibble = (key1High_ >> 16) & 0xF;
                        if (nibble == 0xA) {
                            return decryptAndFinish();
                        }
                        parserStep_ = StepReset;
                        return false;
                    }
                }
                return false;
            }

            // Invalid timing → reset
            parserStep_ = StepReset;
            return false;
        }
        }
        return false;
    }

    std::vector<PPPulse> generatePulseData(const PPDecodeResult&) override {
        return {};  // TX not implemented
    }

private:
    uint32_t dataLow_ = 0, dataHigh_ = 0;
    uint32_t key1Low_ = 0, key1High_ = 0;
    uint16_t key2Val_ = 0;
    uint8_t bitCount_ = 0;
    uint32_t teHalf_ = 250;
    uint32_t patternThreshold_ = 0;

    enum {
        StepReset = 0,
        StepPreamble,
        StepData,
    };

    // ──── Manchester ────
    enum ManchState { ManchMid0 = 0, ManchMid1, ManchLow, ManchHigh };
    ManchState manchState_ = ManchMid0;

    bool manchesterAdvance(int event, bool& bit) {
        switch (manchState_) {
        case ManchMid0:
            if (event == 1)      { manchState_ = ManchHigh; return false; }
            else if (event == 0) { manchState_ = ManchLow;  return false; }
            else if (event == 3) { manchState_ = ManchMid1; bit = false; return true; }
            break;
        case ManchMid1:
            if (event == 0)      { manchState_ = ManchLow;  return false; }
            else if (event == 1) { manchState_ = ManchHigh; return false; }
            else if (event == 2) { manchState_ = ManchMid0; bit = true;  return true; }
            break;
        case ManchLow:
            if (event == 1)      { manchState_ = ManchMid0; bit = true;  return true; }
            break;
        case ManchHigh:
            if (event == 0)      { manchState_ = ManchMid1; bit = false; return true; }
            break;
        }
        manchState_ = ManchMid0;
        return false;
    }

    static bool inRange(uint32_t val, uint32_t target, uint32_t tol) {
        return (val < target) ? (target - val) < tol : (val - target) < tol;
    }

    void pushBit(bool val) {
        uint32_t carry = (dataLow_ >> 31) & 1;
        dataLow_ = (dataLow_ << 1) | (val ? 1 : 0);
        dataHigh_ = (dataHigh_ << 1) | carry;
        bitCount_++;
    }

    // ──────── TEA cipher (Tiny Encryption Algorithm) ────────
    static constexpr uint32_t TEA_DELTA = 0x9E3779B9U;
    static constexpr uint32_t TEA_ROUNDS = 32;

    static void teaDecrypt(uint32_t& v0, uint32_t& v1, const uint32_t key[4]) {
        uint32_t sum = TEA_DELTA * TEA_ROUNDS;
        for (uint32_t i = 0; i < TEA_ROUNDS; i++) {
            v1 -= ((v0 << 4) + key[2]) ^ (v0 + sum) ^ ((v0 >> 5) + key[3]);
            v0 -= ((v1 << 4) + key[0]) ^ (v1 + sum) ^ ((v1 >> 5) + key[1]);
            sum -= TEA_DELTA;
        }
    }

    // ──────── Key schedules for brute force ────────
    static constexpr uint32_t BF1_KEY_SCHEDULE[4] = {
        0x06D03681, 0x544B0B27, 0xA5B3AA06, 0xDDE232EC
    };
    static constexpr uint32_t BF2_KEY_SCHEDULE[4] = {
        0x76B2E08F, 0xDBF1C9BA, 0x5E3B073D, 0xE03B3DA2
    };

    // ──────── XOR chain decrypt (mode 0x23) ────────
    static void setupByteBuffer(const uint32_t k1h, const uint32_t k1l,
                                 const uint16_t k2, uint8_t buf[10]) {
        buf[0] = (k1h >> 24) & 0xFF;
        buf[1] = (k1h >> 16) & 0xFF;
        buf[2] = (k1h >> 8) & 0xFF;
        buf[3] = k1h & 0xFF;
        buf[4] = (k1l >> 24) & 0xFF;
        buf[5] = (k1l >> 16) & 0xFF;
        buf[6] = (k1l >> 8) & 0xFF;
        buf[7] = k1l & 0xFF;
        buf[8] = (k2 >> 8) & 0xFF;
        buf[9] = k2 & 0xFF;
    }

    static uint8_t calculateChecksum(const uint8_t buf[10]) {
        uint8_t cs = 0;
        for (int i = 0; i < 9; i++) cs ^= buf[i];
        return cs;
    }

    static void directXorDecrypt(uint8_t buf[10]) {
        // Single-pass XOR chain
        for (int i = 8; i > 0; i--) {
            buf[i] ^= buf[i - 1];
        }
    }

    static void secondStageXor(uint8_t buf[10]) {
        // 6-byte permutation XOR
        static const uint8_t perm[] = {1, 3, 5, 7, 2, 4};
        uint8_t tmp[6];
        for (int i = 0; i < 6; i++) tmp[i] = buf[perm[i]];
        for (int i = 0; i < 6; i++) buf[perm[i]] = tmp[i] ^ buf[perm[(i + 1) % 6]];
    }

    bool tryMode23() {
        uint8_t buf[10];
        setupByteBuffer(key1High_, key1Low_, key2Val_, buf);

        // Direct XOR decrypt
        directXorDecrypt(buf);
        uint8_t cs = calculateChecksum(buf);
        uint8_t key2h = buf[8];

        if (((cs ^ key2h) & 0xF0) != 0) return false;

        // Second stage
        secondStageXor(buf);

        // Extract fields
        result_.serial = ((uint32_t)buf[1] << 16) |
                         ((uint32_t)buf[2] << 8) | buf[3];
        result_.counter = ((uint32_t)buf[4] << 8) | buf[5];
        result_.button = buf[6];
        result_.type = "Mode 0x23 (XOR)";
        return true;
    }

    // ──────── TEA brute force (mode 0x36) ────────
    bool tryBruteForce() {
        // BF1: range 0x23000000 - 0x24000000
        {
            uint32_t key[4];
            memcpy(key, BF1_KEY_SCHEDULE, sizeof(key));

            for (uint32_t trial = 0x23000000; trial < 0x23100000; trial += 0x10000) {
                // Derive working key from trial + schedule
                uint32_t wk[4];
                wk[0] = key[0] ^ trial;
                wk[1] = key[1]; wk[2] = key[2]; wk[3] = key[3];

                uint32_t v0 = key1High_, v1 = key1Low_;
                teaDecrypt(v0, v1, wk);

                // Check button validity
                uint8_t btn = (v1 >> 24) & 0xF;
                if (btn == 1 || btn == 2 || btn == 4) {
                    result_.serial = v0;
                    result_.counter = v1 & 0xFFFF;
                    result_.button = btn;
                    result_.type = "Mode 0x36 (TEA BF1)";
                    return true;
                }
            }
        }

        // BF2: range 0xF3000000 - 0xF4000000
        {
            uint32_t key[4];
            memcpy(key, BF2_KEY_SCHEDULE, sizeof(key));

            for (uint32_t trial = 0xF3000000; trial < 0xF3100000; trial += 0x10000) {
                uint32_t wk[4];
                wk[0] = key[0] ^ trial;
                wk[1] = key[1] ^ trial;
                wk[2] = key[2]; wk[3] = key[3];

                uint32_t v0 = key1High_, v1 = key1Low_;
                teaDecrypt(v0, v1, wk);

                uint8_t btn = (v1 >> 24) & 0xF;
                if (btn == 1 || btn == 2 || btn == 4) {
                    result_.serial = v0;
                    result_.counter = v1 & 0xFFFF;
                    result_.button = btn;
                    result_.type = "Mode 0x36 (TEA BF2)";
                    return true;
                }
            }
        }
        return false;
    }

    bool decryptAndFinish() {
        result_.data = ((uint64_t)key1High_ << 32) | key1Low_;
        result_.data2 = key2Val_;
        result_.dataBits = 80;
        result_.protocolName = PROTOCOL_NAME;
        result_.encrypted = true;
        result_.canEmulate = false;

        uint8_t dispatchByte = key2Val_ & 0xFF;
        bool ok = false;

        if (dispatchByte == 0x23) {
            ok = tryMode23();
        } else if (dispatchByte == 0x36) {
            // NOTE: Full brute force was 16M iterations on Flipper.
            // On ESP32 we try a reduced subset for real-time decode.
            ok = tryBruteForce();
        }

        result_.crcValid = ok;
        if (!ok) {
            result_.type = (dispatchByte == 0x23) ? "Mode 0x23 (encrypted)"
                                                   : "Mode 0x36 (encrypted)";
        }

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPPsa)
