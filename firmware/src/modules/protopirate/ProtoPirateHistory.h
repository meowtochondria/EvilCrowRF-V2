#pragma once
/**
 * @file ProtoPirateHistory.h
 * @brief Circular buffer for decoded automotive key fob signals.
 *
 * Keeps up to PP_HISTORY_MAX_ENTRIES decoded results.
 * Deduplicates based on data hash + 500ms window.
 */

#ifndef ProtoPirateHistory_h
#define ProtoPirateHistory_h

#include "protocols/PPProtocol.h"
#include <cstring>

#define PP_HISTORY_MAX_ENTRIES 20
#define PP_DEDUP_WINDOW_MS    500

/**
 * @brief Single history entry: decoded result + timestamp.
 */
struct PPHistoryEntry {
    PPDecodeResult result;
    uint32_t timestampMs;
    bool valid;

    PPHistoryEntry() : timestampMs(0), valid(false) {}
};

/**
 * @brief Circular buffer of decoded ProtoPirate results.
 *
 * Thread-safe via external caller locking (the module holds the mutex).
 */
class ProtoPirateHistory {
public:
    ProtoPirateHistory() { clear(); }

    /**
     * @brief Try to add a new decoded result.
     * @return true if added (not a duplicate), false if deduplicated.
     */
    bool add(const PPDecodeResult& result, uint32_t nowMs) {
        // Check for duplicate (same data within dedup window)
        uint32_t hash = hashResult(result);
        for (int i = 0; i < PP_HISTORY_MAX_ENTRIES; i++) {
            if (!entries_[i].valid) continue;
            if (hashResult(entries_[i].result) == hash &&
                (nowMs - entries_[i].timestampMs) < PP_DEDUP_WINDOW_MS) {
                // Duplicate — update timestamp but don't add new entry
                entries_[i].timestampMs = nowMs;
                return false;
            }
        }

        // Add to circular buffer
        entries_[writeIdx_].result = result;
        entries_[writeIdx_].timestampMs = nowMs;
        entries_[writeIdx_].valid = true;
        writeIdx_ = (writeIdx_ + 1) % PP_HISTORY_MAX_ENTRIES;
        if (count_ < PP_HISTORY_MAX_ENTRIES) count_++;
        return true;
    }

    /**
     * @brief Get entry by index (0 = most recent).
     * @return Pointer to entry or nullptr if out of range.
     */
    const PPHistoryEntry* get(int index) const {
        if (index < 0 || index >= count_) return nullptr;
        int actualIdx = (writeIdx_ - 1 - index + PP_HISTORY_MAX_ENTRIES) % PP_HISTORY_MAX_ENTRIES;
        return &entries_[actualIdx];
    }

    int getCount() const { return count_; }

    void clear() {
        writeIdx_ = 0;
        count_ = 0;
        for (int i = 0; i < PP_HISTORY_MAX_ENTRIES; i++) {
            entries_[i].valid = false;
        }
    }

private:
    PPHistoryEntry entries_[PP_HISTORY_MAX_ENTRIES];
    int writeIdx_ = 0;
    int count_ = 0;

    static uint32_t hashResult(const PPDecodeResult& r) {
        // FNV-1a hash of data + data2 + protocol name
        uint32_t h = 2166136261u;
        auto fnvByte = [&h](uint8_t b) {
            h ^= b;
            h *= 16777619u;
        };
        for (int i = 0; i < 8; i++) fnvByte((uint8_t)(r.data >> (i * 8)));
        for (int i = 0; i < 8; i++) fnvByte((uint8_t)(r.data2 >> (i * 8)));
        if (r.protocolName) {
            for (const char* p = r.protocolName; *p; p++) fnvByte(*p);
        }
        return h;
    }
};

#endif // ProtoPirateHistory_h
