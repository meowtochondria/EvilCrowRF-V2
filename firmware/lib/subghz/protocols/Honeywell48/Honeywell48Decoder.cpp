#include "Honeywell48Decoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cmath>
#include <cstring>
#include <cstdio>

static const char* TAG = "Honeywell48Decoder";

static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

static inline uint8_t parity(uint64_t data, uint8_t bit_count) {
    uint8_t p = 0;
    for (uint8_t i = 0; i < bit_count; i++) {
        p ^= (data >> i) & 1;
    }
    return p;
}

const SubGhzProtocolDecoderVTable honeywell48_decoder_vtable = {
    .alloc = Honeywell48Decoder::alloc,
    .free = Honeywell48Decoder::freeInstance,
    .feed = Honeywell48Decoder::feed,
    .reset = Honeywell48Decoder::resetInstance,
    .get_hash_data = Honeywell48Decoder::getHashData,
    .serialize = Honeywell48Decoder::serialize,
    .deserialize = Honeywell48Decoder::deserialize,
};

const SubGhzProtocolDecoderVTable* Honeywell48Decoder::vTable() {
    return &honeywell48_decoder_vtable;
}

Honeywell48Decoder::Honeywell48Decoder()
    : state_(StepReset)
    , decode_data_(0)
    , decode_count_bit_(0)
    , te_last_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Honeywell 48bit";
    base_.flag = PROTOCOL_FLAG;
}

Honeywell48Decoder::~Honeywell48Decoder() {}

void* Honeywell48Decoder::alloc() {
    // Single static instance — avoids boot-time heap fragmentation (see PrincetonDecoder).
    static Honeywell48Decoder instance;
    return &instance;
}
void Honeywell48Decoder::freeInstance(void* context) {
    (void)context;  // static instance, nothing to free
}

void Honeywell48Decoder::resetInstance(void* context) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self) return;
    self->state_ = StepReset;
    self->decode_data_ = 0;
    self->decode_count_bit_ = 0;
    self->te_last_ = 0;
}

void Honeywell48Decoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self) return;

    switch (self->state_) {

    case StepReset:
        if (!level &&
            duration_diff(static_cast<float>(duration_us),
                          static_cast<float>(TE_SHORT * PREAMBLE_GUARD_TE)) <
                static_cast<float>(TE_DELTA)) {
            // Found header (LOW ~3*te_short)
            self->decode_count_bit_ = 0;
            self->decode_data_ = 0;
            ESP_LOGD(TAG, "Preamble detected (LOW=%lu us)", (unsigned long)duration_us);
            self->state_ = StepSaveDuration;
        }
        break;

    case StepSaveDuration:
        if (level) {
            // End-of-frame marker: HIGH ~3*te_short
            if (duration_diff(static_cast<float>(duration_us),
                              static_cast<float>(TE_SHORT * PREAMBLE_GUARD_TE)) <
                static_cast<float>(TE_DELTA)) {
                if (self->decode_count_bit_ == MIN_COUNT_BIT &&
                    (self->decode_data_ & 0x01) ==
                        parity(self->decode_data_ >> 1, MIN_COUNT_BIT - 1)) {
                    ESP_LOGI(TAG, "Honeywell48 decoded: key=0x%012llX, bits=%u",
                             (unsigned long long)self->decode_data_,
                             self->decode_count_bit_);
                    if (self->base_.callback)
                        self->base_.callback(&self->base_, self->base_.callback_context);
                } else {
                    ESP_LOGW(TAG, "Decode rejected: bits=%u (expected %u) or parity fail",
                             self->decode_count_bit_, MIN_COUNT_BIT);
                }
                self->state_ = StepReset;
                break;
            }
            self->te_last_ = duration_us;
            self->state_ = StepCheckDuration;
        } else {
            self->state_ = StepReset;
        }
        break;

    case StepCheckDuration:
        if (!level) {
            if (duration_diff(static_cast<float>(self->te_last_),
                              static_cast<float>(TE_SHORT)) <
                    static_cast<float>(TE_DELTA) &&
                duration_diff(static_cast<float>(duration_us),
                              static_cast<float>(TE_LONG)) <
                    static_cast<float>(TE_DELTA)) {
                // Bit 0: HIGH=te_short, LOW=te_long
                self->decode_data_ = (self->decode_data_ << 1) | 0;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else if (
                duration_diff(static_cast<float>(self->te_last_),
                              static_cast<float>(TE_LONG)) <
                    static_cast<float>(TE_DELTA) &&
                duration_diff(static_cast<float>(duration_us),
                              static_cast<float>(TE_SHORT)) <
                    static_cast<float>(TE_DELTA)) {
                // Bit 1: HIGH=te_long, LOW=te_short
                self->decode_data_ = (self->decode_data_ << 1) | 1;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else {
                self->state_ = StepReset;
            }
        } else {
            self->state_ = StepReset;
        }
        break;
    }
}

uint8_t Honeywell48Decoder::getHashData(void* context) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self || self->decode_data_ == 0) return 0;
    uint8_t hash = 0;
    uint8_t bytes[6];
    for (size_t i = 0; i < 6; i++) {
        bytes[i] = (self->decode_data_ >> (i * 8)) & 0xFF;
        hash += bytes[i];
    }
    return hash;
}

void Honeywell48Decoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self || self->decode_data_ == 0) return;
    file.print("Protocol: Honeywell 48bit\n");
    file.print("Bit: ");
    file.print(self->decode_count_bit_);
    file.print("\nKey: ");
    char hex[17];
    snprintf(hex, sizeof(hex), "%012llX",
             (unsigned long long)(self->decode_data_ & 0xFFFFFFFFFFFFULL));
    file.print(hex);
    file.print("\nTE: ");
    file.print(TE_SHORT);
    file.print("\nRepeat: 1\n");
}

bool Honeywell48Decoder::deserialize(void* context, fs::File& file) {
    (void)context;
    (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use Honeywell48FileParser::parse()");
    return false;
}
