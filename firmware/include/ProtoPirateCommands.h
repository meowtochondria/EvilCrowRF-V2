#ifndef ProtoPirateCommands_h
#define ProtoPirateCommands_h

/**
 * @file ProtoPirateCommands.h
 * @brief BLE/Serial command handler for the ProtoPirate module.
 *
 * Registered on command byte 0x60.
 * Sub-commands (first data byte):
 *   0x01 = Start decode (params: [module:1][freqHz:4LE])
 *         Backward compatible: also accepts legacy [module:1][freqMHz*100:2LE]
 *   0x02 = Stop decode
 *   0x03 = Get history count
 *   0x04 = Get history entry (params: [index:1])
 *   0x05 = Clear history
 *   0x06 = Get status
 *   0x07 = Load .sub file  (params: [pathLen:1][path...])
 *   0x08 = List .sub files (params: [pathLen:1][path...])  — file browser
 *   0x09 = Emulate (TX)    (params: [module:1][repeat:1][nameLen:1][name...]
 *                           [data:8][data2:8][serial:4][btn:1][cnt:4][bits:1][freq:4LE])
 *   0x0A = Save capture    (same data payload as 0x09 without module/repeat)
 *   0x0B = List saved      (no params — lists /DATA/PROTOPIRATE/)
 */

#include "core/ble/CommandHandler.h"
#include "core/ble/ClientsManager.h"
#include "BinaryMessages.h"
#include "config.h"
#include "modules/protopirate/ProtoPirateModule.h"
#include "esp_log.h"
#include <cstring>
#include "SD.h"
#include "ff.h"  // FATFS low-level API for fast directory listing

class ProtoPirateCommands {
public:
    static void registerCommands(CommandHandler& handler) {
        ESP_LOGI("PPCmd", "Registering ProtoPirate commands");
        handler.registerCommand(0x60, handleCommand);
        ESP_LOGI("PPCmd", "ProtoPirate commands registered (0x60)");
    }

private:
    static bool handleCommand(const uint8_t* data, size_t len) {
        if (len < 1) {
            ESP_LOGE("PPCmd", "No sub-command byte");
            sendError(1);
            return false;
        }

        uint8_t subCmd = data[0];
        ProtoPirateModule& pp = ProtoPirateModule::getInstance();

        switch (subCmd) {
        case 0x01: return cmdStartDecode(pp, data + 1, len - 1);
        case 0x02: return cmdStopDecode(pp);
        case 0x03: return cmdGetHistoryCount(pp);
        case 0x04: return cmdGetHistoryEntry(pp, data + 1, len - 1);
        case 0x05: return cmdClearHistory(pp);
        case 0x06: return cmdGetStatus(pp);
        case 0x07: return cmdLoadSubFile(pp, data + 1, len - 1);
        case 0x08: return cmdListSubFiles(data + 1, len - 1);
        case 0x09: return cmdEmulate(pp, data + 1, len - 1);
        case 0x0A: return cmdSaveCapture(pp, data + 1, len - 1);
        case 0x0B: return cmdListSaved(data + 1, len - 1);
        default:
            ESP_LOGW("PPCmd", "Unknown sub-command: 0x%02X", subCmd);
            sendError(2);
            return false;
        }
    }

    // ── Sub-command handlers ──────────────────────────────

    /**
     * Start decode:
     *   New:    [0x01][module:1][freqHz:4LE]
     *   Legacy: [0x01][module:1][freqMHz*100:2LE]
     */
    static bool cmdStartDecode(ProtoPirateModule& pp, const uint8_t* data, size_t len) {
        if (len < 3) {
            ESP_LOGE("PPCmd", "StartDecode: need at least 3 bytes (module + freq)");
            sendError(3);
            return false;
        }

        uint8_t module = data[0];
        float frequency = 0.0f;

        // Prefer new 32-bit Hz encoding when available (supports 868.35 MHz and above 655.35 MHz)
        if (len >= 5) {
            uint32_t freqHz = 0;
            memcpy(&freqHz, data + 1, 4);
            frequency = (float)freqHz / 1000000.0f;
        } else {
            // Legacy uint16 MHz*100 encoding
            uint16_t freqRaw = 0;
            memcpy(&freqRaw, data + 1, 2);
            frequency = (float)freqRaw / 100.0f;
        }

        ESP_LOGI("PPCmd", "StartDecode: module=%d, freq=%.2f MHz", module, frequency);

        if (!pp.startDecode(module, frequency)) {
            sendError(4);
            return false;
        }

        sendSuccess();
        return true;
    }

