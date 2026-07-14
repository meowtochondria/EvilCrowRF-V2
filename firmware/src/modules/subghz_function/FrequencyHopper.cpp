#include "FrequencyHopper.h"
#include "esp_log.h"

static const char* TAG = "FrequencyHopper";

FrequencyHopper::FrequencyHopper()
    : state_(OFF)
    , freqIndex_(0)
    , currentFreq_(433.92f)
    , timeoutRemaining_(0)
{
}

void FrequencyHopper::configure(const Config& cfg) {
    config_ = cfg;
    if (config_.frequencies.empty()) {
        ESP_LOGW(TAG, "Empty frequency list");
        return;
    }
    freqIndex_ = 0;
    currentFreq_ = config_.frequencies[0];
    ESP_LOGI(TAG, "Configured with %zu frequencies, linger RSSI=%.1f dBm, linger=%d ticks",
             config_.frequencies.size(),
             config_.lingerRssiThreshold,
             config_.lingerTicks);
}

void FrequencyHopper::start() {
    if (config_.frequencies.empty()) {
        ESP_LOGW(TAG, "Cannot start: no frequencies configured");
        return;
    }
    state_ = RUNNING;
    freqIndex_ = 0;
    currentFreq_ = config_.frequencies[0];
    timeoutRemaining_ = 0;
    ESP_LOGI(TAG, "Hopper started at %.2f MHz", currentFreq_);
}

void FrequencyHopper::stop() {
    state_ = OFF;
    timeoutRemaining_ = 0;
    ESP_LOGI(TAG, "Hopper stopped");
}

void FrequencyHopper::pause() {
    if (state_ == RUNNING || state_ == RSSI_TIMEOUT) {
        state_ = PAUSE;
        ESP_LOGD(TAG, "Hopper paused at %.2f MHz", currentFreq_);
    }
}

void FrequencyHopper::resume() {
    if (state_ == PAUSE) {
        state_ = RUNNING;
        ESP_LOGD(TAG, "Hopper resumed");
    }
}

bool FrequencyHopper::update(float currentRssi) {
    if (config_.frequencies.empty()) {
        return false;
    }

    switch (state_) {

    case OFF:
    case PAUSE:
        return false;  // No frequency change

    case RSSI_TIMEOUT:
        if (timeoutRemaining_ > 0) {
            timeoutRemaining_--;
            return false;  // Still lingering on current freq
        }
        // Timeout expired — fall through to advance to next freq
        break;

    case RUNNING:
        // Check if current frequency has a strong signal
        if (currentRssi > config_.lingerRssiThreshold) {
            timeoutRemaining_ = config_.lingerTicks;
            state_ = RSSI_TIMEOUT;
            ESP_LOGD(TAG, "RSSI %.1f > %.1f at %.2f MHz — lingering (%d ticks)",
                     currentRssi, config_.lingerRssiThreshold,
                     currentFreq_, config_.lingerTicks);
            return false;  // Stay on this frequency
        }
        break;
    }

    // Advance to next frequency
    freqIndex_ = (freqIndex_ + 1) % config_.frequencies.size();
    currentFreq_ = config_.frequencies[freqIndex_];
    state_ = RUNNING;

    ESP_LOGD(TAG, "Hopping to %.2f MHz (index %zu/%zu)",
             currentFreq_, freqIndex_ + 1, config_.frequencies.size());

    return true;  // Frequency changed
}
