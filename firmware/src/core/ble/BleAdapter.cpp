#if EVILCROW_BT_MODE
#include "BleAdapter.h"
#include "core/ClientsManager.h"
#include "ConfigManager.h"
// Security APIs (setSecurityAuth / setSecurityIOCap / BLE_HS_IO_*) are
// already provided through NimBLEDevice.h (included by BleAdapter.h).
// The legacy NimBLESecurity.h header does not exist in NimBLE-Arduino 2.x.

static const char* TAG = "BleAdapter";

void BleAdapter::heartbeatTimerCallback(TimerHandle_t xTimer) {
    BleAdapter* adapter = static_cast<BleAdapter*>(pvTimerGetTimerID(xTimer));
    if (adapter == nullptr || !adapter->deviceConnected) {
        return;
    }
    // Send heartbeat directly via ClientsManager's queue with 0 timeout.
    // IMPORTANT: Timer callbacks MUST NOT block (portMAX_DELAY is unsafe here).
    // If the queue is full, the heartbeat is dropped — next one is 2.5s away.
    Notification notification;
    notification.type = NotificationType::Unknown;
    notification.isBinary = true;
    notification.messageLength = 1;
    notification.binaryData[0] = 0x82;
    QueueHandle_t q = ClientsManager::getInstance().getQueueHandle();
    if (q != nullptr) {
        xQueueSend(q, &notification, 0);
    }
    ESP_LOGV(TAG, "Heartbeat enqueued");
}

extern ClientsManager& clients;

// Static member definitions
const char* BleAdapter::SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const char* BleAdapter::CHARACTERISTIC_UUID_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
const char* BleAdapter::CHARACTERISTIC_UUID_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

BleAdapter* BleAdapter::instance = nullptr;
SemaphoreHandle_t BleAdapter::sendChunkMutex = nullptr;
TimerHandle_t BleAdapter::heartbeatTimer = nullptr;

BleAdapter::BleAdapter()
    : pServer(nullptr), pService(nullptr),
      pTxCharacteristic(nullptr), pRxCharacteristic(nullptr),
      serverCallbacks(nullptr), characteristicCallbacks(nullptr)
{
    instance = this;
}

BleAdapter::~BleAdapter() {
    if (pServer != nullptr) {
        NimBLEDevice::deinit(true);
    }
}

void BleAdapter::begin() {
    ESP_LOGI(TAG, "Initializing BLE adapter...");

    // Read device name from ConfigManager
    const char* bleName = ConfigManager::getDeviceName();
    ESP_LOGI(TAG, "Using device name: %s", bleName);

    // Initialize NimBLE with device name
    NimBLEDevice::init(bleName);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9); // +9dBm

    // Enable just-works bonding (no passkey, no MITM)
    NimBLEDevice::setSecurityAuth(false, false, true);  // bonding enabled, no MITM, secure connections
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);  // just-works

    // Create BLE Server
    pServer = NimBLEDevice::createServer();
    serverCallbacks = new ServerCallbacks(this);
    pServer->setCallbacks(serverCallbacks);

    // Create Service
    pService = pServer->createService(SERVICE_UUID);

    // Create TX Characteristic (for sending data to client)
    pTxCharacteristic = pService->createCharacteristic(
        CHARACTERISTIC_UUID_TX,
        NIMBLE_PROPERTY::NOTIFY
    );

    // Create RX Characteristic (for receiving data from client)
    pRxCharacteristic = pService->createCharacteristic(
        CHARACTERISTIC_UUID_RX,
        NIMBLE_PROPERTY::WRITE_NR
    );

    characteristicCallbacks = new CharacteristicCallbacks(this);
    pRxCharacteristic->setCallbacks(characteristicCallbacks);

    // Start the service
    pService->start();

    // Start advertising
    NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->enableScanResponse(true);
    pAdvertising->start();

    // Create heartbeat timer (callback on Core 0's timer task)
    heartbeatTimer = xTimerCreate(
        "BLE_Heartbeat",
        pdMS_TO_TICKS(2500),          // 2.5 seconds
        pdTRUE,                       // Auto-reload
        this,                         // Timer ID = adapter instance
        heartbeatTimerCallback
    );
    if (heartbeatTimer != nullptr) {
        xTimerStart(heartbeatTimer, 0);
    }

    ESP_LOGI(TAG, "BLE adapter initialized. Device name: %s", bleName);
}

