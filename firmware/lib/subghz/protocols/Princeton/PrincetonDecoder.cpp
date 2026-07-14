#include "PrincetonDecoder.h"
#include "esp_log.h"
#include <cstring>
#include <cstdio>

static const char* TAG = "PrincetonDecoder";

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
    : state_(WAIT_PREAMBLE)
    , expected_bits_(DEFAULT_BITS)
    , te_(0)
    , key_(0)
    , bit_count_(0)
    , last_high_dur_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Princeton";
    base_.flag = PROTOCOL_FLAG;
}

PrincetonDecoder::~PrincetonDecoder() {}

void* PrincetonDecoder::alloc() {
    return new PrincetonDecoder();
}

void PrincetonDecoder::freeInstance(void* context) {
    delete static_cast<PrincetonDecoder*>(context);
}

void PrincetonDecoder::resetInstance(void* context) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self) return;
    self->state_ = WAIT_PREAMBLE;
    self->te_ = 0;
    self->key_ = 0;
    self->bit_count_ = 0;
    self->last_high_dur_ = 0;
}

// ============================================================
// feed() — real-time bit decoding
//
// Princeton OOK encoding:
//   Bit 0: HIGH for 1×TE, LOW for 3×TE
//   Bit 1: HIGH for 3×TE, LOW for 1×TE
//
// The decoder:
//   1. WAIT_PREAMBLE — waits for a long HIGH (> 800 µs) to start
//   2. WAIT_TE — measures the short LOW duration as TE
//   3. DECODE_BITS — on each HIGH edge, compares HIGH duration to
//      determine if it's a short (1×TE → bit 0) or long (3×TE → bit 1)
// ============================================================

void PrincetonDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self) return;

    switch (self->state_) {

    case WAIT_PREAMBLE:
        // Wait for a long HIGH pulse (preamble)
        if (level && duration_us > PREAMBLE_MIN) {
            self->state_ = WAIT_TE;
            self->te_ = 0;
            self->key_ = 0;
            self->bit_count_ = 0;
            self->last_high_dur_ = duration_us;
            ESP_LOGD(TAG, "Preamble detected: %lu us", (unsigned long)duration_us);
        }
        break;

    case WAIT_TE:
        if (!level) {
            // LOW pulse — measure as potential TE
            if (duration_us >= TE_MIN && duration_us <= TE_MAX) {
                self->te_ = duration_us;
                self->state_ = DECODE_BITS;
                ESP_LOGD(TAG, "TE measured: %lu us", (unsigned long)self->te_);
            } else {
                // Invalid TE — reset
                self->state_ = WAIT_PREAMBLE;
            }
        } else {
            // Unexpected HIGH in WAIT_TE — reset
            self->state_ = WAIT_PREAMBLE;
        }
        break;

    case DECODE_BITS:
        if (level) {
            // HIGH pulse — determine bit value based on duration
            uint32_t te = self->te_;
            float ratio = static_cast<float>(duration_us) / static_cast<float>(te);

            // Short HIGH (≈1×TE) → bit 0
            // Long HIGH (≈3×TE) → bit 1
            if (ratio > 1.8f && ratio < 4.2f) {
                // Long pulse → bit 1
                self->key_ = (self->key_ << 1) | 1;
                self->bit_count_++;
            } else if (ratio > 0.2f && ratio < 1.8f) {
                // Short pulse → bit 0
                self->key_ = (self->key_ << 1);
                self->bit_count_++;
            }
            // If ratio doesn't match either, skip this pulse (noise)

            self->last_high_dur_ = duration_us;
        }

        // Check if we have decoded all expected bits
        if (self->bit_count_ >= self->expected_bits_) {
            self->state_ = DONE;

            ESP_LOGI(TAG, "Princeton decoded: key=0x%08llX, bits=%u, TE=%lu us",
                     (unsigned long long)self->key_,
                     self->bit_count_,
                     (unsigned long)self->te_);

            // Fire callback
            if (self->base_.callback) {
                self->base_.callback(&self->base_, self->base_.callback_context);
            }
        }
        break;

    case DONE:
        // Already decoded one frame; if callback is still set, a new frame
        // might restart the process. For simplicity, just reset on long HIGH.
        if (level && duration_us > PREAMBLE_MIN) {
            self->state_ = WAIT_TE;
            self->te_ = 0;
            self->key_ = 0;
            self->bit_count_ = 0;
            self->last_high_dur_ = duration_us;
        }
        break;
    }
}

// ============================================================

uint8_t PrincetonDecoder::getHashData(void* context) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self || self->key_ == 0) return 0;

    uint8_t hash = 0;
    uint8_t bytes[8];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        bytes[i] = (self->key_ >> (i * 8)) & 0xFF;
        hash += bytes[i];
    }
    return hash;
}

void PrincetonDecoder::serialize(void* context, class File& file) {
    auto* self = static_cast<PrincetonDecoder*>(context);
    if (!self || self->key_ == 0) return;

    file.print("Protocol: Princeton\n");
    file.print("Bit: ");
    file.print(self->bit_count_);
    file.print("\n");
    file.print("Key: ");
    // Print as hex
    char hex[17];
    snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)self->key_);
    file.print(hex);
    file.print("\n");
    file.print("TE: ");
    file.print(self->te_);
    file.print("\n");
    file.print("Repeat: 1\n");
}

bool PrincetonDecoder::deserialize(void* context, class File& file) {
    // Use existing PrincetonProtocol::parse() for file-based loading.
    // This is a stub for interface completeness.
    (void)context;
    (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use PrincetonProtocol::parse()");
    return false;
}
