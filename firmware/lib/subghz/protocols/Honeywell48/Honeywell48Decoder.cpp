#include "Honeywell48Decoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cstring>
#include <cstdio>

static const char* TAG = "Honeywell48Decoder";

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
    : state_(WAIT_PREAMBLE)
    , te_(0)
    , key_(0)
    , bit_count_(0)
    , last_high_dur_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Honeywell 48bit";
    base_.flag = PROTOCOL_FLAG;
}

Honeywell48Decoder::~Honeywell48Decoder() {}

void* Honeywell48Decoder::alloc() { return new Honeywell48Decoder(); }
void Honeywell48Decoder::freeInstance(void* context) { delete static_cast<Honeywell48Decoder*>(context); }

void Honeywell48Decoder::resetInstance(void* context) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self) return;
    self->state_ = WAIT_PREAMBLE;
    self->te_ = 0;
    self->key_ = 0;
    self->bit_count_ = 0;
    self->last_high_dur_ = 0;
}

void Honeywell48Decoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self) return;

    switch (self->state_) {

    case WAIT_PREAMBLE:
        // Honeywell preamble: 12×TE HIGH
        if (level && duration_us > PREAMBLE_MIN) {
            self->state_ = WAIT_TE;
            self->te_ = 0;
            self->key_ = 0;
            self->bit_count_ = 0;
            self->last_high_dur_ = duration_us;
        }
        break;

    case WAIT_TE:
        if (!level && duration_us >= TE_MIN && duration_us <= TE_MAX) {
            self->te_ = duration_us;
            self->state_ = DECODE_BITS;
        } else if (level) {
            self->state_ = WAIT_PREAMBLE;
        }
        break;

    case DECODE_BITS:
        if (level) {
            // Honeywell: 1×TE high = bit 0, 3×TE high = bit 1 (same as Princeton)
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

        if (self->bit_count_ >= EXPECTED_BITS) {
            self->state_ = DONE;
            ESP_LOGI(TAG, "Honeywell48 decoded: key=0x%012llX, TE=%lu us",
                     (unsigned long long)(self->key_ & 0xFFFFFFFFFFFFULL),
                     (unsigned long)self->te_);
            if (self->base_.callback)
                self->base_.callback(&self->base_, self->base_.callback_context);
        }
        break;

    case DONE:
        if (level && duration_us > PREAMBLE_MIN) {
            resetInstance(self);
            self->last_high_dur_ = duration_us;
            self->state_ = WAIT_TE;
        }
        break;
    }
}

uint8_t Honeywell48Decoder::getHashData(void* context) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self || self->key_ == 0) return 0;
    uint8_t hash = 0;
    uint8_t bytes[6];
    for (size_t i = 0; i < 6; i++) {
        bytes[i] = (self->key_ >> (i * 8)) & 0xFF;
        hash += bytes[i];
    }
    return hash;
}

void Honeywell48Decoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<Honeywell48Decoder*>(context);
    if (!self || self->key_ == 0) return;
    file.print("Protocol: Honeywell 48bit\n");
    file.print("Key: ");
    char hex[17];
    snprintf(hex, sizeof(hex), "%012llX", (unsigned long long)(self->key_ & 0xFFFFFFFFFFFFULL));
    file.print(hex);
    file.print("\nTE: ");
    file.print(self->te_);
    file.print("\nRepeat: 1\n");
}

bool Honeywell48Decoder::deserialize(void* context, fs::File& file) {
    (void)context;
    (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use Honeywell48FileParser::parse()");
    return false;
}
