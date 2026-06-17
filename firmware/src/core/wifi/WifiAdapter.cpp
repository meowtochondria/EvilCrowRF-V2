#include "WifiAdapter.h"
#include "WifiConfigManager.h"
#include "core/ClientsManager.h"
#include "ConfigManager.h"
#include <cstdio>

static const char* TAG = "WifiAdapter";

// Static instance
WifiAdapter* WifiAdapter::instance = nullptr;

// ── Constructor / Destructor ───────────────────────────────────────────

WifiAdapter::WifiAdapter()
    : server_(80),
      ws_(server_, "/api/ws")
{
    instance = this;
}

WifiAdapter::~WifiAdapter() {
    // Cleanup: WebSocket, server, and WiFi will be stopped on shutdown
}

// ── begin() — Full WiFi + Services Initialization ─────────────────────

void WifiAdapter::begin() {
    ESP_LOGI(TAG, "Initializing WiFi adapter...");

    // ── Phase 1: WiFi provisioning ──────────────────────────────────
    WifiConfigManager::ProvisionResult result = WifiConfigManager::begin();

    if (result == WifiConfigManager::ProvisionResult::Connected) {
        wifiConnected_ = true;
        ESP_LOGI(TAG, "WiFi connected: %s, IP: %s",
                 WifiConfigManager::getCurrentSSID().c_str(),
                 WifiConfigManager::localIP().toString().c_str());
    } else {
        ESP_LOGI(TAG, "WiFi provisioning in progress...");
        // process() will be called from the main loop
        wifiConnected_ = false;
        // Still set up web server in AP mode for captive portal
    }

    // ── Phase 2: Start AsyncWebServer ───────────────────────────────
    registerRestEndpoints();

    // ── Phase 3: Start WebSocket handler ────────────────────────────
    ws_.begin();
    ws_.onBinaryData([this](uint8_t* data, size_t len) { onWsData(data, len); });
    ws_.onConnect([this](bool connected) { onWsConnect(connected); });

    // Add WebSocket to the server
    server_.addHandler(ws_.getSocket());

    // ── Phase 4: Start mDNS (if WiFi connected) ────────────────────
    if (wifiConnected_) {
        String mdnsHostname = WifiConfigManager::getMdnsHostname();
        const char* deviceName = ConfigManager::getDeviceName();

        if (MDNS.begin(mdnsHostname.c_str())) {
            MDNS.addService("_evilcrow", "_tcp", 80);
            MDNS.addServiceTxt("_evilcrow", "_tcp", "name", deviceName);
            MDNS.addServiceTxt("_evilcrow", "_tcp", "fw_version", FIRMWARE_VERSION_STRING);
            MDNS.addServiceTxt("_evilcrow", "_tcp", "transport", "websocket");
            ESP_LOGI(TAG, "mDNS started as %s.local", mdnsHostname.c_str());
        } else {
            ESP_LOGE(TAG, "mDNS responder failed to start");
        }
    }

    // ── Phase 5: Start server ───────────────────────────────────────
    server_.begin();
    ESP_LOGI(TAG, "AsyncWebServer started on port 80");

    // ── Phase 6: Log connection hint ─────────────────────────────────
    ESP_LOGI(TAG, "=== Device is reachable via SoftAP: SSID='%s', IP=192.168.4.1 ===",
             WiFi.softAPSSID().c_str());
    ESP_LOGI(TAG, "=== If connecting via home WiFi: check logs for STA IP and connect phone to THAT network ===");
}

// ── wifiCheck() — Called from main loop to detect STA connection transitions ──

void WifiAdapter::wifiCheck() {
    bool staConnected = WifiConfigManager::isConnected();
    if (staConnected && !wifiConnected_) {
        // STA just came up — start mDNS
        wifiConnected_ = true;
        String mdnsHostname = WifiConfigManager::getMdnsHostname();
        const char* deviceName = ConfigManager::getDeviceName();
        if (MDNS.begin(mdnsHostname.c_str())) {
            MDNS.addService("_evilcrow", "_tcp", 80);
            MDNS.addServiceTxt("_evilcrow", "_tcp", "name", deviceName);
            MDNS.addServiceTxt("_evilcrow", "_tcp", "fw_version", FIRMWARE_VERSION_STRING);
            MDNS.addServiceTxt("_evilcrow", "_tcp", "transport", "websocket");
            ESP_LOGI(TAG, "=== STA CONNECTED: %s (%s) ===",
                     mdnsHostname.c_str(), WiFi.localIP().toString().c_str());
            ESP_LOGI(TAG, "=== Connect phone to the SAME WiFi network and use IP or mDNS ===");
        }
    } else if (!staConnected && wifiConnected_) {
        // STA dropped
        wifiConnected_ = false;
        ESP_LOGW(TAG, "STA connection lost. SoftAP remains active at 192.168.4.1");
    }
}

