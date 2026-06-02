/**
 * @file BatteryModule.cpp
 * @brief Battery voltage monitoring implementation.
 *
 * Uses ESP-IDF 5.x ADC oneshot + calibration API for accurate readings.
 * GPIO 36 (VP) is an input-only pin with ADC1_CHANNEL_0.
 *
 * LiPo discharge curve approximation (3.7V nominal):
 *   4.20V = 100%
 *   4.10V = 90%
 *   3.95V = 75%
 *   3.80V = 50%
 *   3.70V = 25%
 *   3.50V = 10%
 *   3.20V = 0% (cutoff)
 */

#include "BatteryModule.h"

#if BATTERY_MODULE_ENABLED

static const char* TAG = "Battery";

// Static members
bool     BatteryModule::initialized_  = false;
uint16_t BatteryModule::lastVoltage_  = 0;
uint8_t  BatteryModule::lastPercent_  = 0;
bool     BatteryModule::lastCharging_ = false;
adc_oneshot_unit_handle_t BatteryModule::adcHandle_ = nullptr;
adc_cali_handle_t         BatteryModule::caliHandle_ = nullptr;
TimerHandle_t BatteryModule::readTimer_ = nullptr;

void BatteryModule::init() {
    if (initialized_) return;

    // ── ADC oneshot unit init ───────────────────────────────────
    adc_oneshot_unit_init_cfg_t unitCfg = {};
    unitCfg.unit_id = ADC_UNIT_1;
    unitCfg.ulp_mode = ADC_ULP_MODE_DISABLE;

    esp_err_t err = adc_oneshot_new_unit(&unitCfg, &adcHandle_);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to init ADC unit: %s", esp_err_to_name(err));
        return;
    }

    // ── Channel config (GPIO 36 = ADC1_CH0, 12dB attenuation for ~3.3V range) ──
    adc_oneshot_chan_cfg_t chanCfg = {};
    chanCfg.atten = ADC_ATTEN_DB_12;
    chanCfg.bitwidth = ADC_BITWIDTH_12;

    err = adc_oneshot_config_channel(adcHandle_, ADC_CHANNEL_0, &chanCfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to config ADC channel: %s", esp_err_to_name(err));
        adc_oneshot_del_unit(adcHandle_);
        adcHandle_ = nullptr;
        return;
    }

    // ── Calibration (line fitting scheme for original ESP32) ────
    //
    // ESP32 supports line fitting calibration.
    // Uses factory eFuse Vref or Two-Point values if available.
#if ADC_CALI_SCHEME_LINE_FITTING_SUPPORTED
    adc_cali_line_fitting_config_t caliCfg = {};
    caliCfg.unit_id  = ADC_UNIT_1;
    caliCfg.atten    = ADC_ATTEN_DB_12;
    caliCfg.bitwidth = ADC_BITWIDTH_12;

    err = adc_cali_create_scheme_line_fitting(&caliCfg, &caliHandle_);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "ADC calibration: line fitting");
    } else {
        ESP_LOGW(TAG, "ADC calibration failed (%s), using raw readings",
                 esp_err_to_name(err));
        caliHandle_ = nullptr;
    }
#else
    ESP_LOGW(TAG, "ADC line fitting not supported, using raw readings");
    caliHandle_ = nullptr;
#endif

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
    if (!adcHandle_) return 0;

    // Multisample for noise reduction
    uint32_t rawSum = 0;
    for (int i = 0; i < ADC_SAMPLES; i++) {
        int raw = 0;
        if (adc_oneshot_read(adcHandle_, ADC_CHANNEL_0, &raw) == ESP_OK) {
            rawSum += raw;
        }
    }
    int rawAvg = (int)(rawSum / ADC_SAMPLES);

    // Convert to calibrated millivolts if calibration is available
    uint32_t voltage_mv;
    if (caliHandle_) {
        int mv = 0;
        adc_cali_raw_to_voltage(caliHandle_, rawAvg, &mv);
        voltage_mv = (uint32_t)mv;
    } else {
        // Fallback: approximate conversion for 12-bit / 12dB atten
        // Full range ~3300mV over 4095 counts
        voltage_mv = (uint32_t)rawAvg * 3300 / 4095;
    }

    // Apply voltage divider ratio to get actual battery voltage
    uint16_t batteryVoltage = (uint16_t)(voltage_mv * BATTERY_DIVIDER_RATIO);

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
    // Charging detection: if voltage is above 4.15V and still rising,
    // it's likely charging. A more robust approach would use a dedicated
    // CHRG pin from the TP4056, but we approximate it from voltage.
    //
    // Heuristic: voltage > 4.15V suggests active charging or fully charged.
    // The TP4056 CHRG pin (if connected to a GPIO) would be more reliable.
    //
    // TODO: If the schematic confirms a CHRG pin on a GPIO, read it directly.
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
    uint16_t prevVoltage = lastVoltage_;
    lastVoltage_ = readVoltage();
    lastPercent_ = voltageToPercent(lastVoltage_);
    lastCharging_ = isCharging();

    // Only send BLE notification if value changed significantly (±50mV or ±2%)
    int16_t vDiff = (int16_t)lastVoltage_ - (int16_t)prevVoltage;
    if (vDiff < -50 || vDiff > 50) {
        sendBatteryStatus();
    }
}

#endif // BATTERY_MODULE_ENABLED
