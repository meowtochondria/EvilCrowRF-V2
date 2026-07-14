#ifndef SUB_GHZ_PROTOCOL_DECODER_REGISTRY_H
#define SUB_GHZ_PROTOCOL_DECODER_REGISTRY_H

#include <unordered_map>
#include <string>
#include "SubGhzProtocolBase.h"
#include "SubGhzTypes.h"

/**
 * SubGhzProtocolDecoderRegistry — maps protocol name → decoder v-table + flag.
 *
 * Ported from Flipper's registry concept (protocol_items.c).
 * Separate from SubGhzProtocolRegistry (which manages file-parser protocols).
 *
 * Each real-time decoder that can be fed level/duration pairs registers
 * its v-table here. SubGhzReceiver uses this to instantiate decoder slots.
 */
class SubGhzProtocolDecoderRegistry {
public:
    /** Single entry: v-table + protocol flag. */
    struct Entry {
        const SubGhzProtocolDecoderVTable* vtable;
        SubGhzProtocolFlag flag;
    };

    static SubGhzProtocolDecoderRegistry& instance();

    /**
     * Register a real-time decoder.
     * @param name   Protocol name (e.g. "Princeton", "BinRAW")
     * @param flag   Capability flags
     * @param vtable Function table for feed/reset/alloc/...
     */
    void registerDecoder(
        const std::string& name,
        SubGhzProtocolFlag flag,
        const SubGhzProtocolDecoderVTable* vtable);

    /**
     * Look up a decoder entry by name.
     * @return Entry pointer, or nullptr if not found.
     */
    const Entry* find(const std::string& name) const;

    /**
     * Iterate all registered decoders.
     */
    const std::unordered_map<std::string, Entry>& all() const { return registry_; }

private:
    SubGhzProtocolDecoderRegistry() = default;
    std::unordered_map<std::string, Entry> registry_;
};

/**
 * Convenience: register a decoder into the singleton.
 * Intended for use in static initializers (RegisterAllProtocols).
 */
inline void registerSubGhzDecoder(
    const std::string& name,
    SubGhzProtocolFlag flag,
    const SubGhzProtocolDecoderVTable* vtable)
{
    SubGhzProtocolDecoderRegistry::instance().registerDecoder(name, flag, vtable);
}

#endif // SUB_GHZ_PROTOCOL_DECODER_REGISTRY_H