void BleAdapter::notify(String type, std::string message) {
    if (!isTransportConnected()) return;

    // Use raw data with length to preserve null bytes in binary data.
    // String(message.c_str()) would truncate at the first 0x00 byte.
    const char* rawData = message.data();
    size_t rawLen = message.length();

    if (rawLen <= MAX_CHUNK_SIZE) {
        sendSingleChunk(_lastRequestChunkId, 1, 1, rawData, static_cast<uint16_t>(rawLen));
    } else {
        // Chunk manually without String conversion
        uint8_t chunkId = _lastRequestChunkId != 0 ? _lastRequestChunkId : static_cast<uint8_t>(random(1, 255));
        uint8_t totalChunks = (rawLen + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE;
        for (uint8_t i = 0; i < totalChunks; i++) {
            uint8_t chunkNum = i + 1;
            size_t startPos = i * MAX_CHUNK_SIZE;
            size_t chunkLen = std::min((size_t)MAX_CHUNK_SIZE, rawLen - startPos);
            sendSingleChunk(chunkId, chunkNum, totalChunks,
                          rawData + startPos, static_cast<uint16_t>(chunkLen));
        }
    }
}

// ── Override: send a fully-formed binary frame over BLE notify ──────

void BleAdapter::sendFrame(const uint8_t* data, size_t len) {
    if (!deviceConnected || !pTxCharacteristic) return;

    // Create NimBLE attribute value and notify
    NimBLEAttValue val(data, len);
    pTxCharacteristic->setValue(val);
    pTxCharacteristic->notify();
}

// ── Binary protocol method ──────────────────────────────────────────

void BleAdapter::processBinaryData(uint8_t *data, size_t len) {
    // Delegate to SharedProtocolHandler
    BinaryProtocolHandler::processBinaryData(data, len);
}

// ── File streaming ──────────────────────────────────────────────────

void BleAdapter::streamFileData(const uint8_t* header, size_t headerSize,
                                 File& file, size_t fileSize)
{
    BinaryProtocolHandler::streamFileData(header, headerSize, file, fileSize);
}

// ── Server Callbacks ────────────────────────────────────────────────

void BleAdapter::ServerCallbacks::onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) {
    adapter->deviceConnected = true;
    ESP_LOGI(TAG, "BLE client connected");
    NimBLEDevice::stopAdvertising();

    // Notify system
    clients.notifyAll(NotificationType::DeviceInfo,
        "{\"type\":\"ble_connected\"}");
}

void BleAdapter::ServerCallbacks::onDisconnect(NimBLEServer* pServer,
                                                NimBLEConnInfo& connInfo, int reason) {
    adapter->deviceConnected = false;
    ESP_LOGI(TAG, "BLE client disconnected (reason: %d)", reason);

    // Restart advertising for reconnections
    NimBLEDevice::startAdvertising();

    // Notify system
    clients.notifyAll(NotificationType::DeviceInfo,
        "{\"type\":\"ble_disconnected\"}");
}

void BleAdapter::CharacteristicCallbacks::onSubscribe(
    NimBLECharacteristic* pCharacteristic,
    NimBLEConnInfo& connInfo,
    uint16_t subscriptionValue)
{
    ESP_LOGI(TAG, "Client subscribed to notifications (value: %d)", subscriptionValue);
}

void BleAdapter::CharacteristicCallbacks::onWrite(
    NimBLECharacteristic* pCharacteristic,
    NimBLEConnInfo& connInfo)
{
    NimBLEAttValue val = pCharacteristic->getValue();
    size_t len = val.length();
    uint8_t* data = const_cast<uint8_t*>(val.data());

    // Small hex preview for debugging
    if (len > 0 && len <= 16) {
        char hexPreview[3 * 16 + 1] = {0};
        for (size_t i = 0; i < len; ++i) {
            snprintf(hexPreview + i * 3, 4, "%02X ", data[i]);
        }
        ESP_LOGI(TAG, "BLE RX (%zu bytes): %s", len, hexPreview);
    }

    // Delegate to shared binary protocol handler
    adapter->processBinaryData(data, len);
}
#endif
