#ifndef FREQUENCY_HOPPER_H
#define FREQUENCY_HOPPER_H

#include <vector>
#include <cstdint>

/**
 * FrequencyHopper — automatic frequency hopping with RSSI linger.
 *
 * Ported from Flipper Zero helpers/subghz_txrx.c (subghz_txrx_hopper_update).
 *
 * Walks through a list of frequencies, reading RSSI on each.
 * If RSSI is above a threshold, it lingers (stays on that frequency for
 * N ticks) instead of hopping away. This prevents missing a weak signal
 * that's coming through on the current channel.
 *
 * States:
 *   OFF        — hopper disabled
 *   RUNNING    — actively scanning frequencies
 *   PAUSE      — paused (external)
 *   RSSI_TIMEOUT — signal detected, lingering on current frequency
 */
class FrequencyHopper {
public:
    enum State : uint8_t {
        OFF = 0,
        RUNNING,
        PAUSE,
        RSSI_TIMEOUT
    };

    struct Config {
        std::vector<float> frequencies;     ///< Frequency list in MHz
        float lingerRssiThreshold = -90.0f; ///< Stay if RSSI > this (dBm)
        int lingerTicks = 10;               ///< Ticks to stay on active freq
    };

    FrequencyHopper();

    /** Configure the hop list and thresholds. */
    void configure(const Config& cfg);

    /** Start hopping. */
    void start();

    /** Stop hopping. */
    void stop();

    /** Pause at current frequency (don't hop away). */
    void pause();

    /** Resume hopping. */
    void resume();

    /**
     * Update the hopper state machine.
     * Call periodically (every ~10-50ms) with current RSSI.
     * @param currentRssi  Current RSSI in dBm
     * @return true if the frequency changed, false if still on same freq
     */
    bool update(float currentRssi);

    /** Get the current frequency in MHz. */
    float getCurrentFrequency() const { return currentFreq_; }

    /** Get current hopper state. */
    State getState() const { return state_; }

    /** Get the current index in the frequency list. */
    size_t getCurrentIndex() const { return freqIndex_; }

private:
    Config config_;
    State state_;
    size_t freqIndex_;
    float currentFreq_;
    int timeoutRemaining_;
};

#endif // FREQUENCY_HOPPER_H
