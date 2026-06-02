#pragma once
/**
 * @file PPVag.h
 * @brief VAG (VW/Audi/Seat/Skoda) key fob protocol decoder.
 *
 * Two preamble patterns:
 *   Type 1/2: Manchester 300µs half-period, 200+ header pairs, inverted data
 *   Type 3/4: Manchester 500µs half-period, 40+ header pairs, sync sequence
 * 80-bit payload (64-bit Key1 + 16-bit Key2).
 * Encryption: AUT64 (types 1/3/4), XTEA (type 2).
 * Ported from ProtoPirate vag.c
 */

#include "PPProtocol.h"
#include "PPCommon.h"
#include "Aut64Cipher.h"
#include <cstring>

class PPVag : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "VAG";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return false; }  // Emulation behind feature flag

    const PPTimingConst& getTiming() const override {
        // Type 3/4 timing; type 1/2 uses 300µs internally
        static const PPTimingConst t = {500, 1000, 80, 80};
        return t;
    }

    void reset() override {
        resetDecoder();
        dataLow_ = 0;  dataHigh_ = 0;
        bitCount_ = 0;
        key1Low_ = 0;  key1High_ = 0;
        key2Low_ = 0;
        vagType_ = 0;
        midCount_ = 0;
        manchState_ = ManchMid0;
    }

    /**
     * @brief Set AUT64 keys for VAG decryption.
     * @param index Key index (0-2)
     * @param key   AUT64 key struct
     */
    static void setAut64Key(uint8_t index, const aut64::Key& key) {
        if (index < 3) {
            aut64Keys_[index] = key;
            aut64KeysLoaded_ = true;
        }
    }

    bool feed(bool level, uint32_t duration) override {
        uint32_t diff;

        switch (parserStep_) {
        case StepReset:
            if (!level) return false;
            // Detect preamble start: ~300µs HIGH → type 1/2, ~500µs → type 3/4
            if (inRange(duration, 300, 79)) {
                parserStep_ = StepPreamble1;
                goto initCommon;
            } else if (inRange(duration, 500, 79)) {
                parserStep_ = StepPreamble2;
                goto initCommon;
            }
            return false;

        initCommon:
            dataLow_ = 0; dataHigh_ = 0;
            headerCount_ = 0; midCount_ = 0;
            bitCount_ = 0; vagType_ = 0;
            teLast_ = duration;
            manchState_ = ManchMid0;
            return false;

        // ──────── TYPE 1/2: 300µs preamble ────────
        case StepPreamble1:
            if (level) return false;
            if (inRange(duration, 300, 79)) {
                // Check previous was also ~300µs
                if (inRange(teLast_, 300, 79)) {
                    teLast_ = duration;
                    headerCount_++;
                    return false;
                }
            }
            // Check for gap (~600µs) after sufficient preamble
            if (headerCount_ >= 201) {
                if (inRange(duration, 600, 79) && inRange(teLast_, 300, 79)) {
                    parserStep_ = StepData1;
                    return false;
                }
            }
            parserStep_ = StepReset;
            return false;

        case StepData1: {
            if (bitCount_ < 96) {
                int manchEvent = -1;
                if (inRange(duration, 300, 79)) {
                    manchEvent = level ? 0 : 1;  // ShortLow : ShortHigh
                } else if (inRange(duration, 600, 79)) {
                    manchEvent = level ? 2 : 3;  // LongLow : LongHigh
                }

                if (manchEvent >= 0) {
                    bool bitVal;
                    if (manchesterAdvance(manchEvent, bitVal)) {
                        pushBit(bitVal);
                        // After 15 bits, check for type prefix
                        if (bitCount_ == 15) {
                            if (dataLow_ == 0x2F3F && dataHigh_ == 0) {
                                dataLow_ = 0; dataHigh_ = 0;
                                bitCount_ = 0; vagType_ = 1;
                            } else if (dataLow_ == 0x2F1C && dataHigh_ == 0) {
                                dataLow_ = 0; dataHigh_ = 0;
                                bitCount_ = 0; vagType_ = 2;
                            }
                        } else if (bitCount_ == 64) {
                            key1Low_ = ~dataLow_;
                            key1High_ = ~dataHigh_;
                            dataLow_ = 0; dataHigh_ = 0;
                        }
                    }
                    return false;
                }
            }

            // Gap check (reached when bitCount >= 96 or invalid manchester event)
            if (level) return false;
            diff = (duration < 6000) ? (6000 - duration) : (duration - 6000);
            if (diff < 4000 && bitCount_ == 80) {
                key2Low_ = (~dataLow_) & 0xFFFF;
                return decodeVag();
            }
            dataLow_ = 0; dataHigh_ = 0;
            bitCount_ = 0;
            parserStep_ = StepReset;
            return false;
        }

        // ──────── TYPE 3/4: 500µs preamble ────────
        case StepPreamble2:
            if (!level) {
                if (inRange(duration, 500, 79) && inRange(teLast_, 500, 79)) {
                    teLast_ = duration;
                    headerCount_++;
                    return false;
                }
                parserStep_ = StepReset;
                return false;
            }
            if (headerCount_ < 41) return false;
            if (inRange(duration, 1000, 79) && inRange(teLast_, 500, 79)) {
                teLast_ = duration;
                parserStep_ = StepSync2A;
            }
            return false;

        case StepSync2A:
            if (!level && inRange(duration, 500, 79) &&
                inRange(teLast_, 1000, 79)) {
                teLast_ = duration;
                parserStep_ = StepSync2B;
            } else {
                parserStep_ = StepReset;
            }
            return false;

        case StepSync2B:
            if (level && inRange(duration, 750, 79)) {
                teLast_ = duration;
                parserStep_ = StepSync2C;
            } else {
                parserStep_ = StepReset;
            }
            return false;

        case StepSync2C:
            if (!level && inRange(duration, 750, 79) &&
                inRange(teLast_, 750, 79)) {
                midCount_++;
                parserStep_ = StepSync2B;
                if (midCount_ == 3) {
                    dataLow_ = 1; dataHigh_ = 0;
                    bitCount_ = 1;
                    manchState_ = ManchMid0;
                    parserStep_ = StepData2;
                }
            } else {
                parserStep_ = StepReset;
            }
            return false;

        case StepData2: {
            int manchEvent = -1;
            if (duration >= 380 && duration <= 620) {
                manchEvent = level ? 0 : 1;
            } else if (duration >= 880 && duration <= 1120) {
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
                }
            }

            if (bitCount_ == 80) {
                key2Low_ = dataLow_ & 0xFFFF;
                vagType_ = 3;
                bool ok = decodeVag();
                dataLow_ = 0; dataHigh_ = 0;
                bitCount_ = 0;
                parserStep_ = StepReset;
                return ok;
            }
            return false;
        }
        }
        return false;
    }

    std::vector<PPPulse> generatePulseData(const PPDecodeResult&) override {
        return {};  // TX behind feature flag
    }

