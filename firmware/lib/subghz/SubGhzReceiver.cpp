#include "SubGhzReceiver.h"
#include <cstring>
#include "esp_log.h"

static const char* TAG = "SubGhzReceiver";

SubGhzReceiver::SubGhzReceiver()
    : filter_(static_cast<SubGhzProtocolFlag>(0))
    , rx_callback_(nullptr)
    , rx_callback_ctx_(nullptr)
{
}

SubGhzReceiver::~SubGhzReceiver() {
    for (auto& slot : slots_) {
        if (slot.vtable && slot.vtable->free && slot.instance) {
            slot.vtable->free(slot.instance);
        }
        if (slot.base) {
            delete slot.base;
        }
    }
    slots_.clear();
}

void SubGhzReceiver::registerDecoder(
    const char* name,
    SubGhzProtocolFlag flag,
    const SubGhzProtocolDecoderVTable* vtable)
{
    if (!vtable || !vtable->alloc) {
        ESP_LOGW(TAG, "Cannot register '%s': no alloc in vtable", name ? name : "null");
        return;
    }

    // Allocate the decoder instance
    void* instance = vtable->alloc();
    if (!instance) {
        ESP_LOGE(TAG, "Failed to alloc decoder '%s'", name);
        return;
    }

    // Allocate the base struct
    SubGhzProtocolDecoderBase* base = new SubGhzProtocolDecoderBase();
    base->protocol_name    = name;
    base->flag             = flag;
    base->callback         = nullptr;
    base->callback_context = nullptr;

    Slot slot;
    slot.base     = base;
    slot.instance = instance;
    slot.vtable   = vtable;

    slots_.push_back(slot);

    ESP_LOGI(TAG, "Registered decoder '%s' (flag=0x%08lx)", name, (unsigned long)flag);
}

void SubGhzReceiver::decode(bool level, uint32_t duration_us) {
    for (auto& slot : slots_) {
        if ((slot.base->flag & filter_) != 0) {
            if (slot.vtable && slot.vtable->feed && slot.instance) {
                slot.vtable->feed(slot.instance, level, duration_us);
            }
        }
    }
}

void SubGhzReceiver::reset() {
    for (auto& slot : slots_) {
        if (slot.vtable && slot.vtable->reset && slot.instance) {
            slot.vtable->reset(slot.instance);
        }
    }
}

void SubGhzReceiver::setFilter(SubGhzProtocolFlag filter) {
    filter_ = filter;
    ESP_LOGD(TAG, "Filter set to 0x%08lx", (unsigned long)filter);
}

void SubGhzReceiver::setRxCallback(
    SubGhzProtocolDecoderRxCallback callback, void* context)
{
    rx_callback_     = callback;
    rx_callback_ctx_ = context;

    // Wire every slot's base callback to our trampoline.
    // When any decoder finishes a frame, it calls onSlotDecoded, which
    // forwards to the application-level rx_callback_.
    for (auto& slot : slots_) {
        subghz_protocol_decoder_base_set_callback(
            slot.base, onSlotDecoded, this);
    }
}

SubGhzProtocolDecoderBase* SubGhzReceiver::getDecoderByName(const char* name) {
    for (auto& slot : slots_) {
        if (slot.base && slot.base->protocol_name &&
            strcmp(slot.base->protocol_name, name) == 0)
        {
            return slot.base;
        }
    }
    return nullptr;
}

void* SubGhzReceiver::getDecoderInstance(const char* name) {
    for (auto& slot : slots_) {
        if (slot.base && slot.base->protocol_name &&
            strcmp(slot.base->protocol_name, name) == 0)
        {
            return slot.instance;
        }
    }
    return nullptr;
}

void SubGhzReceiver::onSlotDecoded(
    SubGhzProtocolDecoderBase* decoder, void* context)
{
    SubGhzReceiver* self = static_cast<SubGhzReceiver*>(context);
    if (self->rx_callback_) {
        self->rx_callback_(decoder, self->rx_callback_ctx_);
    }
}

bool SubGhzReceiver::getSlotByBase(
    const SubGhzProtocolDecoderBase* base,
    void*& instance,
    const SubGhzProtocolDecoderVTable*& vtable) const
{
    for (const auto& slot : slots_) {
        if (slot.base == base) {
            instance = slot.instance;
            vtable = slot.vtable;
            return true;
        }
    }
    return false;
}
