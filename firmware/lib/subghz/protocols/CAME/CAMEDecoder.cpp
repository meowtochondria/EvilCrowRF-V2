#include "CAMEDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cmath>
#include <cstring>
#include <cstdio>

static const char* TAG = "CAMEDecoder";

// Local helper mirroring Flipper's DURATION_DIFF macro, but using
// floating-point math so the comparisons in feed() match the reference
// implementation exactly.
static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

const SubGhzProtocolDecoderVTable came_decoder_vtable = {
    .alloc         = CAMEDecoder::alloc,
    .free          = CAMEDecoder::freeInstance,
    .feed          = CAMEDecoder::feed,
    .reset         = CAMEDecoder::resetInstance,
    .get_hash_data = CAMEDecoder::getHashData,
    .serialize     = CAMEDecoder::serialize,
    .deserialize   = CAMEDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* CAMEDecoder::vTable() {
    return &came_decoder_vtable;
}

CAMEDecoder::CAMEDecoder()
    : state_(StepReset)
    , decode_data_(0)
    , decode_count_bit_(0)
    , te_last_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "CAME";
    base_.flag = PROTOCOL_FLAG;
}

CAMEDecoder::~CAMEDecoder() {}

void* CAMEDecoder::alloc() {
    // Single static instance — avoids boot-time heap fragmentation (see PrincetonDecoder).
    static CAMEDecoder instance;
    return &instance;
}
void CAMEDecoder::freeInstance(void* context) {
    (void)context;  // static instance, nothing to free
}

void CAMEDecoder::resetInstance(void* context) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self) return;
    self->state_ = StepReset;
    self->decode_data_ = 0;
    self->decode_count_bit_ = 0;
    self->te_last_ = 0;
}

void CAMEDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self) return;

    const float duration = static_cast<float>(duration_us);

    switch (self->state_) {

    case StepReset:
        // Wait for a long LOW (~te_short * 56 us) that marks the CAME preamble.
        if (!level &&
            duration_diff(duration, static_cast<float>(TE_SHORT * PREAMBLE_GUARD_TE)) <
                static_cast<float>(TE_DELTA * 63)) {
            ESP_LOGD(TAG, "CAME preamble detected (low=%lu us)", (unsigned long)duration_us);
            self->state_ = StepFoundStartBit;
        }
        break;

    case StepFoundStartBit:
        if (!level) {
            // Stay here until we see the start bit.
            break;
        } else if (duration_diff(duration, static_cast<float>(TE_SHORT)) <
                   static_cast<float>(TE_DELTA)) {
            // Found start bit: a HIGH of ~te_short us.
            self->decode_data_ = 0;
            self->decode_count_bit_ = 0;
            self->state_ = StepSaveDuration;
        } else {
            self->state_ = StepReset;
        }
        break;

    case StepSaveDuration:
        if (!level) {
            // Save the LOW interval; if it is long enough, the frame is over.
            if (duration >= static_cast<float>(TE_SHORT * 4)) {
                if (self->decode_count_bit_ == MIN_COUNT_BIT ||
                    self->decode_count_bit_ == AIRFORCE_COUNT_BIT ||
                    self->decode_count_bit_ == CAME_24_COUNT_BIT ||
                    self->decode_count_bit_ == PRASTEL_25_COUNT_BIT ||
                    self->decode_count_bit_ == PRASTEL_42_COUNT_BIT) {
                    ESP_LOGI(TAG,
                             "CAME frame complete: key=0x%llX, bits=%u",
                             (unsigned long long)self->decode_data_,
                             self->decode_count_bit_);
                    if (self->base_.callback)
                        self->base_.callback(&self->base_, self->base_.callback_context);
                } else if (self->decode_count_bit_ != 0) {
                    ESP_LOGW(TAG,
                             "CAME frame rejected: wrong bit count=%u",
                             self->decode_count_bit_);
                }
                self->decode_data_ = 0;
                self->decode_count_bit_ = 0;
                self->state_ = StepFoundStartBit;
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
            // Bit 0: te_last≈te_short && duration≈te_long
            // Bit 1: te_last≈te_long  && duration≈te_short
            if (duration_diff(static_cast<float>(self->te_last_), static_cast<float>(TE_SHORT)) <
                    static_cast<float>(TE_DELTA) &&
                duration_diff(duration, static_cast<float>(TE_LONG)) <
                    static_cast<float>(TE_DELTA)) {
                self->decode_data_ = (self->decode_data_ << 1) | 0;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else if (
                duration_diff(static_cast<float>(self->te_last_), static_cast<float>(TE_LONG)) <
                    static_cast<float>(TE_DELTA) &&
                duration_diff(duration, static_cast<float>(TE_SHORT)) <
                    static_cast<float>(TE_DELTA)) {
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

uint8_t CAMEDecoder::getHashData(void* context) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self || self->decode_data_ == 0) return 0;
    uint8_t hash = 0;
    for (size_t i = 0; i < 8; i++)
        hash += (self->decode_data_ >> (i * 8)) & 0xFF;
    return hash;
}

void CAMEDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self || self->decode_data_ == 0) return;
    char line[64];
    file.print("Protocol: CAME\n");
    file.print("Bit: ");
    file.print(self->decode_count_bit_);
    file.print("\nKey: ");
    snprintf(line, sizeof(line), "%llX", (unsigned long long)self->decode_data_);
    file.print(line);
    file.print("\nTE: ");
    file.print(TE_SHORT);
    file.print("\nRepeat: 1\n");
}

bool CAMEDecoder::deserialize(void* context, fs::File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use CAMEProtocol::parse()");
    return false;
}
