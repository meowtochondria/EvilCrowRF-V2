#if EVILCROW_BT_MODE
#ifndef BleAdapter_h
#define BleAdapter_h

#include <Arduino.h>
#include "config.h"
#include "core/ControllerAdapter.h"
#include <stdint.h>
#include <atomic>
#include "core/CommandHandler.h"

// NimBLE — lightweight BLE stack (replaces Bluedroid, saves ~30-40 KB RAM)
#include <NimBLEDevice.h>
#include <NimBLEConnInfo.h>
#include "FS.h"

#include "core/BinaryProtocolHandler.h"

class BleAdapter : public ControllerAdapter, public BinaryProtocolHandler {
public:
    BleAdapter();
    ~BleAdapter();
    void begin();
    void notify(String type, std::string message) override;
    String getName() override { return "BleAdapter"; }
    bool isConnected() const override { return deviceConnected; }

    // Set CommandHandler
    void setCommandHandler(CommandHandler* handler) override { commandHandler_ = handler; }

    // File streaming method (public for FileCommands access)
    void streamFileData(const uint8_t* header, size_t headerSize, File& file, size_t fileSize);

    // Binary protocol method (public for serial command processing)
    void processBinaryData(uint8_t *data, size_t len);

    // Set serial command flag (atomic — safe from any core)
    void setSerialCommand(bool flag) { isSerialCommand.store(flag); }

    // Get instance (public for FileCommands access)
    static BleAdapter* getInstance() { return instance; }

private:
    // Server callbacks
    class ServerCallbacks : public NimBLEServerCallbacks {
        BleAdapter* adapter;
        public:
            ServerCallbacks(BleAdapter* adapter) : adapter(adapter) {}
            void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override;
            void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override;
    };

    // Characteristic callbacks for RX (incoming data)
    class CharacteristicCallbacks : public NimBLECharacteristicCallbacks {
        BleAdapter* adapter;
        public:
            CharacteristicCallbacks(BleAdapter* adapter) : adapter(adapter) {}
            void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override;
            void onSubscribe(NimBLECharacteristic* pCharacteristic,
                             NimBLEConnInfo& connInfo,
                             uint16_t subscriptionValue) override;
    };

    NimBLEServer* pServer;
    NimBLEService* pService;
    NimBLECharacteristic* pTxCharacteristic;
    NimBLECharacteristic* pRxCharacteristic;

    ServerCallbacks* serverCallbacks;
    CharacteristicCallbacks* characteristicCallbacks;

    bool deviceConnected = false;

    // BLE UUIDs
    static const char* SERVICE_UUID;
    static const char* CHARACTERISTIC_UUID_TX;
    static const char* CHARACTERISTIC_UUID_RX;

    // ── BinaryProtocolHandler overrides ────────────────────────────
protected:
    void sendFrame(const uint8_t* data, size_t len) override;
    bool isTransportConnected() const override { return deviceConnected; }
    const char* transportName() const override { return "BleAdapter"; }

private:

    // Heartbeat / keepalive
    static TimerHandle_t heartbeatTimer;
    static void heartbeatTimerCallback(TimerHandle_t xTimer);

    // Static instance for callbacks
    static BleAdapter* instance;

    // Mutex protecting static buffer in sendSingleChunk (cross-core safety)
    static SemaphoreHandle_t sendChunkMutex;
};

#endif // BleAdapter_h
#endif // EVILCROW_BT_MODE
