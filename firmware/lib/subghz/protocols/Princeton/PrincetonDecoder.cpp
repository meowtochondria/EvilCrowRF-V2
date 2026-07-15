#include "PrincetonDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cstring>
#include <cstdio>
#include <cmath>

static const char* TAG = "PrincetonDecoder";

/** Port of DURATION_DIFF from Flipper blocks/const.h. */
static inline float duration_diff(float a, float b) {
    return fabsf(a - b);
}

const SubGhzProtocolDecoderVTable princeton_decoder_vtable = {
    .alloc         = PrincetonDecoder::alloc,
    .free          = PrincetonDecoder::freeInstance,
    .feed          = PrincetonDecoder::feed,
    .reset         = PrincetonDecoder::resetInstance,
    .get_hash_data = PrincetonDecoder::getHashData,
    .serialize     = PrincetonDecoder::serialize,
    .deserialize   = PrincetonDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* PrincetonDecoder::vTable() {
    return &princeton_decoder_vtable;
}

// ============================================================

PrincetonDecoder::PrincetonDecoder()
    : state_(StepReset)
    , decode_data_(0)
    , decode_count_bit_(0)
    , last_data_(0)
    , te_(0)
    , te_last_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Princeton";
    base_.flag = PROTOCOL_FLAG;
}

PrincetonDecoder::~PrincetonDecoder() {}

void* PrincetonDecoder::alloc() {
    // Use a single static instance instead of heap allocation. This avoids
    // 14 boot-time `new` calls (2 modules x 7 decoders) that fragment the
    // already-tight ESP32 heap and break the SoftAP DHCP server. reset() is
    // called between captures, so shared state is safe.
    static PrincetonDecoder instance;
    return &instance;
}

void PrincetonDecoder::freeInstance(void* context) {
    // Instance is static (lives for program lifetime) — nothing to free.
    (void)context;
}

void PrincetonDecoder::resetInstance(void* context) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self) return;
    self->state_           = StepReset;
    self->decode_data_     = 0;
    self->decode_count_bit_ = 0;
    self->te_              = 0;
    self->te_last_         = 0;
    // Note: last_data_ is intentionally preserved across resetInstance()
    // so that the "two consecutive frames with same key" check still works
    // when the receiver fan-out resets us between frames (matches Flipper).
}

// ============================================================
// feed() — Princeton decoder state machine
//
// Ported from Flipper Zero lib/subghz/protocols/princeton.c
// (subghz_protocol_decoder_princeton_feed).
//
// Princeton OOK encoding (Flipper constants):
//   Bit 0: HIGH for 1×TE_SHORT, LOW for 1×TE_LONG  (HIGH short, LOW long)
//   Bit 1: HIGH for 1×TE_LONG,  LOW for 1×TE_SHORT (HIGH long,  LOW short)
//   Preamble: HIGH 36×TE followed by a guard LOW (~30×TE, decoder accepts
//             any LOW within TE_SHORT*36 ± TE_DELTA*36, i.e. ~3.2–24.8 ms).
//   End of frame: LOW ≥ 2×TE_LONG  (long guard, indicates frame is done).
//
// The callback only fires when a frame with MIN_COUNT_BIT bits matches the
// previously decoded frame (last_data_ == decode_data_ && last_data_), which
// is Flipper's repeat-confirmation guard.
// ============================================================

void PrincetonDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self) return;

    switch (self->state_) {

    case StepReset:
        // Wait for the preamble guard LOW (~36×TE_SHORT, with very wide tolerance).
        // Range: TE_SHORT*36 ± TE_DELTA*36 = 14040 ± 10800 = [3240, 24840] us.
        if ((!level) &&
            (duration_diff(static_cast<float>(duration_us),
                           static_cast<float>(TE_SHORT * PREAMBLE_GUARD_TE)) <
             static_cast<float>(TE_DELTA * PREAMBLE_GUARD_TE))) {
            ESP_LOGI(TAG, "Preamble guard detected: %lu us", (unsigned long)duration_us);
            self->state_           = StepSaveDuration;
            self->decode_data_     = 0;
            self->decode_count_bit_ = 0;
            self->te_              = 0;
        }
        // else: log every ~200th edge at INFO level so we can see the decoder
        // is alive but receiving edges outside the preamble guard timing window.
        {
            static uint32_t resetSkipCount = 0;
            if ((resetSkipCount % 200) == 0) {
                ESP_LOGI(TAG, "StepReset: waiting for preamble guard LOW (3.2-24.8 ms); "
                         "got level=%d duration=%lu us (skipped %u similar)",
                         (int)level, (unsigned long)duration_us,
                         (unsigned)(resetSkipCount % 200 == 0 ? 200 : 0));
            }
            resetSkipCount++;
        }
        break;

    case StepSaveDuration:
        // Wait for the HIGH half of a bit. Save its duration and accumulate
        // it into the running TE total.
        if (level) {
            self->te_last_ = duration_us;
            self->te_     += duration_us;
            self->state_   = StepCheckDuration;
        }
        // HIGHs are unexpected here; stay in this state until we see one.
        break;

    case StepCheckDuration:
        // Wait for the LOW half of a bit (or the end-of-frame guard LOW).
        if (!level) {
            // End-of-frame guard: LOW ≥ 2×TE_LONG. Finalise and fire callback
            // if we have MIN_COUNT_BIT bits AND the previous frame matched.
            if (duration_us >= (TE_LONG * 2)) {
                if (self->decode_count_bit_ == MIN_COUNT_BIT) {
                    if ((self->last_data_ == self->decode_data_) && self->last_data_) {
                        // Repeat confirmed — fire callback.
                        // TE total accounts for 4×TE per bit (HIGH+LOW pair)
                        // plus 1×TE from the preamble sync HIGH.
                        // decode_count_bit * 4 + 1 matches Flipper princeton.c:273.
                        uint32_t avg_te = self->te_ /
                            (self->decode_count_bit_ * 4 + 1);

                        ESP_LOGI(TAG,
                                 "Princeton decoded: key=0x%016llX, bits=%u, TE=%lu us",
                                 (unsigned long long)self->decode_data_,
                                 self->decode_count_bit_,
                                 (unsigned long)avg_te);

                        self->te_ = avg_te;

                        if (self->base_.callback) {
                            self->base_.callback(&self->base_,
                                                 self->base_.callback_context);
                        }
                    } else {
                        // First frame — prime last_data_ for repeat check.
                        ESP_LOGI(TAG,
                                 "Princeton frame decoded (waiting for repeat): "
                                 "key=0x%016llX, bits=%u",
                                 (unsigned long long)self->decode_data_,
                                 self->decode_count_bit_);
                    }
                } else {
                    ESP_LOGW(TAG,
                             "Princeton end-of-frame with %u bits (expected %u) — resetting",
                             self->decode_count_bit_, MIN_COUNT_BIT);
                }

                // Remember this frame for the next repeat check, then reset
                // for the next frame's preamble guard.
                self->last_data_        = self->decode_data_;
                self->decode_data_      = 0;
                self->decode_count_bit_ = 0;
                self->te_               = 0;
                self->state_            = StepSaveDuration;
                break;
            }

            // Accumulate LOW into TE total.
            self->te_ += duration_us;

            // Classify the bit using BOTH the previous HIGH duration (te_last_)
            // and the current LOW duration (duration_us).
            if ((duration_diff(static_cast<float>(self->te_last_),
                               static_cast<float>(TE_SHORT)) < TE_DELTA) &&
                (duration_diff(static_cast<float>(duration_us),
                               static_cast<float>(TE_LONG))  < (TE_DELTA * 3))) {
                // bit 0: HIGH=short, LOW=long
                self->decode_data_ = (self->decode_data_ << 1) | 0;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else if ((duration_diff(static_cast<float>(self->te_last_),
                                      static_cast<float>(TE_LONG))  < (TE_DELTA * 3)) &&
                       (duration_diff(static_cast<float>(duration_us),
                                      static_cast<float>(TE_SHORT)) < TE_DELTA)) {
                // bit 1: HIGH=long, LOW=short
                self->decode_data_ = (self->decode_data_ << 1) | 1;
                self->decode_count_bit_++;
                self->state_ = StepSaveDuration;
            } else {
                // Pattern doesn't match either bit shape → reset.
                // Log at INFO level so it's visible with default log settings.
                ESP_LOGI(TAG,
                         "Bit mismatch (bits so far=%u, last_data=0x%016llX): "
                         "te_last=%lu duration=%lu → resetting",
                         self->decode_count_bit_,
                         (unsigned long long)self->last_data_,
                         (unsigned long)self->te_last_,
                         (unsigned long)duration_us);
                self->state_ = StepReset;
            }
        } else {
            // Got a HIGH where we expected a LOW → reset.
            ESP_LOGI(TAG, "Expected LOW, got HIGH (bits=%u) → resetting",
                     self->decode_count_bit_);
            self->state_ = StepReset;
        }
        break;
    }
}

// ============================================================

uint8_t PrincetonDecoder::getHashData(void* context) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self || self->decode_data_ == 0) return 0;

    uint8_t hash = 0;
    uint8_t bytes[8];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        bytes[i] = (self->decode_data_ >> (i * 8)) & 0xFF;
        hash += bytes[i];
    }
    return hash;
}

void PrincetonDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self || self->decode_data_ == 0) return;

    file.print("Protocol: Princeton\n");
    file.print("Bit: ");
    file.print(self->decode_count_bit_);
    file.print("\n");
    file.print("Key: ");
    char hex[17];
    snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)self->decode_data_);
    file.print(hex);
    file.print("\n");
    file.print("TE: ");
    file.print(self->te_);
    file.print("\n");
    file.print("Repeat: 1\n");
}

bool PrincetonDecoder::deserialize(void* context, fs::File& file) {
    // Use existing PrincetonProtocol::parse() for file-based loading.
    // This is a stub for interface completeness.
    (void)context;
    (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use PrincetonProtocol::parse()");
    return false;
}