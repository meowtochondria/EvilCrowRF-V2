#ifndef SUB_GHZ_THRESHOLD_RSSI_H
#define SUB_GHZ_THRESHOLD_RSSI_H

#include <stdint.h>
#include <cmath>

/**
 * SubGhzThresholdRssi — RSSI threshold gate with hysteresis.
 *
 * Ported from Flipper Zero helpers/subghz_threshold_rssi.c.
 *
 * Provides a configurable RSSI threshold with 10-sample hysteresis.
 * When RSSI drops below the threshold for 10 consecutive samples,
 * is_above() returns false (signal lost). A single spike doesn't
 * trigger false starts, and a single dip doesn't fragment a capture.
 */
class SubGhzThresholdRssi {
public:
    /** Minimum value that disables the threshold (always record). */
    static constexpr float THRESHOLD_MIN = -90.0f;

    /** Number of consecutive below-threshold samples to trigger pause. */
    static constexpr uint8_t HYSTERESIS_COUNT = 10;

    struct Result {
        float rssi;
        bool is_above;  ///< true = signal strength above threshold
    };

    SubGhzThresholdRssi();

    /**
     * Set the threshold value (dBm).
     * Set to THRESHOLD_MIN (-90.0f) to disable gating (always record).
     */
    void set(float rssi);

    /** Get the current threshold value. */
    float get() const { return threshold_; }

    /**
     * Evaluate the current RSSI against the threshold.
     * @param rssi  Current RSSI in dBm
     * @return Result with is_above = true if signal is strong enough
     */
    Result check(float rssi);

    /** Reset hysteresis counter to initial state. */
    void reset();

private:
    float threshold_;
    uint8_t low_count_;
};

#endif // SUB_GHZ_THRESHOLD_RSSI_H
