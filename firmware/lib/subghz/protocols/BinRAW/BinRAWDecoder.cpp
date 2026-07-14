#include "BinRAWDecoder.h"
#include "esp_log.h"
#include <cstring>
#include <cmath>
#include <cfloat>

static const char* TAG = "BinRAWDecoder";

// ============================================================
// V-table
// ============================================================

const SubGhzProtocolDecoderVTable binraw_decoder_vtable = {
    .alloc         = SubGhzProtocolDecoderBinRAW::alloc,
    .free          = SubGhzProtocolDecoderBinRAW::freeInstance,
    .feed          = SubGhzProtocolDecoderBinRAW::feed,
    .reset         = SubGhzProtocolDecoderBinRAW::resetInstance,
    .get_hash_data = SubGhzProtocolDecoderBinRAW::getHashData,
    .serialize     = SubGhzProtocolDecoderBinRAW::serialize,
    .deserialize   = SubGhzProtocolDecoderBinRAW::deserialize,
};

const SubGhzProtocolDecoderVTable* SubGhzProtocolDecoderBinRAW::vTable() {
    return &binraw_decoder_vtable;
}

// ============================================================
// Helpers
// ============================================================

/** Duration difference helper — port of DURATION_DIFF from Flipper blocks. */
static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

/** Get full byte count for a bit count (round up to nearest byte). */
static uint16_t bin_raw_get_full_byte(uint16_t bit_count) {
    if (bit_count & 0x7) {
        return (bit_count >> 3) + 1;
    }
    return bit_count >> 3;
}

// ============================================================
// Constructor / Destructor / Alloc / Free
// ============================================================

SubGhzProtocolDecoderBinRAW::SubGhzProtocolDecoderBinRAW()
    : parser_step(BinRAWDecoderStep::Reset)
    , te(0)
    , adaptive_threshold_rssi(BIN_RAW_THRESHOLD_RSSI)
    , generic_data_count_bit(0)
    , data_raw_(nullptr)
    , data_(nullptr)
    , data_raw_ind_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "BinRAW";
    base_.flag = PROTOCOL_FLAG;

    data_raw_ = new int32_t[BIN_RAW_BUF_RAW_SIZE];
    data_     = new uint8_t[BIN_RAW_BUF_RAW_SIZE];
    memset(data_raw_, 0, BIN_RAW_BUF_RAW_SIZE * sizeof(int32_t));
    memset(data_, 0, BIN_RAW_BUF_RAW_SIZE * sizeof(uint8_t));
    memset(data_markup_, 0, BIN_RAW_MAX_MARKUP_COUNT * sizeof(BinRAWMarkup));
}

SubGhzProtocolDecoderBinRAW::~SubGhzProtocolDecoderBinRAW() {
    delete[] data_raw_;
    delete[] data_;
}

void* SubGhzProtocolDecoderBinRAW::alloc() {
    auto* instance = new SubGhzProtocolDecoderBinRAW();
    return instance;
}

void SubGhzProtocolDecoderBinRAW::freeInstance(void* context) {
    auto* instance = static_cast<SubGhzProtocolDecoderBinRAW*>(context);
    delete instance;
}

// ============================================================
// Ph 2.2: feed() — port of bin_raw.c:384-395
// ============================================================

void SubGhzProtocolDecoderBinRAW::feed(void* context, bool level, uint32_t duration_us) {
    auto* instance = static_cast<SubGhzProtocolDecoderBinRAW*>(context);
    if (!instance) return;

    if (instance->parser_step == BinRAWDecoderStep::Write) {
        if (instance->data_raw_ind_ >= BIN_RAW_BUF_RAW_SIZE) {
            instance->parser_step = BinRAWDecoderStep::BufFull;
        } else {
            instance->data_raw_[instance->data_raw_ind_++] =
                level ? static_cast<int32_t>(duration_us)
                      : -static_cast<int32_t>(duration_us);
        }
    }
}

// ============================================================
// reset() — port of bin_raw.c:373-382
// ============================================================

void SubGhzProtocolDecoderBinRAW::resetInstance(void* context) {
    auto* instance = static_cast<SubGhzProtocolDecoderBinRAW*>(context);
    if (!instance) return;

    instance->parser_step = BinRAWDecoderStep::NoParse;
    instance->data_raw_ind_ = 0;
}