    static bool cmdStopDecode(ProtoPirateModule& pp) {
        ESP_LOGI("PPCmd", "StopDecode");
        pp.stopDecode();
        sendSuccess();
        return true;
    }

    static bool cmdGetHistoryCount(ProtoPirateModule& pp) {
        pp.sendHistoryCount();
        return true;
    }

    /**
     * Get history entry: [0x04][index:1]
     */
    static bool cmdGetHistoryEntry(ProtoPirateModule& pp, const uint8_t* data, size_t len) {
        if (len < 1) {
            sendError(5);
            return false;
        }
        int index = data[0];
        if (!pp.sendHistoryEntry(index)) {
            sendError(6);
            return false;
        }
        return true;
    }

    static bool cmdClearHistory(ProtoPirateModule& pp) {
        ESP_LOGI("PPCmd", "ClearHistory");
        pp.clearHistory();
        sendSuccess();
        return true;
    }

    static bool cmdGetStatus(ProtoPirateModule& pp) {
        pp.sendStatus();
        return true;
    }

    /**
     * Load .sub file: [0x07][pathLen:1][path...]
     * Feeds RAW data from the file directly to decoders (diagnostic tool).
     */
    static bool cmdLoadSubFile(ProtoPirateModule& pp, const uint8_t* data, size_t len) {
        if (len < 2) {
            ESP_LOGE("PPCmd", "LoadSubFile: need pathLen + path");
            sendError(7);
            return false;
        }
        uint8_t pathLen = data[0];
        if (pathLen == 0 || (size_t)(pathLen + 1) > len) {
            ESP_LOGE("PPCmd", "LoadSubFile: invalid pathLen=%u (avail=%zu)", pathLen, len);
            sendError(8);
            return false;
        }
        char path[128];
        size_t copyLen = std::min((size_t)pathLen, sizeof(path) - 1);
        memcpy(path, data + 1, copyLen);
        path[copyLen] = '\0';

        ESP_LOGI("PPCmd", "LoadSubFile: %s", path);

        if (pp.loadSubFile(path)) {
            sendSuccess();
        } else {
            sendError(9);
        }
        return true;
    }

    /**
     * List .sub files on SD card (file browser).
     * [0x08][pathLen:1][path...]
     *
     * pathLen can be 0 to scan default directories (RECORDS, SIGNALS, root).
     * If pathLen > 0, the path is used as the directory to list.
     *
     * Response: MSG_PP_FILE_LIST (0xB9)
     * [0xB9][fileCount:1][{pathLen:1, path:pathLen, size:4LE}...]
     *
     * Uses FATFS low-level API for O(n) directory traversal.
     * Filters for .sub extension only.
     * If too many files for one BLE packet, multiple packets are sent.
     */
    static bool cmdListSubFiles(const uint8_t* data, size_t len) {
        // Parse optional directory path
        char searchDir[128] = "/";
        if (len >= 2) {
            uint8_t pathLen = data[0];
            if (pathLen > 0 && (size_t)(pathLen + 1) <= len) {
                size_t copyLen = std::min((size_t)pathLen, sizeof(searchDir) - 1);
                memcpy(searchDir, data + 1, copyLen);
                searchDir[copyLen] = '\0';
            }
        }

        ESP_LOGI("PPCmd", "ListSubFiles: dir=%s", searchDir);

        // Buffer for BLE response (fits in single BLE chunk)
        static uint8_t buf[480];
        size_t offset = 0;
        buf[offset++] = MSG_PP_FILE_LIST;
        size_t countOffset = offset++;  // placeholder for file count
        uint8_t fileCount = 0;

        // Search for .sub files recursively from the given directory
        listSubFilesRecursive(searchDir, buf, offset, fileCount, sizeof(buf));

        buf[countOffset] = fileCount;

        ESP_LOGI("PPCmd", "ListSubFiles: found %u .sub files", fileCount);

        ClientsManager::getInstance().notifyAllBinary(
            NotificationType::SignalDetected, buf, offset);
        return true;
    }

