#include "GateTXDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cstring>
#include <cstdio>
#include <cmath>

static const char* TAG = "GateTXDecoder";

/** Port of DURATION_DIFF from Flipper blocks/const.h. */
static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

const SubGhzProtocolDecoderVTable gatetx_decoder_vtable = {
    .alloc         = GateTXDecoder::alloc,
    .free          = GateTXDecoder::freeInstance,
    .feed          = GateTXDecoder::feed,
    .reset         = GateTXDecoder::resetInstance,
    .get_hash_data = GateTXDecoder::getHashData,
    .serialize     = GateTXDecoder::serialize,
    .deserialize   = GateTXDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* GateTXDecoder::vTable() {
    return &gatetx_decoder_vtable;
}

// ============================================================

GateTXDecoder::GateTXDecoder()
    : state_(StepReset)
    , decode_data_(0)
    , decode_count_bit_(0)
    , te_last_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Gate TX";
    base_.flag = PROTOCOL_FLAG;
}

GateTXDecoder::~GateTXDecoder() {}

void* GateTXDecoder::alloc() {
    // Single static instance — avoids boot-time heap fragmentation (see PrincetonDecoder).
    static GateTXDecoder instance;
    return &instance;
}

void GateTXDecoder::freeInstance(void* context) {
    (void)context;  // static instance, nothing to free
}

void GateTXDecoder::resetInstance(void* context) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self) return;
    self->state_            = StepReset;
    self->decode_data_      = 0;
    self->decode_count_bit_ = 0;
    self->te_last_          = 0;
}

// ============================================================
// feed() — Gate TX decoder state machine
//
// Ported from Flipper Zero lib/subghz/protocols/gate_tx.c
// (subghz_protocol_decoder_gate_tx_feed).
//
// Gate TX OOK encoding (Flipper constants):
//   Bit 0: LOW for 1×TE_SHORT, HIGH for 1×TE_LONG   (LOW short,  HIGH long)
//   Bit 1: LOW for 1×TE_LONG,  HIGH for 1×TE_SHORT  (LOW long,   HIGH short)
//   Preamble:  LOW 47×TE (~16.5 ms, tolerance ±4.7 ms), then HIGH "start bit"
//             of TE_LONG (~700 µs, tolerance ±300 µs).
//   End of frame: LOW ≥ 10×TE_SHORT + te_delta (~3.6 ms).
//
// Unlike Princeton, GateTX fires the callback on the first fully-decoded
// frame — no repeat-confirmation guard.
// ============================================================

void GateTXDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self) return;

    switch (self->state_) {

    case StepReset:
        // Wait for the preamble LOW (~47×TE_SHORT, with very wide tolerance).
        if ((!level) &&
            (duration_diff(static_cast<float>(duration_us),
                           static_cast<float>(TE_SHORT * PREAMBLE_GUARD_TE)) <
             static_cast<float>(TE_DELTA * PREAMBLE_GUARD_TE))) {
            ESP_LOGD(TAG, "Preamble detected: %lu us", (unsigned long)duration_us);
            self->state_ = StepFoundStartBit;
        }
        break;

    case StepFoundStartBit:
        // Wait for the HIGH start bit (~TE_LONG, tolerance ±3×TE_DELTA).
        if (level &&
            (duration_diff(static_cast<float>(duration_us),
                           static_cast<float>(TE_LONG)) <
             static_cast<float>(TE_DELTA * 3))) {
            ESP_LOGD(TAG, "Start bit detected: %lu us", (unsigned long)duration_us);
            self->state_            = StepSaveDuration;
            self->decode_data_      = 0;
            self->decode_count_bit_ = 0;
        } else {
            // Unexpected pattern → back to looking for preamble.
            self->state_ = StepReset;
        }
        break;

    case StepSaveDuration:
        // Wait for the LOW half of a bit (or end-of-frame).
        if (!level) {
            // End-of-frame: long LOW (≥ 10×TE_SHORT + te_delta).
            if (duration_us >=
                ((uint32_t)TE_SHORT * 10 + TE_DELTA)) {
                // Finalise: if we have MIN_COUNT_BIT bits, fire callback.
                if (self->decode_count_bit_ == MIN_COUNT_BIT) {
                    ESP_LOGI(TAG,
                             "GateTX decoded: key=0x%016llX, bits=%u",
                             (unsigned long long)self->decode_data_,
                             self->decode_count_bit_);

                    if (self->base_.callback) {
                        self->base_.callback(&self->base_,
                                             self->base_.callback_context);
                    }
                } else {
                    ESP_LOGW(TAG,
                             "GateTX end-of-frame with %u bits (expected %u) — resetting",
                             self->decode_count_bit_, MIN_COUNT_BIT);
                }
                // Reset for next preamble.
                self->decode_data_      = 0;
                self->decode_count_bit_ = 0;
                self->te_last_          = 0;
                self->state_            = StepFoundStartBit;
                break;
            }

            // Otherwise, save LOW duration as te_last and advance to CheckDuration.
            self->te_last_ = duration_us;
            self->state_   = StepCheckDuration;
        }
        break;

    case StepCheckDuration:
        // Wait for the HIGH half of the bit.
        if (level) {
            // Classify bit using BOTH the saved LOW (te_last_) and the current HIGH.
            if ((duration_diff(static_cast<float>(self->te_last_),
                               static_cast<float>(TE_SHORT)) < TE_DELTA) &&
                (duration_diff(static_cast<float>(duration_us),
                               static_cast<float>(TE_LONG))  < (TE_DELTA * 3))) {
                // bit 0: LOW=short, HIGH=long
                self->decode_data_ = (self->decode_data_ << 1) | 0;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else if ((duration_diff(static_cast<float>(self->te_last_),
                                      static_cast<float>(TE_LONG))  < (TE_DELTA * 3)) &&
                       (duration_diff(static_cast<float>(duration_us),
                                      static_cast<float>(TE_SHORT)) < TE_DELTA)) {
                // bit 1: LOW=long, HIGH=short
                self->decode_data_ = (self->decode_data_ << 1) | 1;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else {
                // Pattern doesn't match either bit shape → reset.
                self->state_ = StepReset;
            }
        } else {
            // Got a LOW where we expected a HIGH → reset.
            self->state_ = StepReset;
        }
        break;
    }
}

// ============================================================

uint8_t GateTXDecoder::getHashData(void* context) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self || self->decode_data_ == 0) return 0;

    uint8_t hash = 0;
    for (size_t i = 0; i < 8; i++) {
        hash += (self->decode_data_ >> (i * 8)) & 0xFF;
    }
    return hash;
}

void GateTXDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self || self->decode_data_ == 0) return;

    file.print("Protocol: Gate TX\n");
    file.print("Bit: ");
    file.print(self->decode_count_bit_);
    file.print("\n");
    file.print("Data: ");
    char hex[17];
    snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)self->decode_data_);
    file.print(hex);
    file.print("\n");
    file.print("TE: ");
    file.print(TE_SHORT);
    file.print("\n");
    file.print("Repeat: 1\n");
}

bool GateTXDecoder::deserialize(void* context, fs::File& file) {
    // Use existing GateTXProtocol::parse() for file-based loading.
    // This is a stub for interface completeness.
    (void)context;
    (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use GateTXProtocol::parse()");
    return false;
}