// ============================================================
// Ph 2.3: inputRssi() — Adaptive RSSI gate
// Port of bin_raw.c:884-963
// ============================================================

void SubGhzProtocolDecoderBinRAW::inputRssi(void* context, float rssi) {
    auto* instance = static_cast<SubGhzProtocolDecoderBinRAW*>(context);
    if (!instance) return;

    switch (instance->parser_step) {

    case BinRAWDecoderStep::Reset: {
        // Quiet state: track noise floor with EMA
        if (rssi > (instance->adaptive_threshold_rssi + BIN_RAW_DELTA_RSSI)) {
            // SIGNAL DETECTED: clear buffers, start writing
            ESP_LOGD(TAG, "RSSI %.1f > threshold %.1f + %.1f — START capture",
                     rssi, instance->adaptive_threshold_rssi, BIN_RAW_DELTA_RSSI);
            instance->data_raw_ind_ = 0;
            memset(instance->data_raw_, 0, BIN_RAW_BUF_RAW_SIZE * sizeof(int32_t));
            memset(instance->data_, 0, BIN_RAW_BUF_RAW_SIZE * sizeof(uint8_t));
            instance->parser_step = BinRAWDecoderStep::Write;
        } else {
            // Quiet: adapt threshold toward current noise floor (EMA α = 0.2)
            instance->adaptive_threshold_rssi +=
                (rssi - instance->adaptive_threshold_rssi) * 0.2f;

            // Clamp to valid range
            if (instance->adaptive_threshold_rssi < BIN_RAW_THRESHOLD_RSSI_MIN)
                instance->adaptive_threshold_rssi = BIN_RAW_THRESHOLD_RSSI_MIN;
            if (instance->adaptive_threshold_rssi > BIN_RAW_THRESHOLD_RSSI_MAX)
                instance->adaptive_threshold_rssi = BIN_RAW_THRESHOLD_RSSI_MAX;
        }
        break;
    }

    case BinRAWDecoderStep::Write:
    case BinRAWDecoderStep::BufFull: {
        if (rssi < instance->adaptive_threshold_rssi + BIN_RAW_DELTA_RSSI) {
            // SIGNAL ENDED: return to Reset state
            ESP_LOGD(TAG, "RSSI %.1f < threshold %.1f + %.1f — END capture (%zu samples)",
                     rssi, instance->adaptive_threshold_rssi, BIN_RAW_DELTA_RSSI,
                     instance->data_raw_ind_);

            instance->parser_step = BinRAWDecoderStep::Reset;
            instance->generic_data_count_bit = 0;

            // Only validate if we have enough samples
            if (instance->data_raw_ind_ >= BIN_RAW_BUF_MIN_DATA_COUNT) {
                if (instance->checkRemoteController()) {
                    ESP_LOGI(TAG, "✅ BinRAW valid signal found! %zu samples, TE=%lu us",
                             instance->data_raw_ind_, (unsigned long)instance->te);

                    // Fire callback
                    if (instance->base_.callback) {
                        instance->base_.callback(&instance->base_, instance->base_.callback_context);
                    }
                } else {
                    ESP_LOGD(TAG, "BinRAW structural validation failed — rejected");
                }
            } else {
                ESP_LOGD(TAG, "Too few samples (%zu < %d) — skipping validation",
                         instance->data_raw_ind_, BIN_RAW_BUF_MIN_DATA_COUNT);
            }
        }
        break;
    }

    default:
        // BinRAWDecoderStep::NoParse or others: restore to Reset if signal is gone
        if (rssi < instance->adaptive_threshold_rssi + BIN_RAW_DELTA_RSSI) {
            instance->parser_step = BinRAWDecoderStep::Reset;
        }
        break;
    }
}

// ============================================================
// Ph 2.4: checkRemoteController() — Structural validation
// Port of bin_raw.c:401-882
//
// This is the heuristic classifier that determines whether a captured
// raw pulse train represents a plausible remote-control signal.
// ============================================================