    /**
     * Recursively list .sub files using FATFS API.
     * Each file entry: [pathLen:1][fullPath:pathLen][size:4LE]
     */
    static void listSubFilesRecursive(const char* dir, uint8_t* buf,
                                      size_t& offset, uint8_t& count,
                                      size_t maxBufSize) {
        // FATFS needs /sd prefix on ESP32
        char fatfsPath[270];
        snprintf(fatfsPath, sizeof(fatfsPath), "/sd%s", dir);

        FF_DIR fatDir;
        FILINFO fno;
        FRESULT res = f_opendir(&fatDir, fatfsPath);
        if (res != FR_OK) {
            // Try without /sd prefix
            res = f_opendir(&fatDir, dir);
            if (res != FR_OK) {
                ESP_LOGD("PPCmd", "ListSubFiles: cannot open dir %s", dir);
                return;
            }
        }

        while (count < 50) {  // Limit to 50 files max
            res = f_readdir(&fatDir, &fno);
            if (res != FR_OK || fno.fname[0] == 0) break;

            // Skip . and ..
            if (fno.fname[0] == '.') continue;

            bool isDir = (fno.fattrib & AM_DIR) != 0;

            if (isDir) {
                // Build subdirectory path and recurse
                char subDir[256];
                if (strcmp(dir, "/") == 0) {
                    snprintf(subDir, sizeof(subDir), "/%s", fno.fname);
                } else {
                    snprintf(subDir, sizeof(subDir), "%s/%s", dir, fno.fname);
                }
                listSubFilesRecursive(subDir, buf, offset, count, maxBufSize);
            } else {
                // Check for .sub extension (case-insensitive)
                const char* ext = strrchr(fno.fname, '.');
                if (!ext) continue;
                if (strcasecmp(ext, ".sub") != 0) continue;

                // Build full path
                char fullPath[256];
                if (strcmp(dir, "/") == 0) {
                    snprintf(fullPath, sizeof(fullPath), "/%s", fno.fname);
                } else {
                    snprintf(fullPath, sizeof(fullPath), "%s/%s", dir, fno.fname);
                }

                uint8_t pathLen = (uint8_t)strlen(fullPath);
                uint32_t fileSize = (uint32_t)fno.fsize;

                // Check buffer space: 1 (pathLen) + pathLen + 4 (size) = pathLen + 5
                if (offset + pathLen + 5 >= maxBufSize - 4) {
                    ESP_LOGW("PPCmd", "ListSubFiles: buffer full at %u files", count);
                    break;
                }

                buf[offset++] = pathLen;
                memcpy(buf + offset, fullPath, pathLen);
                offset += pathLen;
                memcpy(buf + offset, &fileSize, 4);
                offset += 4;
                count++;

                ESP_LOGD("PPCmd", "ListSubFiles: [%u] %s (%u bytes)",
                         count, fullPath, fileSize);
            }

            // Yield periodically to avoid watchdog timeout
            if ((count % 10) == 0) {
                vTaskDelay(pdMS_TO_TICKS(2));
            }
        }

        f_closedir(&fatDir);
    }

    // ── Parse a PPDecodeResult from BLE binary payload ────────────
    // Layout: [nameLen:1][name...][data:8LE][data2:8LE][serial:4LE]
    //         [btn:1][cnt:4LE][bits:1][freq_hz:4LE]
    // Returns true if parsing succeeded.
    static bool parsePPResult(const uint8_t* data, size_t len,
                              PPDecodeResult& result, size_t& consumed) {
        if (len < 1) return false;
        uint8_t nameLen = data[0];
        size_t need = 1 + nameLen + 8 + 8 + 4 + 1 + 4 + 1 + 4;  // 31 + nameLen
        if (len < need) {
            ESP_LOGE("PPCmd", "parsePPResult: need %zu bytes, have %zu", need, len);
            return false;
        }
        size_t off = 1;

        // Protocol name → find a static string from the registry
        char nameBuf[32];
        size_t copyLen = std::min((size_t)nameLen, sizeof(nameBuf) - 1);
        memcpy(nameBuf, data + off, copyLen);
        nameBuf[copyLen] = '\0';
        off += nameLen;

        // Match protocol name from registered list
        result.protocolName = nullptr;
        const auto& factories = ppGetRegisteredProtocols();
        for (auto& entry : factories) {
            if (strcmp(entry.name, nameBuf) == 0) {
                result.protocolName = entry.name;
                break;
            }
        }
        if (!result.protocolName) {
            // Fallback: use a static buffer (less ideal but works)
            static char staticName[32];
            strncpy(staticName, nameBuf, sizeof(staticName) - 1);
            staticName[sizeof(staticName) - 1] = '\0';
            result.protocolName = staticName;
        }

        memcpy(&result.data, data + off, 8);    off += 8;
        memcpy(&result.data2, data + off, 8);   off += 8;
        memcpy(&result.serial, data + off, 4);  off += 4;
        result.button = data[off++];
        memcpy(&result.counter, data + off, 4); off += 4;
        result.dataBits = data[off++];

        uint32_t freqHz;
        memcpy(&freqHz, data + off, 4);         off += 4;
        result.frequency = (float)freqHz / 1000000.0f;

        consumed = off;
        return true;
    }