// ── notify() — Send notification via WebSocket binary frames ─────────

void WifiAdapter::notify(String type, std::string message) {
    // Delegate to BinaryProtocolHandler's send logic
    sendBinaryResponse(String(message.c_str()));
}

// ── isConnected() ──────────────────────────────────────────────────────

bool WifiAdapter::isConnected() const {
    // Consider "connected" when WiFi is up AND we have a WebSocket client
    return wifiConnected_ && wsClientConnected_;
}

// ── BinaryProtocolHandler overrides ────────────────────────────────────

void WifiAdapter::sendFrame(const uint8_t* data, size_t len) {
    if (!wsClientConnected_) return;
    ws_.sendBinary(data, len);
}

bool WifiAdapter::isTransportConnected() const {
    return wsClientConnected_;
}

// ── WebSocket callbacks ───────────────────────────────────────────────

void WifiAdapter::onWsData(uint8_t* data, size_t len) {
    ESP_LOGD(TAG, "WebSocket binary data received: %zu bytes", len);
    BinaryProtocolHandler::processBinaryData(data, len);
}

void WifiAdapter::onWsConnect(bool connected) {
    wsClientConnected_ = connected;
    ClientsManager& cm = ClientsManager::getInstance();
    if (connected) {
        ESP_LOGI(TAG, "WebSocket client connected");
        cm.notifyAll(NotificationType::DeviceInfo,
            "{\"type\":\"wifi_connected\"}");
    } else {
        ESP_LOGI(TAG, "WebSocket client disconnected");
        cm.notifyAll(NotificationType::DeviceInfo,
            "{\"type\":\"wifi_disconnected\"}");
    }
}

// ── REST API Endpoints ────────────────────────────────────────────────

void WifiAdapter::registerRestEndpoints() {
    // GET /api/info — Device info
    server_.on("/api/info", HTTP_GET, [this](AsyncWebServerRequest* request) {
        request->send(200, "application/json", formatDeviceInfo());
    });

    // GET /api/status — Device status
    server_.on("/api/status", HTTP_GET, [this](AsyncWebServerRequest* request) {
        request->send(200, "application/json", formatDeviceStatus());
    });

    // GET /scan — Captive portal landing (redirect to root)
    server_.on("/scan", HTTP_GET, [](AsyncWebServerRequest* request) {
        request->redirect("/");
    });
}

// ── JSON helpers (non-static — access member state) ───────────────────

String WifiAdapter::formatDeviceInfo() {
    String json;
    json.reserve(256);

    const char* deviceName = ConfigManager::getDeviceName();

    json += "{";
    json += "\"device_name\":\"" + String(deviceName) + "\",";
    json += "\"fw_version\":\"" + String(FIRMWARE_VERSION_STRING) + "\",";
    json += "\"free_heap\":" + String(ESP.getFreeHeap()) + ",";
    json += "\"uptime\":" + String(millis() / 1000) + ",";
    json += "\"transport\":\"websocket\",";
    json += "\"rssi\":" + String(WifiConfigManager::getRSSI());
    json += "}";

    return json;
}

String WifiAdapter::formatDeviceStatus() {
    String json;
    json.reserve(256);

    json += "{";
    json += "\"connected\":" + String(isConnected() ? "true" : "false") + ",";
    json += "\"wifi_connected\":" + String(wifiConnected_ ? "true" : "false") + ",";
    json += "\"ws_connected\":" + String(wsClientConnected_ ? "true" : "false") + ",";
    json += "\"ssid\":\"" + WifiConfigManager::getCurrentSSID() + "\",";
    json += "\"ip\":\"" + WifiConfigManager::localIP().toString() + "\"";
    json += "}";

    return json;
}
