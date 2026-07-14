#ifndef SUB_GHZ_RECEIVER_H
#define SUB_GHZ_RECEIVER_H

#include <vector>
#include <cstdint>
#include <cstddef>
#include "SubGhzProtocolBase.h"
#include "SubGhzTypes.h"

/**
 * SubGhzReceiver — fan-out dispatcher for real-time protocol decoders.
 *
 * Ported from Flipper Zero lib/subghz/receiver.h / receiver.c.
 *
 * The receiver holds one slot per registered protocol. Every call to
 * decode(level, duration) iterates all slots and feeds only those whose
 * protocol flag passes the active filter mask.
 *
 * When a decoder successfully identifies a valid frame it invokes the
 * callback set via setRxCallback().
 */
class SubGhzReceiver {
public:
    SubGhzReceiver();
    ~SubGhzReceiver();

    /**
     * Register a decoder v-table into the receiver.
     * Called once at startup for each protocol.
     * @param name     Protocol name (e.g. "Princeton", "BinRAW")
     * @param flag     Protocol capability flags
     * @param vtable   V-table with alloc/feed/reset/... function pointers
     */
    void registerDecoder(
        const char* name,
        SubGhzProtocolFlag flag,
        const SubGhzProtocolDecoderVTable* vtable);

    /**
     * Feed a level/duration pair to all enabled decoder slots.
     * Called from the worker thread after the glitch filter.
     * @param level    Signal level (true = HIGH, false = LOW)
     * @param duration Duration of this level in microseconds
     */
    void decode(bool level, uint32_t duration_us);

    /**
     * Reset all decoder slots. Called on buffer overrun or mode change.
     */
    void reset();

    /**
     * Set the protocol filter mask. Only decoders whose flag matches
     * will receive decode() calls.
     * @param filter  Bitmask of SubGhzProtocolFlag values
     */
    void setFilter(SubGhzProtocolFlag filter);

    /** Get the current filter mask. */
    SubGhzProtocolFlag getFilter() const { return filter_; }

    /**
     * Set the callback for successful decodes across all slots.
     * Each slot's base struct gets wired to an internal trampoline that
     * calls this callback.
     * @param callback  Function to call on decode success
     * @param context   Opaque context pointer
     */
    void setRxCallback(SubGhzProtocolDecoderRxCallback callback, void* context);

    /**
     * Find a decoder slot by protocol name.
     * @param name  Protocol name (e.g. "BinRAW")
     * @return Pointer to the decoder base struct, or nullptr if not found
     */
    SubGhzProtocolDecoderBase* getDecoderByName(const char* name);

private:
    /** One decoder slot wraps a v-table + allocated instance. */
    struct Slot {
        SubGhzProtocolDecoderBase*  base;      // protocol name, flag, callback
        void*                       instance;  // opaque decoder instance
        const SubGhzProtocolDecoderVTable* vtable;
    };

    std::vector<Slot> slots_;
    SubGhzProtocolFlag filter_;
    SubGhzProtocolDecoderRxCallback rx_callback_;
    void* rx_callback_ctx_;

    /** Internal trampoline: called per-slot when a decoder finds a signal. */
    static void onSlotDecoded(SubGhzProtocolDecoderBase* decoder, void* context);
};

#endif // SUB_GHZ_RECEIVER_H
