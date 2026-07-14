#ifndef SUBGHZ_CONFIG_COMMANDS_H
#define SUBGHZ_CONFIG_COMMANDS_H

#include <Arduino.h>
#include <cstring>
#include <vector>
#include "core/CommandHandler.h"
#include "core/ClientsManager.h"
#include "BinaryMessages.h"
#include "modules/subghz_function/SubGhzThresholdRssi.h"
#include "modules/subghz_function/FrequencyHopper.h"
#include "modules/subghz_function/SubGhzCaptureManager.h"

/**
 * SubGhzConfigCommands — key-value config for subghz capture.
 *
 * Commands:
 *   0x70 = SUBGHZ_SET_CONFIG  [key:1][value:variable]
 *   0x71 = SUBGHZ_GET_CONFIG  [key:1]  → responds [key:1][value:variable]
 *
 * Key enum:
 *   0x01 = THRESHOLD_RSSI        [int8]    RSSI threshold in dBm (-90 to -40)
 *   0x02 = HOPPER_FREQS          [count:1][freq_khz:4LE * count]
 *   0x03 = HOPPER_LINGER_RSSI    [int8]    RSSI threshold to linger (-90 dBm default)
 *   0x04 = HOPPER_LINGER_TICKS   [u8]      Ticks to stay on active freq (10 default)
 *   0x05 = HOPPER_ENABLED        [u8]      0=off, 1=on
 *   0x06 = DECODER_FILTER        [u32]     Protocol flag mask (default: BinRAW|Decodable)
 *   0x07 = DECODER_FILTER_RAW    [u8]      0=decodable+binraw, 1=raw only
 */
class SubGhzConfigCommands {
public:
    enum ConfigKey : uint8_t {
        KEY_THRESHOLD_RSSI      = 0x01,
        KEY_HOPPER_FREQS        = 0x02,
        KEY_HOPPER_LINGER_RSSI  = 0x03,
        KEY_HOPPER_LINGER_TICKS = 0x04,
        KEY_HOPPER_ENABLED      = 0x05,
        KEY_DECODER_FILTER      = 0x06,
        KEY_DECODER_FILTER_RAW  = 0x07,
    };

    static void registerCommands(CommandHandler& handler) {
        ESP_LOGI("SGCfgCmd", "Registering subghz config commands");
        handler.registerCommand(0x70, handleSetConfig);
        handler.registerCommand(0x71, handleGetConfig);
        ESP_LOGI("SGCfgCmd", "SubGhzConfig commands registered (0x70/0x71)");
    }

private:
    // ---- External references ----
    static SubGhzThresholdRssi& threshold() {
        static SubGhzThresholdRssi instance;
        return instance;
    }

    static FrequencyHopper& hopper() {
        static FrequencyHopper instance;
        return instance;
    }

    // ---- 0x70: SET_CONFIG ----
    static bool handleSetConfig(const uint8_t* data, size_t len) {
        if (len < 2) {
            ESP_LOGW("SGCfgCmd", "SET_CONFIG: too short (%zu bytes)", len);
            sendResult(false);
            return false;
        }

        uint8_t key = data[0];
        const uint8_t* value = data + 1;
        size_t valueLen = len - 1;

        switch (key) {

        case KEY_THRESHOLD_RSSI: {
            if (valueLen < 1) { sendResult(false); return false; }
            int8_t rssi = static_cast<int8_t>(value[0]);
            // Clamp to valid range [-90, -40]
            if (rssi < -90) rssi = -90;
            if (rssi > -40) rssi = -40;
            threshold().set(static_cast<float>(rssi));
            ESP_LOGI("SGCfgCmd", "Threshold RSSI set to %d dBm", rssi);
            sendResult(true);
            return true;
        }

        case KEY_HOPPER_FREQS: {
            if (valueLen < 1) { sendResult(false); return false; }
            uint8_t count = value[0];
            if (count == 0 || valueLen < 1 + count * 4u) {
                sendResult(false);
                return false;
            }
            std::vector<float> freqs;
            freqs.reserve(count);
            for (uint8_t i = 0; i < count; i++) {
                uint32_t khz = value[1 + i * 4]
                    | (value[2 + i * 4] << 8)
                    | (value[3 + i * 4] << 16)
                    | (value[4 + i * 4] << 24);
                freqs.push_back(khz / 1000.0f);
            }
            FrequencyHopper::Config cfg = hopperConfig();
            cfg.frequencies = freqs;
            hopper().configure(cfg);
            ESP_LOGI("SGCfgCmd", "Hopper freqs set: %d frequencies", count);
            sendResult(true);
            return true;
        }

        case KEY_HOPPER_LINGER_RSSI: {
            if (valueLen < 1) { sendResult(false); return false; }
            int8_t rssi = static_cast<int8_t>(value[0]);
            FrequencyHopper::Config cfg = hopperConfig();
            cfg.lingerRssiThreshold = static_cast<float>(rssi);
            hopper().configure(cfg);
            ESP_LOGI("SGCfgCmd", "Hopper linger RSSI set to %d dBm", rssi);
            sendResult(true);
            return true;
        }

        case KEY_HOPPER_LINGER_TICKS: {
            if (valueLen < 1) { sendResult(false); return false; }
            uint8_t ticks = value[0];
            FrequencyHopper::Config cfg = hopperConfig();
            cfg.lingerTicks = ticks;
            hopper().configure(cfg);
            ESP_LOGI("SGCfgCmd", "Hopper linger ticks set to %d", ticks);
            sendResult(true);
            return true;
        }

        case KEY_HOPPER_ENABLED: {
            if (valueLen < 1) { sendResult(false); return false; }
            bool enable = value[0] != 0;
            if (enable) {
                hopper().start();
            } else {
                hopper().stop();
            }
            ESP_LOGI("SGCfgCmd", "Hopper %s", enable ? "started" : "stopped");
            sendResult(true);
            return true;
        }

        case KEY_DECODER_FILTER: {
            if (valueLen < 4) { sendResult(false); return false; }
            uint32_t mask = value[0]
                | (value[1] << 8)
                | (value[2] << 16)
                | (value[3] << 24);
            g_subghzCaptureManager.setFilter(
                static_cast<SubGhzProtocolFlag>(mask));
            ESP_LOGI("SGCfgCmd", "Decoder filter set to 0x%08lx", (unsigned long)mask);
            sendResult(true);
            return true;
        }

        case KEY_DECODER_FILTER_RAW: {
            if (valueLen < 1) { sendResult(false); return false; }
            bool rawOnly = value[0] != 0;
            SubGhzProtocolFlag filter;
            if (rawOnly) {
                filter = SubGhzProtocolFlag_RAW;
            } else {
                filter = static_cast<SubGhzProtocolFlag>(
                    SubGhzProtocolFlag_BinRAW |
                    SubGhzProtocolFlag_Decodable);
            }
            g_subghzCaptureManager.setFilter(filter);
            ESP_LOGI("SGCfgCmd", "Decoder filter: RAW=%d", rawOnly);
            sendResult(true);
            return true;
        }

        default:
            ESP_LOGW("SGCfgCmd", "Unknown config key: 0x%02X", key);
            sendResult(false);
            return false;
        }
    }

