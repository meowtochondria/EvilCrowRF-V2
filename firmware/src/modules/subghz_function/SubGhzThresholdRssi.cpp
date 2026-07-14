#include "SubGhzThresholdRssi.h"
#include "esp_log.h"

static const char* TAG = "SubGhzThresholdRssi";

SubGhzThresholdRssi::SubGhzThresholdRssi()
    : threshold_(THRESHOLD_MIN)
    , low_count_(HYSTERESIS_COUNT)
{
}

void SubGhzThresholdRssi::set(float rssi) {
    threshold_ = rssi;
    low_count_ = 0;  // Reset on threshold change
    ESP_LOGI(TAG, "Threshold set to %.1f dBm", rssi);
}

void SubGhzThresholdRssi::reset() {
    low_count_ = 0;
}

SubGhzThresholdRssi::Result SubGhzThresholdRssi::check(float rssi) {
    Result ret = {rssi, false};

    // Threshold disabled → always record
    if (std::fabs(threshold_ - THRESHOLD_MIN) < 0.01f) {
        ret.is_above = true;
        return ret;
    }

    if (rssi < threshold_) {
        // Below threshold: increment hysteresis counter
        low_count_++;
        if (low_count_ > HYSTERESIS_COUNT) {
            low_count_ = HYSTERESIS_COUNT;
        }
        ret.is_above = false;
    } else {
        // Above threshold: reset counter
        low_count_ = 0;
    }

    // Only report "below" after HYSTERESIS_COUNT consecutive below-threshold samples
    if (low_count_ == HYSTERESIS_COUNT) {
        ret.is_above = false;
    } else {
        ret.is_above = true;
    }

    return ret;
}