bool SubGhzProtocolDecoderBinRAW::checkRemoteController() {
    DurationClass classes[BIN_RAW_SEARCH_CLASSES];
    memset(classes, 0, sizeof(classes));

    uint16_t data_markup_ind = 0;
    memset(data_markup_, 0, BIN_RAW_MAX_MARKUP_COUNT * sizeof(BinRAWMarkup));

    // Determine how much data to classify (exclude trailing garbage)
    size_t ind;
    if (data_raw_ind_ < 512) {
        ind = data_raw_ind_ > 100 ? data_raw_ind_ - 100 : 0;
    } else {
        ind = 512;
    }

    if (ind == 0) return false;

    // ---- Step 1: Duration clustering (bin_raw.c:424-439) ----
    // Bucket all pulse/gap durations into ≤20 classes.
    // Tolerance: within 25% of running average, EMA k = 0.05.
    for (size_t i = 0; i < ind; i++) {
        float abs_dur = static_cast<float>(abs(data_raw_[i]));
        for (size_t k = 0; k < BIN_RAW_SEARCH_CLASSES; k++) {
            if (classes[k].count == 0) {
                classes[k].data  = abs_dur;
                classes[k].count = 1;
                break;
            } else if (duration_diff(abs_dur, classes[k].data) < (classes[k].data / 4.0f)) {
                // Within 25%: merge with running average (k=0.05)
                classes[k].data += (abs_dur - classes[k].data) * 0.05f;
                classes[k].count++;
                break;
            }
        }
    }

    // ---- Step 2: Sort classes by count descending (bin_raw.c:457-471) ----
    sortClassesByCount(classes, BIN_RAW_SEARCH_CLASSES);

    // ---- Step 3: TE detection (bin_raw.c:480-514) ----
    te = 65000 * 2;  // init to max (te_long * 2)
    bool te_ok = false;
    uint16_t gap_ind = 0;
    uint32_t gap = 0;
    BinRAWType bin_raw_type = BinRAWType::Unknown;

    if ((classes[0].count > BIN_RAW_TE_MIN_COUNT) && (classes[1].count == 0)) {
        // Only preamble adopted — single dominant duration
        te = static_cast<uint32_t>(classes[0].data);
        te_ok = true;
        gap = 0;  // no gap
    } else {
        // Need at least 2 common durations
        if ((classes[0].count < BIN_RAW_TE_MIN_COUNT) ||
            (classes[1].count < (BIN_RAW_TE_MIN_COUNT >> 1))) {
            return false;
        }

        // Arrange first 2 values in ascending order
        if (classes[0].data > classes[1].data) {
            float tmp = classes[0].data;
            classes[0].data = classes[1].data;
            classes[1].data = tmp;
        }

        // Determine if 2nd duration is an integer multiple of 1st (k=1..4)
        for (uint8_t k = 1; k < 5; k++) {
            float delta = (classes[1].data / (classes[0].data / static_cast<float>(k)));
            float int_part;
            float frac = modff(delta, &int_part);

            if ((frac < 0.20f) || (frac > 0.80f)) {
                te = static_cast<uint32_t>(classes[0].data / static_cast<float>(k));
                te_ok = true;
                break;
            }
        }

        if (!te_ok) {
            // Did not find correlated TE
            return false;
        }

        // ---- Gap detection (bin_raw.c:517-538) ----
        for (size_t k = 2; k < BIN_RAW_SEARCH_CLASSES; k++) {
            if ((classes[k].count > 2) && (classes[k].data > static_cast<float>(gap))) {
                gap = static_cast<uint32_t>(classes[k].data);
            }
        }

        if (te > 0 && (gap / te) < 10) {
            // Gap too short relative to TE → consider NoGap
            gap = 0;
            bin_raw_type = BinRAWType::NoGap;
        } else {
            bin_raw_type = BinRAWType::Gap;
            // Find last occurrence of gap in raw data
            uint32_t gap_delta = gap / 5;  // 20% deviation
            ind = data_raw_ind_ - 1;
            while ((ind > 0) &&
                   (duration_diff(static_cast<float>(abs(data_raw_[ind])), static_cast<float>(gap)) >
                    static_cast<float>(gap_delta))) {
                ind--;
            }
            gap_ind = static_cast<uint16_t>(ind);
        }
    }

    if (!te_ok) return false;

    // ---- Step 4: If Gap, split at gaps and decode packets (bin_raw.c:543-580) ----
    if (bin_raw_type == BinRAWType::Gap) {
        ind = (BIN_RAW_BUF_DATA_SIZE * 8);
        uint16_t bit_count = 0;
        uint32_t gap_delta = gap / 5;

        do {
            if (gap_ind == 0) break;
            gap_ind--;

            int data_temp = static_cast<int>(roundf(
                static_cast<float>(data_raw_[gap_ind]) / static_cast<float>(te)));

            if (data_temp == 0) {
                bit_count++;  // noise in packet
            }

            for (size_t i = 0; i < static_cast<size_t>(abs(data_temp)); i++) {
                bit_count++;
                if (ind > 0) {
                    ind--;
                } else {
                    break;
                }
                if (data_temp > 0) {
                    // Set bit to HIGH
                    data_[ind / 8] |= (1 << (7 - (ind % 8)));
                } else {
                    // Set bit to LOW
                    data_[ind / 8] &= ~(1 << (7 - (ind % 8)));
                }
            }

            // Split packet if gap is caught
            if (duration_diff(static_cast<float>(abs(data_raw_[gap_ind])),
                              static_cast<float>(gap)) < static_cast<float>(gap_delta)) {
                if (data_markup_ind < BIN_RAW_MAX_MARKUP_COUNT) {
                    data_markup_[data_markup_ind].byte_bias = ind >> 3;
                    data_markup_[data_markup_ind].bit_count = bit_count;
                    data_markup_ind++;
                }
                bit_count = 0;
                if (data_markup_ind >= BIN_RAW_MAX_MARKUP_COUNT) break;
                ind &= 0xFFFFFFF8;  // jump to previous whole byte
            }
        } while (gap_ind != 0);

        // Capture trailing fragment
        if ((data_markup_ind < BIN_RAW_MAX_MARKUP_COUNT) && (ind != 0)) {
            data_markup_[data_markup_ind].byte_bias = ind >> 3;
            data_markup_[data_markup_ind].bit_count = bit_count;
            data_markup_ind++;
        }

        if (data_markup_ind == 0) return false;

        // ---- Step 5: Classify packets by bit count (bin_raw.c:584-614) ----
        DurationClass pkt_classes[BIN_RAW_SEARCH_CLASSES];
        memset(pkt_classes, 0, sizeof(pkt_classes));

        for (uint16_t i = 0; i < data_markup_ind; i++) {
            for (size_t k = 0; k < BIN_RAW_SEARCH_CLASSES; k++) {
                if (pkt_classes[k].count == 0) {
                    pkt_classes[k].data = static_cast<float>(data_markup_[i].bit_count);
                    pkt_classes[k].count = 1;
                    break;
                } else if (data_markup_[i].bit_count == static_cast<uint16_t>(pkt_classes[k].data)) {
                    pkt_classes[k].count++;
                    break;
                }
            }
        }

        // Find the most common packet length
        int data_temp = 0;
        for (size_t i = 0; i < BIN_RAW_SEARCH_CLASSES; i++) {
            if ((pkt_classes[i].count > 1) && (data_temp < pkt_classes[i].count)) {
                data_temp = static_cast<int>(pkt_classes[i].data);
            }
        }

        // ---- Step 6: Adjacent repetition check (bin_raw.c:644-689) ----
        if (data_temp != 0) {
            for (uint16_t i = 0; i < data_markup_ind - 1; i++) {
                if ((data_markup_[i].bit_count == static_cast<uint16_t>(data_temp)) &&
                    (data_markup_[i + 1].bit_count == static_cast<uint16_t>(data_temp)))
                {
                    uint16_t byte_count = bin_raw_get_full_byte(data_markup_[i].bit_count);
                    if (memcmp(
                            data_ + data_markup_[i].byte_bias,
                            data_ + data_markup_[i + 1].byte_bias,
                            byte_count - 1) == 0)
                    {
                        // Adjacent packets match → GapRecurring (fixed code)
                        data_markup_[0].bit_count = data_markup_[i].bit_count;
                        data_markup_[0].byte_bias = data_markup_[i].byte_bias;
                        data_markup_[1].bit_count = 0;
                        data_markup_[1].byte_bias = 0;

                        bin_raw_type = BinRAWType::GapRecurring;
                        break;
                    }
                }
            }
        }

        // ---- Step 7: Every-N-th packet check (bin_raw.c:692-774) ----
        if (bin_raw_type == BinRAWType::Gap) {
            for (uint16_t i = 0; i < data_markup_ind - 2; i++) {
                uint16_t byte_count = bin_raw_get_full_byte(data_markup_[i].bit_count);
                for (uint16_t y = i + 1; y < data_markup_ind - 1; y++) {
                    if (byte_count == bin_raw_get_full_byte(data_markup_[y].bit_count)) {
                        // Check if both (i, y) and (i+1, y+1) match (rolling code pattern)
                        if ((memcmp(data_ + data_markup_[i].byte_bias,
                                   data_ + data_markup_[y].byte_bias,
                                   byte_count - 1) == 0) &&
                            (data_markup_[i + 1].bit_count == data_markup_[y + 1].bit_count) &&
                            (memcmp(data_ + data_markup_[i + 1].byte_bias,
                                   data_ + data_markup_[y + 1].byte_bias,
                                   byte_count - 1) == 0))
                        {
                            // Found rolling code pattern — copy packets between i and y
                            BinRAWMarkup tmp_markup[BIN_RAW_MAX_MARKUP_COUNT];
                            memcpy(tmp_markup, data_markup_,
                                   BIN_RAW_MAX_MARKUP_COUNT * sizeof(BinRAWMarkup));
                            memset(data_markup_, 0,
                                   BIN_RAW_MAX_MARKUP_COUNT * sizeof(BinRAWMarkup));

                            uint16_t index = 0;
                            for (uint16_t z = i; z < y; z++) {
                                data_markup_[index].bit_count = tmp_markup[y - z - 1].bit_count;
                                data_markup_[index].byte_bias = tmp_markup[y - z - 1].byte_bias;
                                index++;
                            }

                            bin_raw_type = BinRAWType::GapRolling;
                            break;
                        }
                    }
                }
                if (bin_raw_type == BinRAWType::GapRolling) break;
            }
        }

        // ---- Step 8: Same-length grouping (bin_raw.c:776-800) ----
        if (bin_raw_type == BinRAWType::Gap) {
            if (data_temp != 0) {
                BinRAWMarkup tmp_markup[BIN_RAW_MAX_MARKUP_COUNT];
                memcpy(tmp_markup, data_markup_,
                       BIN_RAW_MAX_MARKUP_COUNT * sizeof(BinRAWMarkup));
                memset(data_markup_, 0,
                       BIN_RAW_MAX_MARKUP_COUNT * sizeof(BinRAWMarkup));

                uint16_t byte_count = bin_raw_get_full_byte(static_cast<uint16_t>(data_temp));
                uint16_t index = 0;
                uint16_t it = BIN_RAW_MAX_MARKUP_COUNT;
                do {
                    it--;
                    if (bin_raw_get_full_byte(tmp_markup[it].bit_count) == byte_count) {
                        data_markup_[index].bit_count = tmp_markup[it].bit_count;
                        data_markup_[index].byte_bias = tmp_markup[it].byte_bias;
                        index++;
                        bin_raw_type = BinRAWType::GapUnknown;
                    }
                } while (it != 0);
            }
        }

        if (bin_raw_type != BinRAWType::Gap) {
            return true;
        } else {
            return false;
        }

    } else {
        // ---- No-gap path (bin_raw.c:807-880) ----
        ind = 0;
        for (size_t i = 0; i < data_raw_ind_; i++) {
            int data_temp_val = static_cast<int>(roundf(
                static_cast<float>(data_raw_[i]) / static_cast<float>(te)));
            if (data_temp_val == 0) {
                // Interval 2x shorter than TE → noise
                break;
            }

            for (size_t k = 0; k < static_cast<size_t>(abs(data_temp_val)); k++) {
                if (data_temp_val > 0) {
                    data_[ind / 8] |= (1 << (7 - (ind % 8)));
                } else {
                    data_[ind / 8] &= ~(1 << (7 - (ind % 8)));
                }
                ind++;
                if (ind >= BIN_RAW_BUF_DATA_SIZE * 8) {
                    i = data_raw_ind_;
                    break;
                }
            }
        }

        if (ind != 0) {
            bin_raw_type = BinRAWType::NoGap;

            // Check that decoded data contains non-zero data
            bool data_check = false;
            for (size_t i = 0; i < bin_raw_get_full_byte(static_cast<uint16_t>(ind)); i++) {
                if (data_[i] != 0) {
                    data_check = true;
                    break;
                }
            }

            if (data_check) {
                // Right-align bits
                uint8_t bit_bias = (bin_raw_get_full_byte(static_cast<uint16_t>(ind)) << 3) -
                                   static_cast<uint8_t>(ind);

                for (size_t i = bin_raw_get_full_byte(static_cast<uint16_t>(ind)) - 1; i > 0; i--) {
                    data_[i] = (data_[i - 1] << (8 - bit_bias)) | (data_[i] >> bit_bias);
                }
                data_[0] = (data_[0] >> bit_bias);

                data_markup_[0].bit_count = static_cast<uint16_t>(ind);
                data_markup_[0].byte_bias = 0;
                return true;
            } else {
                return false;
            }
        } else {
            return false;
        }
    }
}

