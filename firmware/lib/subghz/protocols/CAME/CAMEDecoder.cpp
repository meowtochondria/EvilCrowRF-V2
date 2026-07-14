#include "CAMEDecoder.h"
#include "esp_log.h"
#include <cstring>
#include <cstdio>

static const char* TAG = "CAMEDecoder";

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
    : state_(WAIT_PREAMBLE)
    , te_(0)
    , key_(0)
    , bit_count_(0)
    , expected_bits_(DEFAULT_BITS)
    , last_high_dur_(0)
    , expected_preamble_min_(1200)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "CAME";
    base_.flag = PROTOCOL_FLAG;
}

CAMEDecoder::~CAMEDecoder() {}

void* CAMEDecoder::alloc() { return new CAMEDecoder(); }
void CAMEDecoder::freeInstance(void* context) { delete static_cast<CAMEDecoder*>(context); }

void CAMEDecoder::resetInstance(void* context) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self) return;
    self->state_ = WAIT_PREAMBLE;
    self->te_ = 0;
    self->key_ = 0;
    self->bit_count_ = 0;
    self->last_high_dur_ = 0;
}

void CAMEDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self) return;

    switch (self->state_) {

    case WAIT_PREAMBLE:
        // Look for a long HIGH that starts the preamble (≥ 4×TE typical)
        if (level && duration_us > self->expected_preamble_min_) {
            self->state_ = WAIT_TE;
            self->te_ = 0;
            self->key_ = 0;
            self->bit_count_ = 0;
            self->last_high_dur_ = duration_us;
        }
        break;

    case WAIT_TE:
        if (!level && duration_us >= TE_MIN && duration_us <= TE_MAX) {
            // First LOW after preamble — measure as TE
            self->te_ = duration_us;
            self->state_ = DECODE_BITS;
        } else if (level) {
            self->state_ = WAIT_PREAMBLE;
        }
        break;

    case DECODE_BITS:
        if (level) {
            // CAME: bit 0 = short high (1×TE), bit 1 = long high (3×TE)
            float ratio = static_cast<float>(duration_us) / static_cast<float>(self->te_);

            if (ratio > 1.8f && ratio < 4.2f) {
                // Long HIGH → bit 1
                self->key_ = (self->key_ << 1) | 1;
                self->bit_count_++;
            } else if (ratio > 0.2f && ratio < 1.8f) {
                // Short HIGH → bit 0
                self->key_ = (self->key_ << 1);
                self->bit_count_++;
            }
            self->last_high_dur_ = duration_us;
        }

        if (self->bit_count_ >= self->expected_bits_) {
            self->state_ = DONE;
            ESP_LOGI(TAG, "CAME decoded: key=0x%08llX, bits=%u, TE=%lu us",
                     (unsigned long long)self->key_, self->bit_count_,
                     (unsigned long)self->te_);
            if (self->base_.callback)
                self->base_.callback(&self->base_, self->base_.callback_context);
        }
        break;

    case DONE:
        if (level && duration_us > self->expected_preamble_min_) {
            resetInstance(self);
            self->last_high_dur_ = duration_us;
            self->state_ = WAIT_TE;
        }
        break;
    }
}

uint8_t CAMEDecoder::getHashData(void* context) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self || self->key_ == 0) return 0;
    uint8_t hash = 0;
    for (size_t i = 0; i < 8; i++)
        hash += (self->key_ >> (i * 8)) & 0xFF;
    return hash;
}

void CAMEDecoder::serialize(void* context, class File& file) {
    auto* self = static_cast<CAMEDecoder*>(context);
    if (!self || self->key_ == 0) return;
    file.print("Protocol: CAME\n");
    file.print("Bit: ");
    file.print(self->bit_count_);
    file.print("\nButton: ");
    char hex[17];
    snprintf(hex, sizeof(hex), "%04X", (unsigned)(self->key_ & 0xF));
    file.print(hex);
    file.print("\nSerial: ");
    snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)(self->key_ >> 4));
    file.print(hex);
    file.print("\nTE: ");
    file.print(self->te_);
    file.print("\nRepeat: 1\n");
}

bool CAMEDecoder::deserialize(void* context, class File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use CAMEProtocol::parse()");
    return false;
}
