#pragma once
/**
 * @file PPStarLine.h
 * @brief StarLine key fob protocol decoder/encoder.
 *
 * PWM: te_short=250µs, te_long=500µs, 64-bit.
 * KeeLoq encrypted with keystore (Simple/Normal learning).
 * Ported from ProtoPirate star_line.c
 */

#include "PPProtocol.h"
#include "PPCommon.h"
#include "KeeloqCipher.h"

class PPStarLine : public PPProtocol {
public:
    static constexpr const char* PROTOCOL_NAME = "StarLine";

    const char* getName() const override { return PROTOCOL_NAME; }
    bool canEmulate() const override { return true; }

    const PPTimingConst& getTiming() const override {
        static const PPTimingConst t = {250, 500, 120, 64};
        return t;
    }

    void reset() override {
        resetDecoder();
    }

    /**
     * @brief Set a manufacturer key for KeeLoq decryption.
     * @param index Key index (0-based)
     * @param name  Manufacturer name
     * @param key   64-bit KeeLoq key
     * @param type  Learning type (0=Simple, 1=Normal, 2=Unknown)
     */
    static void addManufacturerKey(size_t index, const char* name,
                                   uint64_t key, uint8_t type) {
        if (index < MAX_KEYS) {
            keys_[index] = {name, key, type};
            if (index >= keyCount_) keyCount_ = index + 1;
        }
    }

    static void clearKeys() { keyCount_ = 0; }