    /**
     * Emulate (TX): [0x09][module:1][repeat:1][nameLen:1][name...][data:8][data2:8]
     *               [serial:4][btn:1][cnt:4][bits:1][freq_hz:4LE]
     */
    static bool cmdEmulate(ProtoPirateModule& pp, const uint8_t* data, size_t len) {
        if (len < 3) {
            ESP_LOGE("PPCmd", "Emulate: need module + repeat + result data");
            sendError(10);
            return false;
        }

        uint8_t module = data[0];
        uint8_t repeat = data[1];
        if (repeat < 1) repeat = 1;
        if (repeat > 10) repeat = 10;

        PPDecodeResult result;
        memset(&result, 0, sizeof(result));
        size_t consumed = 0;

        if (!parsePPResult(data + 2, len - 2, result, consumed)) {
            ESP_LOGE("PPCmd", "Emulate: failed to parse result payload");
            sendError(11);
            return false;
        }

        ESP_LOGI("PPCmd", "Emulate: proto=%s module=%d repeat=%d btn=%d cnt=%u",
                 result.protocolName ? result.protocolName : "?",
                 module, repeat, result.button, result.counter);

        return pp.emulate(result, module, repeat);
    }

    /**
     * Save capture: [0x0A][nameLen:1][name...][data:8][data2:8]
     *               [serial:4][btn:1][cnt:4][bits:1][freq_hz:4LE]
     */
    static bool cmdSaveCapture(ProtoPirateModule& pp, const uint8_t* data, size_t len) {
        PPDecodeResult result;
        memset(&result, 0, sizeof(result));
        size_t consumed = 0;

        if (!parsePPResult(data, len, result, consumed)) {
            ESP_LOGE("PPCmd", "SaveCapture: failed to parse result payload");
            sendError(12);
            return false;
        }

        ESP_LOGI("PPCmd", "SaveCapture: proto=%s btn=%d cnt=%u",
                 result.protocolName ? result.protocolName : "?",
                 result.button, result.counter);

        std::string savedPath;
        if (pp.saveCapture(result, savedPath)) {
            sendSuccess();
            return true;
        } else {
            sendError(13);
            return false;
        }
    }

    /**
     * List saved captures: [0x0B] (no params)
     * Lists files in /DATA/PROTOPIRATE/
     */
    static bool cmdListSaved(const uint8_t* /*data*/, size_t /*len*/) {
        ESP_LOGI("PPCmd", "ListSaved: /DATA/PROTOPIRATE/");

        static uint8_t buf[480];
        size_t offset = 0;
        buf[offset++] = MSG_PP_FILE_LIST;
        size_t countOffset = offset++;
        uint8_t fileCount = 0;

        listSubFilesRecursive("/DATA/PROTOPIRATE", buf, offset, fileCount, sizeof(buf));

        buf[countOffset] = fileCount;
        ESP_LOGI("PPCmd", "ListSaved: found %u files", fileCount);

        ClientsManager::getInstance().notifyAllBinary(
            NotificationType::SignalDetected, buf, offset);
        return true;
    }

    // ── Helpers ──────────────────────────────────────────

    static void sendSuccess() {
        uint8_t buf[1] = {MSG_COMMAND_SUCCESS};
        ClientsManager::getInstance().notifyAllBinary(
            NotificationType::SignalSendingError, buf, 1);
    }

    static void sendError(uint8_t code) {
        uint8_t buf[2] = {MSG_COMMAND_ERROR, code};
        ClientsManager::getInstance().notifyAllBinary(
            NotificationType::SignalSendingError, buf, 2);
    }
};

#endif // ProtoPirateCommands_h
