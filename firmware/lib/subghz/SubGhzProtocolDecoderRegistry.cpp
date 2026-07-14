#include "SubGhzProtocolDecoderRegistry.h"
#include "esp_log.h"

static const char* TAG = "SubGhzDecoderRegistry";

SubGhzProtocolDecoderRegistry& SubGhzProtocolDecoderRegistry::instance() {
    static SubGhzProtocolDecoderRegistry instance;
    return instance;
}

void SubGhzProtocolDecoderRegistry::registerDecoder(
    const std::string& name,
    SubGhzProtocolFlag flag,
    const SubGhzProtocolDecoderVTable* vtable)
{
    if (!vtable) {
        ESP_LOGW(TAG, "Cannot register '%s': null vtable", name.c_str());
        return;
    }
    if (!vtable->alloc || !vtable->feed || !vtable->reset) {
        ESP_LOGW(TAG, "Cannot register '%s': vtable missing alloc/feed/reset", name.c_str());
        return;
    }

    registry_[name] = {vtable, flag};
    ESP_LOGI(TAG, "Registered decoder '%s' (flag=0x%08lx)", name.c_str(), (unsigned long)flag);
}

const SubGhzProtocolDecoderRegistry::Entry*
SubGhzProtocolDecoderRegistry::find(const std::string& name) const {
    auto it = registry_.find(name);
    if (it != registry_.end()) {
        return &it->second;
    }
    return nullptr;
}