private:
    uint32_t dataLow_ = 0, dataHigh_ = 0;
    uint8_t bitCount_ = 0;
    uint32_t key1Low_ = 0, key1High_ = 0;
    uint32_t key2Low_ = 0;
    uint8_t vagType_ = 0;
    uint8_t midCount_ = 0;

    enum {
        StepReset = 0,
        StepPreamble1, StepData1,
        StepPreamble2, StepSync2A, StepSync2B, StepSync2C, StepData2,
    };

    // ──── Simple Manchester state machine ────
    enum ManchState { ManchMid0 = 0, ManchMid1, ManchLow, ManchHigh };
    ManchState manchState_ = ManchMid0;

    bool manchesterAdvance(int event, bool& bit) {
        // event: 0=ShortLow, 1=ShortHigh, 2=LongLow, 3=LongHigh
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

    // ──── XTEA decrypt (VAG type 2) ────
    static constexpr uint32_t TEA_DELTA = 0x9E3779B9U;
    static constexpr uint32_t TEA_ROUNDS = 32;
    static constexpr uint32_t TEA_KEY[4] = {
        0x0B46502D, 0x5E253718, 0x2BF93A19, 0x622C1206
    };

    static void teaDecrypt(uint32_t& v0, uint32_t& v1) {
        uint32_t sum = TEA_DELTA * TEA_ROUNDS;
        for (int i = 0; i < (int)TEA_ROUNDS; i++) {
            v1 -= (((v0 << 4) ^ (v0 >> 5)) + v0) ^
                  (sum + TEA_KEY[(sum >> 11) & 3]);
            sum -= TEA_DELTA;
            v0 -= (((v1 << 4) ^ (v1 >> 5)) + v1) ^
                  (sum + TEA_KEY[sum & 3]);
        }
    }

    // ──── AUT64 keys ────
    static inline aut64::Key aut64Keys_[3] = {};
    static inline bool aut64KeysLoaded_ = false;

    static bool aut64Decrypt(uint8_t* block, int keyIdx) {
        if (!aut64KeysLoaded_ || keyIdx < 0 || keyIdx > 2) return false;
        aut64::decrypt(aut64Keys_[keyIdx], block);
        return true;
    }

    static bool buttonValid(const uint8_t* dec) {
        uint8_t b = (dec[7] >> 4) & 0xF;
        return (b == 1 || b == 2 || b == 4 || dec[7] == 0);
    }

    // ──── Vehicle name from type byte ────
    static const char* vehicleName(uint8_t typeByte) {
        switch (typeByte) {
        case 0x00: return "VW Passat";
        case 0xC0: return "VW";
        case 0xC1: return "Audi";
        case 0xC2: return "Seat";
        case 0xC3: return "Skoda";
        default:   return "VAG";
        }
    }

    static const char* buttonName(uint8_t btn) {
        switch (btn) {
        case 0x01: case 0x10: return "Unlock";
        case 0x02: case 0x20: return "Lock";
        case 0x04: case 0x40: return "Boot";
        default: return "Unknown";
        }
    }

    void fillFromDecrypted(const uint8_t* dec, uint8_t dispatchByte) {
        // Serial: reverse byte order of bytes [0..3]
        uint32_t sr = (uint32_t)dec[0] | ((uint32_t)dec[1] << 8) |
                      ((uint32_t)dec[2] << 16) | ((uint32_t)dec[3] << 24);
        result_.serial = (sr << 24) | ((sr & 0xFF00) << 8) |
                         ((sr >> 8) & 0xFF00) | (sr >> 24);
        result_.counter = (uint32_t)dec[4] | ((uint32_t)dec[5] << 8) |
                          ((uint32_t)dec[6] << 16);
        result_.button = (dec[7] >> 4) & 0xF;
    }

    bool decodeVag() {
        uint8_t dispatchByte = (uint8_t)(key2Low_ & 0xFF);
        uint8_t key2High = (uint8_t)((key2Low_ >> 8) & 0xFF);

        // Build key1 bytes
        uint8_t key1Bytes[8];
        key1Bytes[0] = (uint8_t)(key1High_ >> 24);
        key1Bytes[1] = (uint8_t)(key1High_ >> 16);
        key1Bytes[2] = (uint8_t)(key1High_ >> 8);
        key1Bytes[3] = (uint8_t)(key1High_);
        key1Bytes[4] = (uint8_t)(key1Low_ >> 24);
        key1Bytes[5] = (uint8_t)(key1Low_ >> 16);
        key1Bytes[6] = (uint8_t)(key1Low_ >> 8);
        key1Bytes[7] = (uint8_t)(key1Low_);

        uint8_t typeByte = key1Bytes[0];
        uint8_t block[8];
        memcpy(block, key1Bytes + 1, 7);
        block[7] = key2High;

        bool decrypted = false;

        switch (vagType_) {
        case 1:
            // AUT64 decrypt, try all 3 keys
            for (int ki = 0; ki < 3 && !decrypted; ki++) {
                uint8_t copy[8];
                memcpy(copy, block, 8);
                if (aut64Decrypt(copy, ki) && buttonValid(copy)) {
                    result_.serial = ((uint32_t)copy[0] << 24) |
                                     ((uint32_t)copy[1] << 16) |
                                     ((uint32_t)copy[2] << 8) | copy[3];
                    result_.counter = (uint32_t)copy[4] |
                                      ((uint32_t)copy[5] << 8) |
                                      ((uint32_t)copy[6] << 16);
                    result_.button = copy[7];
                    result_.keyIndex = ki;
                    decrypted = true;
                }
            }
            break;

        case 2: {
            // XTEA decrypt
            uint32_t v0 = ((uint32_t)block[0] << 24) | ((uint32_t)block[1] << 16) |
                          ((uint32_t)block[2] << 8) | block[3];
            uint32_t v1 = ((uint32_t)block[4] << 24) | ((uint32_t)block[5] << 16) |
                          ((uint32_t)block[6] << 8) | block[7];
            teaDecrypt(v0, v1);

            uint8_t teaDec[8];
            teaDec[0] = v0 >> 24; teaDec[1] = v0 >> 16;
            teaDec[2] = v0 >> 8;  teaDec[3] = v0;
            teaDec[4] = v1 >> 24; teaDec[5] = v1 >> 16;
            teaDec[6] = v1 >> 8;  teaDec[7] = v1;

            fillFromDecrypted(teaDec, dispatchByte);
            result_.keyIndex = 0xFF;
            decrypted = true;
            break;
        }

        case 3:
            // Try key2 first (→ type 4), then key1, key0
            for (int ki : {2, 1, 0}) {
                uint8_t copy[8];
                memcpy(copy, block, 8);
                if (aut64Decrypt(copy, ki) && buttonValid(copy)) {
                    if (ki == 2) vagType_ = 4;
                    fillFromDecrypted(copy, dispatchByte);
                    result_.keyIndex = ki;
                    decrypted = true;
                    break;
                }
            }
            break;

        case 4: {
            uint8_t copy[8];
            memcpy(copy, block, 8);
            if (aut64Decrypt(copy, 2) && buttonValid(copy)) {
                fillFromDecrypted(copy, dispatchByte);
                result_.keyIndex = 2;
                decrypted = true;
            }
            break;
        }
        }

        // Build result
        result_.data = ((uint64_t)key1High_ << 32) | key1Low_;
        result_.data2 = key2Low_;
        result_.dataBits = 80;
        result_.protocolName = PROTOCOL_NAME;
        result_.encrypted = true;
        result_.canEmulate = false;
        result_.crcValid = decrypted;

        // Vehicle name as type string
        result_.type = vehicleName(typeByte);

        parserStep_ = StepReset;
        return true;
    }
};

PP_REGISTER_PROTOCOL(PPVag)
