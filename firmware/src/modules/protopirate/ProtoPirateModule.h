#pragma once
/**
 * @file ProtoPirateModule.h
 * @brief ProtoPirate module — automotive key fob protocol decoder.
 *
 * Runs a FreeRTOS task that feeds ISR-captured CC1101 samples
 * to all 14 registered protocol decoders in parallel.
 * Detected signals are stored in a circular history buffer.
 */

#ifndef ProtoPirateModule_h
#define ProtoPirateModule_h

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include <vector>
#include <memory>
#include "config.h"
#include "ProtoPirateHistory.h"
#include "protocols/PPProtocol.h"
#include "protocols/PPAllProtocols.h"
#include "modules/CC1101_driver/CC1101_Module.h"
#include "modules/CC1101_driver/CC1101_Worker.h"
#include "core/ble/ClientsManager.h"
#include "BinaryMessages.h"
#include "esp_log.h"

/**
 * @brief ProtoPirate module state.
 */
enum class PPState : uint8_t {
    Idle = 0,
    Decoding = 1,
};

class ProtoPirateModule {
public:
    static ProtoPirateModule& getInstance() {
        static ProtoPirateModule instance;
        return instance;
    }

    /**
     * @brief Initialize the module. Call once from setup().
     */
    bool init();

    /**
     * @brief Start decoding on specified CC1101 module and frequency.
     * @param ccModule CC1101 module index (0 or 1)
     * @param frequency Frequency in MHz (e.g. 433.92)
     * @return true if started successfully
     */
    bool startDecode(int ccModule, float frequency);

    /**
     * @brief Stop decoding and release CC1101 module.
     */
    void stopDecode();

    /**
     * @brief Get current module state.
     */
    PPState getState() const { return state_; }

    /**
     * @brief Get decode history.
     */
    ProtoPirateHistory& getHistory() { return history_; }

    /**
     * @brief Clear decode history.
     */
    void clearHistory();

    /**
     * @brief Get history entry count.
     */
    int getHistoryCount() const { return history_.getCount(); }

    /**
     * @brief Send a history entry over BLE.
     * @param index Entry index (0 = newest)
     */
    bool sendHistoryEntry(int index);

    /**
     * @brief Send history count over BLE.
     */
    void sendHistoryCount();

    /**
     * @brief Send current status over BLE.
     */
    void sendStatus();

    /**
     * @brief Load a .sub file from SD and feed its RAW data to decoders.
     *
     * Useful for offline testing / diagnostics without RF reception.
     * @param filePath Full path to the .sub file on the SD card.
     * @return true if at least one protocol decoded the file.
     */
    bool loadSubFile(const char* filePath);

    /**
     * @brief Emulate (transmit) a previously decoded signal.
     *
     * Looks up the protocol by name, calls generatePulseData() and
     * transmits via CC1101.  Optionally increments the rolling counter.
     *
     * @param result     Decoded result to re-encode and transmit.
     * @param ccModule   CC1101 module to use for TX (0 or 1).
     * @param repeatCount Number of times to repeat the transmission (1-10).
     * @return true if transmission succeeded.
     */
    bool emulate(const PPDecodeResult& result, int ccModule, int repeatCount = 3);

    /**
     * @brief Save a decoded result to SD card as a .sub file.
     *
     * Creates /DATA/PROTOPIRATE/ if it does not exist.
     * Generates the pulse data from the protocol encoder and writes
     * a Flipper-compatible RAW .sub file.
     *
     * @param result  Decoded result to save.
     * @param[out] outPath  Receives the saved file path.
     * @return true if saved successfully.
     */
    bool saveCapture(const PPDecodeResult& result, std::string& outPath);

private:
    ProtoPirateModule() = default;
    ~ProtoPirateModule() = default;
    ProtoPirateModule(const ProtoPirateModule&) = delete;
    ProtoPirateModule& operator=(const ProtoPirateModule&) = delete;

    // FreeRTOS decode task
    static void decodeTask(void* param);
    void processLoop();

    // Feed samples to all decoders
    void feedSamplesToDecoders(const std::vector<unsigned long>& samples);

    // Notify BLE clients of a new decode result
    void notifyDecodeResult(const PPDecodeResult& result);

    // Notify BLE clients of TX status changes
    void notifyTxStatus(uint8_t state, uint8_t errCode = 0);

    // Notify BLE clients of save result
    void notifySaveResult(bool success, const char* path);

    // Find a protocol decoder by name (for emulate/save)
    PPProtocol* findProtocolByName(const char* name);

    // Protocol decoder instances
    std::vector<std::unique_ptr<PPProtocol>> decoders_;

    // History
    ProtoPirateHistory history_;

    // State
    PPState state_ = PPState::Idle;
    int activeModule_ = -1;
    float activeFrequency_ = 0.0f;

    /// Count of RF signals analyzed in the current decode session
    volatile uint32_t signalCount_ = 0;

    // Task
    TaskHandle_t taskHandle_ = nullptr;
    SemaphoreHandle_t mutex_ = nullptr;
    volatile bool stopRequested_ = false;

    // Task stack (static allocation — no heap fragmentation)
    static constexpr size_t TASK_STACK_SIZE = 4096;
    static StackType_t taskStack_[TASK_STACK_SIZE];
    static StaticTask_t taskTcb_;

    static constexpr const char* TAG = "ProtoPirate";
};

#endif // ProtoPirateModule_h