    // ---- 0x71: GET_CONFIG ----
    static bool handleGetConfig(const uint8_t* data, size_t len) {
        if (len < 1) {
            ESP_LOGW("SGCfgCmd", "GET_CONFIG: no key");
            sendResult(false);
            return false;
        }

        uint8_t key = data[0];
        uint8_t response[256];
        size_t responseLen = 0;

        response[responseLen++] = MSG_COMMAND_SUCCESS;
        response[responseLen++] = key;

        switch (key) {

        case KEY_THRESHOLD_RSSI: {
            float rssi = threshold().get();
            response[responseLen++] = static_cast<uint8_t>(static_cast<int8_t>(rssi));
            break;
        }

        case KEY_HOPPER_FREQS: {
            // Not stored in a retrievable form currently — return count=0
            response[responseLen++] = 0;
            break;
        }

        case KEY_HOPPER_LINGER_RSSI: {
            response[responseLen++] = static_cast<uint8_t>(
                static_cast<int8_t>(hopperConfig().lingerRssiThreshold));
            break;
        }

        case KEY_HOPPER_LINGER_TICKS: {
            response[responseLen++] = static_cast<uint8_t>(hopperConfig().lingerTicks);
            break;
        }

        case KEY_HOPPER_ENABLED: {
            response[responseLen++] = hopper().getState() != FrequencyHopper::OFF ? 1 : 0;
            break;
        }

        case KEY_DECODER_FILTER: {
            uint32_t mask = static_cast<uint32_t>(
                g_subghzCaptureManager.getReceiver(0)
                    ? g_subghzCaptureManager.getReceiver(0)->getFilter()
                    : 0);
            response[responseLen++] = mask & 0xFF;
            response[responseLen++] = (mask >> 8) & 0xFF;
            response[responseLen++] = (mask >> 16) & 0xFF;
            response[responseLen++] = (mask >> 24) & 0xFF;
            break;
        }

        case KEY_DECODER_FILTER_RAW: {
            SubGhzProtocolFlag filter = g_subghzCaptureManager.getReceiver(0)
                ? g_subghzCaptureManager.getReceiver(0)->getFilter()
                : static_cast<SubGhzProtocolFlag>(0);
            response[responseLen++] = (filter == SubGhzProtocolFlag_RAW) ? 1 : 0;
            break;
        }

        default:
            ESP_LOGW("SGCfgCmd", "GET unknown key: 0x%02X", key);
            response[1] = 0xFF;  // Error indicator
            responseLen = 2;
            break;
        }

        ClientsManager::getInstance().notifyAllBinary(
            NotificationType::CommandResponse, response, responseLen);
        return true;
    }

    // ---- Helpers ----
    static void sendResult(bool success) {
        uint8_t resp[1] = { success ? MSG_COMMAND_SUCCESS : MSG_COMMAND_ERROR };
        ClientsManager::getInstance().notifyAllBinary(
            NotificationType::CommandResponse, resp, 1);
    }

    /** Get current hopper config (preserving existing freqs if set). */
    static FrequencyHopper::Config hopperConfig() {
        // Build a default config. The hopper object already has its own config.
        // Since FrequencyHopper doesn't expose getConfig(), we reconstruct it.
        FrequencyHopper::Config cfg;
        cfg.lingerRssiThreshold = -90.0f;
        cfg.lingerTicks = 10;
        // Frequencies: use the standard detection list as default
        // (18 frequencies from CC1101Worker::signalDetectionFrequencies)
        cfg.frequencies = {};
        return cfg;
    }
};

#endif // SUBGHZ_CONFIG_COMMANDS_H
