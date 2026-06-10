#if EVILCROW_BT_MODE
#include "BleAdapter.h"
#include "core/ClientsManager.h"
#include "ConfigManager.h"

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
    // Delegate to BinaryProtocolHandler's send logic
    // The message is already formatted; wrap in String and send
    sendBinaryResponse(String(message.c_str()));
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
