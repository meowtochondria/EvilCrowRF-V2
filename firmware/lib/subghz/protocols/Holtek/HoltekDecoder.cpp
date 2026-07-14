#include "HoltekDecoder.h"
#include "esp_log.h"
#include <FS.h>
#include <cstring>
#include <cstdio>

static const char* TAG = "HoltekDecoder";

const SubGhzProtocolDecoderVTable holtek_decoder_vtable = {
    .alloc = HoltekDecoder::alloc, .free = HoltekDecoder::freeInstance,
    .feed = HoltekDecoder::feed, .reset = HoltekDecoder::resetInstance,
    .get_hash_data = HoltekDecoder::getHashData,
    .serialize = HoltekDecoder::serialize, .deserialize = HoltekDecoder::deserialize,
};

const SubGhzProtocolDecoderVTable* HoltekDecoder::vTable() { return &holtek_decoder_vtable; }

HoltekDecoder::HoltekDecoder()
    : state_(WAIT_PREAMBLE), te_(0), address_(0), data_val_(0),
      bit_count_(0), last_high_dur_(0)
{
    memset(&base_, 0, sizeof(base_));
    base_.protocol_name = "Holtek";
    base_.flag = PROTOCOL_FLAG;
}

HoltekDecoder::~HoltekDecoder() {}
void* HoltekDecoder::alloc() { return new HoltekDecoder(); }
void HoltekDecoder::freeInstance(void* context) { delete static_cast<HoltekDecoder*>(context); }

void HoltekDecoder::resetInstance(void* context) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return;
    self->state_ = WAIT_PREAMBLE; self->te_ = 0; self->address_ = 0;
    self->data_val_ = 0; self->bit_count_ = 0; self->last_high_dur_ = 0;
}

void HoltekDecoder::feed(void* context, bool level, uint32_t duration_us) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return;

    switch (self->state_) {
    case WAIT_PREAMBLE:
        // Holtek preamble: 12×TE HIGH — very long pulse
        if (level && duration_us > PREAMBLE_MIN) {
            self->state_ = WAIT_TE; self->te_ = 0; self->address_ = 0;
            self->data_val_ = 0; self->bit_count_ = 0; self->last_high_dur_ = duration_us;
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
            // Holtek: bit 0 = 1×TE high, bit 1 = 3×TE high
            float ratio = (float)duration_us / (float)self->te_;
            if (ratio > 1.8f && ratio < 4.2f) {
                // Bit 1
                if (self->bit_count_ < 12) {
                    self->address_ = (self->address_ << 1) | 1;
                } else {
                    self->data_val_ = (self->data_val_ << 1) | 1;
                }
                self->bit_count_++;
            } else if (ratio > 0.2f && ratio < 1.8f) {
                // Bit 0
                if (self->bit_count_ < 12) {
                    self->address_ = (self->address_ << 1);
                } else {
                    self->data_val_ = (self->data_val_ << 1);
                }
                self->bit_count_++;
            }
            self->last_high_dur_ = duration_us;
        }
        // 12 address bits + 4 data bits = 16 total
        if (self->bit_count_ >= 16) {
            self->state_ = DONE;
            ESP_LOGI(TAG, "Holtek decoded: addr=0x%03X, data=0x%X, TE=%lu us",
                     self->address_, self->data_val_, (unsigned long)self->te_);
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

uint8_t HoltekDecoder::getHashData(void* context) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return 0;
    uint8_t hash = 0;
    hash += (uint8_t)(self->address_ & 0xFF);
    hash += (uint8_t)((self->address_ >> 8) & 0xFF);
    hash += self->data_val_;
    return hash;
}

void HoltekDecoder::serialize(void* context, fs::File& file) {
    auto* self = static_cast<HoltekDecoder*>(context);
    if (!self) return;
    file.print("Protocol: Holtek\n");
    file.print("Address: ");
    char hex[9]; snprintf(hex, sizeof(hex), "%03X", self->address_);
    file.print(hex); file.print("\n");
    file.print("Data: ");
    snprintf(hex, sizeof(hex), "%X", self->data_val_);
    file.print(hex); file.print("\n");
    file.print("TE: "); file.print(self->te_); file.print("\n");
    file.print("Repeat: 1\n");
}

bool HoltekDecoder::deserialize(void* context, fs::File& file) {
    (void)context; (void)file;
    ESP_LOGW(TAG, "deserialize() not implemented — use HoltekProtocol::parse()");
    return false;
}
