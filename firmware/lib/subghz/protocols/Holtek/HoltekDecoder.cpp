#include "HoltekDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cmath>
#include <cstring>
#include <cstdio>

static const char* TAG = "HoltekDecoder";

static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

const SubGhzProtocolDecoderVTable holtek_decoder_vtable = {
    .alloc = HoltekDecoder::alloc, .free = HoltekDecoder::freeInstance,
    .feed = HoltekDecoder::feed, .reset = HoltekDecoder::resetInstance,
    .get_hash_data = HoltekDecoder::getHashData,
    .serialize = HoltekDecoder::serialize, .deserialize = HoltekDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* HoltekDecoder::vTable() { return &holtek_decoder_vtable; }

HoltekDecoder::HoltekDecoder()
    : state_(StepReset), decode_data_(0), decode_count_bit_(0),
      last_data_(0), te_(0), te_last_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Holtek";
    base_.flag = PROTOCOL_FLAG;
}

HoltekDecoder::~HoltekDecoder() {}
void* HoltekDecoder::alloc() {
    // Single static instance — avoids boot-time heap fragmentation (see PrincetonDecoder).
    static HoltekDecoder instance;
    return &instance;
}
void HoltekDecoder::freeInstance(void* context) { (void)context; }

void HoltekDecoder::resetInstance(void* context) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return;
    // PRESERVE last_data_ — needed for repeat confirmation across resets.
    self->state_ = StepReset;
    self->decode_data_ = 0;
    self->decode_count_bit_ = 0;
    self->te_ = 0;
    self->te_last_ = 0;
}

void HoltekDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return;

    const float duration = (float)duration_us;

    switch (self->state_) {
    case StepReset:
        // Wait for a long LOW (~28×te_short) preamble guard.
        if (!level &&
            duration_diff(duration, (float)(TE_SHORT * PREAMBLE_GUARD_TE)) <
                (float)(TE_DELTA * PREAMBLE_GUARD_DELTA_TE)) {
            ESP_LOGD(TAG, "Preamble detected (%lu us)", (unsigned long)duration_us);
            self->state_ = StepFoundStartBit;
        }
        break;

    case StepFoundStartBit:
        // Wait for HIGH ~= te_short (start bit).
        if (level && duration_diff(duration, (float)TE_SHORT) < (float)TE_DELTA) {
            self->state_ = StepSaveDuration;
            self->decode_data_ = 0;
            self->decode_count_bit_ = 0;
            self->te_ = duration_us;
        } else {
            self->state_ = StepReset;
        }
        break;

    case StepSaveDuration:
        if (!level) {
            // End-of-frame guard: long LOW >= te_short*10 + te_delta.
            if (duration >= (float)(TE_SHORT * 10) + (float)TE_DELTA) {
                if (self->decode_count_bit_ == MIN_COUNT_BIT) {
                    if (self->last_data_ == self->decode_data_ && self->last_data_) {
                        self->te_ /= (self->decode_count_bit_ * 3 + 1);
                        ESP_LOGI(TAG,
                                 "Holtek decoded: data=0x%03lX, bit=%u, TE=%lu us",
                                 (unsigned long)(self->decode_data_ & 0xFFF),
                                 self->decode_count_bit_,
                                 (unsigned long)self->te_);
                        if (self->base_.callback)
                            self->base_.callback(&self->base_, self->base_.callback_context);
                    } else {
                        ESP_LOGD(TAG, "Waiting for repeat (data=0x%03lX)",
                                 (unsigned long)(self->decode_data_ & 0xFFF));
                    }
                    self->last_data_ = self->decode_data_;
                } else if (self->decode_count_bit_ != 0) {
                    ESP_LOGW(TAG,
                             "Wrong bit count: %u (expected %u)",
                             self->decode_count_bit_, MIN_COUNT_BIT);
                }
                self->decode_data_ = 0;
                self->decode_count_bit_ = 0;
                self->te_ = 0;
                self->state_ = StepFoundStartBit;
                break;
            }
            self->te_last_ = duration_us;
            self->te_ += duration_us;
            self->state_ = StepCheckDuration;
        } else {
            self->state_ = StepReset;
        }
        break;

    case StepCheckDuration:
        if (level) {
            self->te_ += duration_us;
            // Bit 1: LOW=te_long, HIGH=te_short
            if (duration_diff((float)self->te_last_, (float)TE_LONG) < (float)(TE_DELTA * 2) &&
                duration_diff(duration, (float)TE_SHORT) < (float)TE_DELTA) {
                self->decode_data_ = (self->decode_data_ << 1) | 1;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            }
            // Bit 0: LOW=te_short, HIGH=te_long
            else if (duration_diff((float)self->te_last_, (float)TE_SHORT) < (float)TE_DELTA &&
                     duration_diff(duration, (float)TE_LONG) < (float)(TE_DELTA * 2)) {
                self->decode_data_ = (self->decode_data_ << 1);
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

uint8_t HoltekDecoder::getHashData(void* context) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return 0;
    uint8_t hash = 0;
    for (uint8_t i = 0; i < (self->decode_count_bit_ / 8) + 1; i++) {
        hash += (uint8_t)((self->decode_data_ >> (i * 8)) & 0xFF);
    }
    return hash;
}

void HoltekDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return;
    char hex[17];
    file.print("Protocol: Holtek\n");
    file.print("Bit: ");
    file.print(self->decode_count_bit_);
    file.print("\n");
    file.print("Key: ");
    snprintf(hex, sizeof(hex), "%lX", (unsigned long)(self->decode_data_ & 0xFFFF));
    file.print(hex);
    file.print("\n");
    file.print("TE: ");
    file.print(self->te_);
    file.print("\n");
    file.print("Repeat: 1\n");
}

bool HoltekDecoder::deserialize(void* context, fs::File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use HoltekProtocol::parse()");
    return false;
}