// ============================================================
// Bubble sort classes by count descending (bin_raw.c:457-471)
// ============================================================

void SubGhzProtocolDecoderBinRAW::sortClassesByCount(
    DurationClass* classes, size_t count)
{
    bool swapped = true;
    while (swapped) {
        swapped = false;
        for (size_t i = 1; i < count; i++) {
            if (classes[i].count > classes[i - 1].count) {
                DurationClass tmp = classes[i - 1];
                classes[i - 1] = classes[i];
                classes[i] = tmp;
                swapped = true;
            }
        }
    }
}

// ============================================================
// getHashData — port of bin_raw.c:965-970
// ============================================================

uint8_t SubGhzProtocolDecoderBinRAW::getHashData(void* context) {
    auto* instance = static_cast<SubGhzProtocolDecoderBinRAW*>(context);
    if (!instance || instance->data_markup_[0].bit_count == 0) return 0;

    uint16_t byte_count = bin_raw_get_full_byte(instance->data_markup_[0].bit_count);
    // Simple byte-sum hash (Flipper uses subghz_protocol_blocks_add_bytes)
    uint8_t hash = 0;
    for (uint16_t i = 0; i < byte_count; i++) {
        hash += instance->data_[instance->data_markup_[0].byte_bias + i];
    }
    return hash;
}

