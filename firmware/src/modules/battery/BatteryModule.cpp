/**
 * @file BatteryModule.cpp
 * @brief Battery voltage monitoring implementation (Arduino-compatible).
 *
 * Uses analogRead() with attenuation for battery monitoring on GPIO 36 (VP).
 * LiPo discharge curve approximation remains the same.
 */

#include "BatteryModule.h"

#if BATTERY_MODULE_ENABLED

static const char* TAG = "Battery";

// Static members
bool BatteryModule::initialized_ = false;
uint16_t BatteryModule::lastVoltage_ = 0;
uint8_t BatteryModule::lastPercent_ = 0;
bool BatteryModule::lastCharging_ = false;
TimerHandle_t BatteryModule::readTimer_ = nullptr;

void BatteryModule::init() {
    if (initialized_) return;

    // Configure ADC for battery monitoring
    // Set attenuation to 11dB to allow measurement up to ~3.9V
    analogSetAttenuation(ADC_11db);
    // Set resolution to 12-bit (0-4095)
    analogReadResolution(12);

    // Take initial reading
    lastVoltage_ = readVoltage();
    lastPercent_ = voltageToPercent(lastVoltage_);
    lastCharging_ = isCharging();

    ESP_LOGI(TAG, "Battery init: %dmV (%d%%) charging=%d",
             lastVoltage_, lastPercent_, lastCharging_);

    // Start periodic timer
    if (BATTERY_READ_INTERVAL_MS > 0) {
        readTimer_ = xTimerCreate(
            "BattTimer",
            pdMS_TO_TICKS(BATTERY_READ_INTERVAL_MS),
            pdTRUE,    // Auto-reload
            nullptr,
            timerCallback
        );
        if (readTimer_) {
            xTimerStart(readTimer_, 0);
            ESP_LOGI(TAG, "Periodic reading every %dms", BATTERY_READ_INTERVAL_MS);
        }
    }

    initialized_ = true;
}

uint16_t BatteryModule::readVoltage() {
    // Multisample for noise reduction
    uint32_t sum = 0;
    for (int i = 0; i < ADC_SAMPLES; i++) {
        // Use analogReadMilliVolts for direct mV reading (includes attenuation factor)
        sum += analogReadMilliVolts(36); // GPIO 36 (ADC1 channel 0)
    }
    uint32_t avg_mv = sum / ADC_SAMPLES;

    // Apply voltage divider ratio to get actual battery voltage
    uint16_t batteryVoltage = (uint16_t)(avg_mv * BATTERY_DIVIDER_RATIO);
    return batteryVoltage;
}

uint8_t BatteryModule::voltageToPercent(uint16_t voltage_mv) {
    // Piecewise linear approximation of LiPo discharge curve
    // Based on typical 3.7V LiPo cell characteristics
    struct VoltagePoint {
        uint16_t mv;
        uint8_t pct;
    };

    // Discharge curve lookup table (descending voltage)
    static const VoltagePoint curve[] = {
        {4200, 100},
        {4150,  95},
        {4100,  90},
        {4000,  80},
        {3950,  75},
        {3900,  70},
        {3850,  60},
        {3800,  50},
        {3750,  40},
        {3700,  30},
        {3650,  20},
        {3500,  10},
        {3300,   5},
        {3200,   0},
    };
    static const int curveSize = sizeof(curve) / sizeof(curve[0]);

    // Clamp to range
    if (voltage_mv >= curve[0].mv) return 100;
    if (voltage_mv <= curve[curveSize - 1].mv) return 0;

    // Linear interpolation between curve points
    for (int i = 0; i < curveSize - 1; i++) {
        if (voltage_mv >= curve[i + 1].mv) {
            uint16_t vRange = curve[i].mv - curve[i + 1].mv;
            uint8_t  pRange = curve[i].pct - curve[i + 1].pct;
            uint16_t vDelta = voltage_mv - curve[i + 1].mv;
            return curve[i + 1].pct + (uint8_t)((uint32_t)vDelta * pRange / vRange);
        }
    }

    return 0;
}

bool BatteryModule::isCharging() {
    // Charging detection: if voltage is above 4.15V, it's likely charging.
    // A dedicated CHRG pin from TP4056 would be more reliable.
    return (lastVoltage_ > 4150);
}

void BatteryModule::sendBatteryStatus() {
    if (!initialized_) return;

    BinaryBatteryStatus msg;
    msg.voltage_mv = lastVoltage_;
    msg.percentage = lastPercent_;
    msg.charging   = lastCharging_ ? 1 : 0;

    ClientsManager::getInstance().notifyAllBinary(
        NotificationType::DeviceInfo,
        reinterpret_cast<const uint8_t*>(&msg),
        sizeof(msg));

    ESP_LOGD(TAG, "Battery: %dmV %d%% charging=%d",
             lastVoltage_, lastPercent_, lastCharging_);
}

void BatteryModule::timerCallback(TimerHandle_t /*xTimer*/) {
    lastVoltage_ = readVoltage();
    lastPercent_ = voltageToPercent(lastVoltage_);
    lastCharging_ = isCharging();

    // Battery status is sent via GetState responses and CC1101Worker
    // sendHeartbeat instead of directly from this timer callback.
    // The Tmr Svc task has only 2KB stack — calling NimBLE notify
    // from here triggers a stack overflow.
}

#endif // BATTERY_MODULE_ENABLED
