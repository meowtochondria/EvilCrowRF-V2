#include "GateTXDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cstring>
#include <cstdio>

static const char* TAG = "GateTXDecoder";

const SubGhzProtocolDecoderVTable gatetx_decoder_vtable = {
    .alloc = GateTXDecoder::alloc, .free = GateTXDecoder::freeInstance,
    .feed = GateTXDecoder::feed, .reset = GateTXDecoder::resetInstance,
    .get_hash_data = GateTXDecoder::getHashData,
    .serialize = GateTXDecoder::serialize, .deserialize = GateTXDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* GateTXDecoder::vTable() { return &gatetx_decoder_vtable; }

GateTXDecoder::GateTXDecoder()
    : state_(WAIT_PREAMBLE), te_(0), key_(0), bit_count_(0),
      expected_bits_(DEFAULT_BITS), last_high_dur_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Gate TX";
    base_.flag = PROTOCOL_FLAG;
}
GateTXDecoder::~GateTXDecoder() {}
void* GateTXDecoder::alloc() { return new GateTXDecoder(); }
void GateTXDecoder::freeInstance(void* context) { delete static_cast<GateTXDecoder*>(context); }

void GateTXDecoder::resetInstance(void* context) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self) return;
    self->state_ = WAIT_PREAMBLE; self->te_ = 0; self->key_ = 0;
    self->bit_count_ = 0; self->last_high_dur_ = 0;
}

void GateTXDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self) return;

    switch (self->state_) {
    case WAIT_PREAMBLE:
        if (level && duration_us > PREAMBLE_MIN) {
            self->state_ = WAIT_TE; self->te_ = 0; self->key_ = 0;
            self->bit_count_ = 0; self->last_high_dur_ = duration_us;
        }
        break;
    case WAIT_TE:
        if (!level && duration_us >= TE_MIN && duration_us <= TE_MAX) {
            self->te_ = duration_us;
            self->state_ = DECODE_BITS;
        } else if (level) { self->state_ = WAIT_PREAMBLE; }
        break;
    case DECODE_BITS:
        if (level) {
            // Gate TX: bit 0 = 1×TE high, bit 1 = 2×TE high
            float ratio = (float)duration_us / (float)self->te_;
            if (ratio < 1.6f) {
                self->key_ = (self->key_ << 1); self->bit_count_++;
            } else if (ratio < 3.5f) {
                self->key_ = (self->key_ << 1) | 1; self->bit_count_++;
            }
            self->last_high_dur_ = duration_us;
        }
        if (self->bit_count_ >= self->expected_bits_) {
            self->state_ = DONE;
            ESP_LOGI(TAG, "GateTX decoded: key=0x%08llX, bits=%u",
                     (unsigned long long)self->key_, self->bit_count_);
            if (self->base_.callback)
                self->base_.callback(&self->base_, self->base_.callback_context);
        }
        break;
    case DONE:
        if (level && duration_us > PREAMBLE_MIN) {
            resetInstance(self);
            self->last_high_dur_ = duration_us; self->state_ = WAIT_TE;
        }
        break;
    }
}

uint8_t GateTXDecoder::getHashData(void* context) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self || self->key_ == 0) return 0;
    uint8_t hash = 0;
    for (size_t i = 0; i < 8; i++) hash += (self->key_ >> (i * 8)) & 0xFF;
    return hash;
}

void GateTXDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<GateTXDecoder*>(context);
    if (!self || self->key_ == 0) return;
    file.print("Protocol: Gate TX\n");
    file.print("Bit: "); file.print(self->bit_count_); file.print("\n");
    file.print("Data: ");
    char hex[17]; snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)self->key_);
    file.print(hex); file.print("\n");
    file.print("TE: "); file.print(self->te_); file.print("\n");
    file.print("Repeat: 1\n");
}

bool GateTXDecoder::deserialize(void* context, fs::File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use GateTXProtocol::parse()");
    return false;
}