// ============================================================
// serialize — save decoded BinRAW to .sub format
// ============================================================

void SubGhzProtocolDecoderBinRAW::serialize(void* context, class File& file) {
    auto* instance = static_cast<SubGhzProtocolDecoderBinRAW*>(context);
    if (!instance || instance->data_markup_[0].bit_count == 0) return;

    uint16_t total_bit_count = 0;
    for (size_t i = 0; i < BIN_RAW_MAX_MARKUP_COUNT; i++) {
        if (instance->data_markup_[i].bit_count == 0) break;
        total_bit_count += instance->data_markup_[i].bit_count;
    }

    file.print("Protocol: BinRAW\n");
    file.print("Bit: ");
    file.print(total_bit_count);
    file.print("\n");
    file.print("TE: ");
    file.print(instance->te);
    file.print("\n");

    for (size_t i = 0; i < BIN_RAW_MAX_MARKUP_COUNT; i++) {
        if (instance->data_markup_[i].bit_count == 0) break;
        file.print("Bit_RAW: ");
        file.print(instance->data_markup_[i].bit_count);
        file.print("\n");
        file.print("Data_RAW: ");
        uint16_t byte_count = bin_raw_get_full_byte(instance->data_markup_[i].bit_count);
        for (uint16_t b = 0; b < byte_count; b++) {
            if (b > 0) file.print(" ");
            char hex[3];
            snprintf(hex, sizeof(hex), "%02X",
                     instance->data_[instance->data_markup_[i].byte_bias + b]);
            file.print(hex);
        }
        file.print("\n");
    }
}

// ============================================================
// deserialize — load from file
// ============================================================

bool SubGhzProtocolDecoderBinRAW::deserialize(void* context, class File& file) {
    // Currently not implemented for real-time use — the existing
    // BinRAWProtocol::parse() handles file-based loading.
    // This is a stub for interface completeness.
    (void)context;
    (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use BinRAWProtocol::parse()");
    return false;
}