    bool feed(bool level, uint32_t duration) override {
        auto& t = getTiming();

        switch (parserStep_) {
        case StepReset:
            if (level) {
                if (DURATION_DIFF(duration, t.te_long * 2) <
                    t.te_delta * 2) {
                    parserStep_ = StepCheckPreamble;
                    headerCount_++;
                } else if (headerCount_ > 4) {
                    decodeData_ = 0;
                    decodeCountBit_ = 0;
                    teLast_ = duration;
                    parserStep_ = StepCheckDuration;
                }
            } else {
                headerCount_ = 0;
            }
            break;

        case StepCheckPreamble:
            if (!level &&
                DURATION_DIFF(duration, t.te_long * 2) < t.te_delta * 2) {
                // Preamble pair found
                parserStep_ = StepReset;
            } else {
                headerCount_ = 0;
                parserStep_ = StepReset;
            }
            break;

        case StepSaveDuration:
            if (level) {
                if (duration >= (t.te_long + t.te_delta)) {
                    // End of data
                    parserStep_ = StepReset;
                    if (decodeCountBit_ >= t.min_count_bit &&
                        decodeCountBit_ <= t.min_count_bit + 2) {
                        if (lastData_ != decodeData_) {
                            lastData_ = decodeData_;
                            return extractData();
                        }
                    }
                    decodeData_ = 0;
                    decodeCountBit_ = 0;
                    headerCount_ = 0;
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
                    // Bit 0
                    if (decodeCountBit_ < t.min_count_bit) {
                        addBit(0);
                    } else {
                        decodeCountBit_++;
                    }
                    parserStep_ = StepSaveDuration;
                } else if (DURATION_DIFF(teLast_, t.te_long) < t.te_delta &&
                           DURATION_DIFF(duration, t.te_long) < t.te_delta) {
                    // Bit 1
                    if (decodeCountBit_ < t.min_count_bit) {
                        addBit(1);
                    } else {
                        decodeCountBit_++;
                    }
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

    std::vector<PPPulse> generatePulseData(const PPDecodeResult& r) override {
        std::vector<PPPulse> pulses;
        auto& t = getTiming();

        // 6 preamble long-pulse pairs
        for (int i = 0; i < 6; i++) {
            pulses.push_back({(int32_t)(t.te_long * 2)});
            pulses.push_back({-(int32_t)(t.te_long * 2)});
        }

        // Data bits (MSB first)
        for (int i = 63; i >= 0; i--) {
            if ((r.data >> i) & 1) {
                pulses.push_back({(int32_t)t.te_long});
                pulses.push_back({-(int32_t)t.te_long});
            } else {
                pulses.push_back({(int32_t)t.te_short});
                pulses.push_back({-(int32_t)t.te_short});
            }
        }

        return pulses;
    }

private:
    uint64_t lastData_ = 0;

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
        // Reverse key bits (original uses subghz_protocol_blocks_reverse_key)
        uint64_t key = pp_reverse64(decodeData_);
        uint32_t keyFix = (uint32_t)(key >> 32);
        uint32_t keyHop = (uint32_t)(key & 0xFFFFFFFF);

        uint32_t serial = keyFix & 0x00FFFFFF;
        uint8_t btn = (uint8_t)(keyFix >> 24);
        uint16_t endSerial = (uint16_t)(keyFix & 0xFF);

        // Try all manufacturer keys
        const char* mfName = "Unknown";
        uint32_t cnt = 0;
        bool found = tryDecrypt(keyFix, keyHop, btn, endSerial, mfName, cnt);

        result_.data = decodeData_;
        result_.dataBits = 64;
        result_.protocolName = PROTOCOL_NAME;
        result_.serial = serial;
        result_.button = btn;
        result_.counter = cnt;
        result_.encrypted = true;
        result_.canEmulate = found;
        result_.type = mfName;

        return true;
    }

    /// Try to decrypt the hop code using the keystore
    bool tryDecrypt(uint32_t fix, uint32_t hop, uint8_t btn,
                    uint16_t endSerial, const char*& mfName,
                    uint32_t& cnt) {
        for (size_t i = 0; i < keyCount_; i++) {
            auto& mk = keys_[i];
            uint32_t decrypt = 0;

            switch (mk.type) {
            case 0: // KEELOQ_LEARNING_SIMPLE
                decrypt = keeloq::decrypt(hop, mk.key);
                if (checkDecrypt(decrypt, btn, endSerial, cnt)) {
                    mfName = mk.name;
                    return true;
                }
                break;

            case 1: { // KEELOQ_LEARNING_NORMAL
                uint64_t manKey = keeloq::normalLearning(fix, mk.key);
                decrypt = keeloq::decrypt(hop, manKey);
                if (checkDecrypt(decrypt, btn, endSerial, cnt)) {
                    mfName = mk.name;
                    return true;
                }
                break;
            }

            case 2: { // KEELOQ_LEARNING_UNKNOWN
                // Try Simple
                decrypt = keeloq::decrypt(hop, mk.key);
                if (checkDecrypt(decrypt, btn, endSerial, cnt)) {
                    mfName = mk.name;
                    return true;
                }

                // Try mirrored key
                uint64_t manRev = 0;
                for (uint8_t j = 0; j < 64; j += 8) {
                    manRev |= (uint64_t)((uint8_t)(mk.key >> j))
                              << (56 - j);
                }
                decrypt = keeloq::decrypt(hop, manRev);
                if (checkDecrypt(decrypt, btn, endSerial, cnt)) {
                    mfName = mk.name;
                    return true;
                }

                // Try Normal
                uint64_t manKey = keeloq::normalLearning(fix, mk.key);
                decrypt = keeloq::decrypt(hop, manKey);
                if (checkDecrypt(decrypt, btn, endSerial, cnt)) {
                    mfName = mk.name;
                    return true;
                }

                // Try mirrored Normal
                manKey = keeloq::normalLearning(fix, manRev);
                decrypt = keeloq::decrypt(hop, manKey);
                if (checkDecrypt(decrypt, btn, endSerial, cnt)) {
                    mfName = mk.name;
                    return true;
                }
                break;
            }
            }
        }
        return false;
    }

    static bool checkDecrypt(uint32_t decrypt, uint8_t btn,
                             uint16_t endSerial, uint32_t& cnt) {
        if ((decrypt >> 24 == btn) &&
            (((uint16_t)(decrypt >> 16) & 0x00FF) == endSerial)) {
            cnt = decrypt & 0x0000FFFF;
            return true;
        }
        return false;
    }

    /// Manufacturer key entry
    struct ManufacturerKey {
        const char* name;
        uint64_t key;
        uint8_t type;  // 0=Simple, 1=Normal, 2=Unknown
    };

    static constexpr size_t MAX_KEYS = 16;
    static inline ManufacturerKey keys_[MAX_KEYS] = {};
    static inline size_t keyCount_ = 0;
};

PP_REGISTER_PROTOCOL(PPStarLine)
