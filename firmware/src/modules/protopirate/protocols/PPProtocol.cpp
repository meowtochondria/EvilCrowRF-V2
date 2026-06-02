/**
 * @file PPProtocol.cpp
 * @brief Protocol registry and PPDecodeResult formatting implementation.
 */

#include "PPProtocol.h"
#include <cstdio>

// ============================================================================
// GLOBAL PROTOCOL REGISTRY
// ============================================================================

static std::vector<PPProtocolEntry>& getRegistry() {
    static std::vector<PPProtocolEntry> registry;
    return registry;
}

const std::vector<PPProtocolEntry>& ppGetRegisteredProtocols() {
    return getRegistry();
}

void ppRegisterProtocol(const char* name, PPProtocolCreator creator) {
    getRegistry().push_back({name, creator});
}

// ============================================================================
// DECODE RESULT FORMATTING
// ============================================================================

void PPDecodeResult::formatString(char* buf, size_t bufLen) const {
    if (!buf || bufLen == 0) return;

    uint32_t keyHi = (uint32_t)(data >> 32);
    uint32_t keyLo = (uint32_t)(data & 0xFFFFFFFF);

    int written = snprintf(buf, bufLen,
        "%s %ubit\n"
        "Key:%08lX%08lX\n"
        "Sn:%07lX Btn:%X\n"
        "Cnt:%04lX CRC:%02X %s",
        protocolName ? protocolName : "Unknown",
        dataBits,
        (unsigned long)keyHi,
        (unsigned long)keyLo,
        (unsigned long)serial,
        button,
        (unsigned long)counter,
        crc,
        crcValid ? "OK" : "BAD");

    // Append extra fields for specific protocols
    if (bsMagic != 0 && written > 0 && (size_t)written < bufLen) {
        snprintf(buf + written, bufLen - written,
            "\nBS:%02lX", (unsigned long)bsMagic);
    }

    if (type != 0 && written > 0 && (size_t)written < bufLen) {
        size_t len = strlen(buf);
        snprintf(buf + len, bufLen - len,
            "\nType:%u KeyIdx:%u", type, keyIndex);
    }
}
