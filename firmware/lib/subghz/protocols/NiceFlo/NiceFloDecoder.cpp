#include "NiceFloDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cstring>
#include <cstdio>

static const char* TAG = "NiceFloDecoder";

const SubGhzProtocolDecoderVTable niceflo_decoder_vtable = {
    .alloc = NiceFloDecoder::alloc, .free = NiceFloDecoder::freeInstance,
    .feed = NiceFloDecoder::feed, .reset = NiceFloDecoder::resetInstance,
    .get_hash_data = NiceFloDecoder::getHashData,
    .serialize = NiceFloDecoder::serialize, .deserialize = NiceFloDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* NiceFloDecoder::vTable() { return &niceflo_decoder_vtable; }

NiceFloDecoder::NiceFloDecoder()
    : state_(WAIT_PREAMBLE), te_(0), key_(0), bit_count_(0),
      expected_bits_(DEFAULT_BITS), last_high_dur_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Nice FLO";
    base_.flag = PROTOCOL_FLAG;
}

NiceFloDecoder::~NiceFloDecoder() {}
void* NiceFloDecoder::alloc() { return new NiceFloDecoder(); }
void NiceFloDecoder::freeInstance(void* context) { delete static_cast<NiceFloDecoder*>(context); }

void NiceFloDecoder::resetInstance(void* context) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self) return;
    self->state_ = WAIT_PREAMBLE; self->te_ = 0; self->key_ = 0;
    self->bit_count_ = 0; self->last_high_dur_ = 0;
}

void NiceFloDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<NiceFloDecoder*>(context);
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
            // Nice FLO asymmetric: bit 0 = 1×TE high, bit 1 = 3×TE high
            float ratio = (float)duration_us / (float)self->te_;
            if (ratio > 1.8f && ratio < 4.2f) {
                self->key_ = (self->key_ << 1) | 1; self->bit_count_++;
            } else if (ratio > 0.2f && ratio < 1.8f) {
                self->key_ = (self->key_ << 1); self->bit_count_++;
            }
            self->last_high_dur_ = duration_us;
        }
        if (self->bit_count_ >= self->expected_bits_) {
            self->state_ = DONE;
            ESP_LOGI(TAG, "NiceFLO decoded: key=0x%08llX, bits=%u",
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

uint8_t NiceFloDecoder::getHashData(void* context) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self || self->key_ == 0) return 0;
    uint8_t hash = 0;
    for (size_t i = 0; i < 8; i++) hash += (self->key_ >> (i * 8)) & 0xFF;
    return hash;
}

void NiceFloDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<NiceFloDecoder*>(context);
    if (!self || self->key_ == 0) return;
    file.print("Protocol: Nice FLO\n");
    file.print("Bit: "); file.print(self->bit_count_); file.print("\n");
    file.print("Button: ");
    char hex[17]; snprintf(hex, sizeof(hex), "%04X", (unsigned)(self->key_ & 0xF));
    file.print(hex); file.print("\n");
    file.print("Serial: ");
    snprintf(hex, sizeof(hex), "%016llX", (unsigned long long)(self->key_ >> 4));
    file.print(hex); file.print("\n");
    file.print("TE: "); file.print(self->te_); file.print("\n");
    file.print("Repeat: 1\n");
}

bool NiceFloDecoder::deserialize(void* context, fs::File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use NiceFloProtocol::parse()");
    return false;
}
