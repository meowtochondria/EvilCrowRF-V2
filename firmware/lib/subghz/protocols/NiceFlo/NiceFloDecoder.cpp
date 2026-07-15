#include "NiceFloDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cmath>
#include <cstring>
#include <cstdio>

static const char* TAG = "NiceFloDecoder";

static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

const SubGhzProtocolDecoderVTable niceflo_decoder_vtable = {
    .alloc = NiceFloDecoder::alloc, .free = NiceFloDecoder::freeInstance,
    .feed = NiceFloDecoder::feed, .reset = NiceFloDecoder::resetInstance,
    .get_hash_data = NiceFloDecoder::getHashData,
    .serialize = NiceFloDecoder::serialize, .deserialize = NiceFloDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* NiceFloDecoder::vTable() { return &niceflo_decoder_vtable; }

NiceFloDecoder::NiceFloDecoder()
    : state_(StepReset), decode_data_(0), decode_count_bit_(0), te_last_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Nice FLO";
    base_.flag = PROTOCOL_FLAG;
}

NiceFloDecoder::~NiceFloDecoder() {}
void* NiceFloDecoder::alloc() {
    // Single static instance — avoids boot-time heap fragmentation (see PrincetonDecoder).
    static NiceFloDecoder instance;
    return &instance;
}
void NiceFloDecoder::freeInstance(void* context) { (void)context; }

void NiceFloDecoder::resetInstance(void* context) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self) return;
    self->state_ = StepReset;
    self->decode_data_ = 0;
    self->decode_count_bit_ = 0;
    self->te_last_ = 0;
}

void NiceFloDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self) return;

    float duration = (float)duration_us;

    switch (self->state_) {
    case StepReset:
        if (!level &&
            duration_diff(duration, (float)(TE_SHORT * PREAMBLE_GUARD_TE)) <
                (float)(TE_DELTA * PREAMBLE_GUARD_TE)) {
            // Found header Nice Flo
            ESP_LOGI(TAG, "Preamble detected");
            self->state_ = StepFoundStartBit;
        }
        break;
    case StepFoundStartBit:
        if (!level) {
            break;
        } else if (duration_diff(duration, (float)TE_SHORT) < (float)TE_DELTA) {
            // Found start bit Nice Flo
            self->state_ = StepSaveDuration;
            self->decode_data_ = 0;
            self->decode_count_bit_ = 0;
        } else {
            self->state_ = StepReset;
        }
        break;
    case StepSaveDuration:
        if (!level) { // save interval
            if (duration >= (float)(TE_SHORT * 4)) {
                // end of frame
                self->state_ = StepFoundStartBit;
                if (self->decode_count_bit_ >= MIN_COUNT_BIT) {
                    ESP_LOGI(TAG,
                             "Nice FLO decoded: key=0x%08llX, bits=%u",
                             (unsigned long long)self->decode_data_,
                             self->decode_count_bit_);
                    if (self->base_.callback)
                        self->base_.callback(&self->base_, self->base_.callback_context);
                } else {
                    ESP_LOGW(TAG,
                             "Wrong bit count: %u (need >= %u)",
                             self->decode_count_bit_, MIN_COUNT_BIT);
                }
                break;
            }
            self->te_last_ = duration_us;
            self->state_ = StepCheckDuration;
        } else {
            self->state_ = StepReset;
        }
        break;
    case StepCheckDuration:
        if (level) {
            if (duration_diff((float)self->te_last_, (float)TE_SHORT) < (float)TE_DELTA &&
                duration_diff(duration, (float)TE_LONG) < (float)TE_DELTA) {
                // bit 0: LOW=te_short, HIGH=te_long
                self->decode_data_ = (self->decode_data_ << 1) | 0;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else if (duration_diff((float)self->te_last_, (float)TE_LONG) < (float)TE_DELTA &&
                       duration_diff(duration, (float)TE_SHORT) < (float)TE_DELTA) {
                // bit 1: LOW=te_long, HIGH=te_short
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

uint8_t NiceFloDecoder::getHashData(void* context) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self || self->decode_data_ == 0) return 0;
    uint8_t hash = 0;
    uint8_t bytes = (self->decode_count_bit_ / 8) + 1;
    for (size_t i = 0; i < bytes; i++) {
        hash += (self->decode_data_ >> (i * 8)) & 0xFF;
    }
    return hash;
}

void NiceFloDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self || self->decode_data_ == 0) return;
    file.print("Protocol: Nice FLO\n");
    file.print("Bit: "); file.print(self->decode_count_bit_); file.print("\n");
    file.print("Key: ");
    char hex[17];
    snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)self->decode_data_);
    file.print(hex); file.print("\n");
    file.print("TE: "); file.print(TE_SHORT); file.print("\n");
    file.print("Repeat: 1\n");
}

bool NiceFloDecoder::deserialize(void* context, fs::File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use NiceFloProtocol::parse()");
    return false;
}
