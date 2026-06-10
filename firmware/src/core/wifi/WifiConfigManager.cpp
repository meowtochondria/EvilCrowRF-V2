#include "WifiConfigManager.h"
#include "ConfigManager.h"

static const char* TAG = "WifiConfigManager";

// ── Static member definitions ─────────────────────────────────────────

WifiConfigManager::State WifiConfigManager::state_ = State::ConnectSaved;
unsigned long WifiConfigManager::smartConfigStart_ = 0;
unsigned long WifiConfigManager::softAPStart_ = 0;
unsigned long WifiConfigManager::connectStart_ = 0;
int WifiConfigManager::connectRetries_ = 0;
DNSServer* WifiConfigManager::dnsServer_ = nullptr;
AsyncWebServer* WifiConfigManager::captiveServer_ = nullptr;

const char* WifiConfigManager::NVS_NAMESPACE = "wificfg";
const char* WifiConfigManager::NVS_KEY_SSID   = "ssid";
const char* WifiConfigManager::NVS_KEY_PASS   = "pass";

// ── Public API ────────────────────────────────────────────────────────

WifiConfigManager::ProvisionResult WifiConfigManager::begin() {
    ESP_LOGI(TAG, "WifiConfigManager::begin()");

    // Set WiFi to STA mode
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);

    // Attempt to connect with saved credentials
    if (hasSavedCredentials()) {
        state_ = State::ConnectSaved;
        connectStart_ = millis();
        connectRetries_ = 0;

        if (tryConnectSaved()) {
            state_ = State::Connected;
            ESP_LOGI(TAG, "Connected to saved WiFi: %s, IP: %s",
                     WiFi.SSID().c_str(), WiFi.localIP().toString().c_str());
            return ProvisionResult::Connected;
        }
    }

    // No saved credentials or connection failed — start SmartConfig
    ESP_LOGI(TAG, "Starting SmartConfig provisioning...");
    state_ = State::SmartConfig;
    smartConfigStart_ = millis();
    startSmartConfig();

    return ProvisionResult::Provisioning;
}

void WifiConfigManager::process() {
    switch (state_) {
        case State::ConnectSaved:
            // Check if connection attempt timed out
            if (millis() - connectStart_ > CONNECT_TIMEOUT_MS) {
                connectRetries_++;
                ESP_LOGW(TAG, "Connection attempt %d/%d timed out",
                         connectRetries_, MAX_CONNECT_RETRIES);

                if (connectRetries_ >= MAX_CONNECT_RETRIES) {
                    // Fall through to SmartConfig
                    ESP_LOGI(TAG, "Max connection retries reached, starting SmartConfig");
                    state_ = State::SmartConfig;
                    smartConfigStart_ = millis();
                    startSmartConfig();
                } else {
                    // Retry
                    WiFi.disconnect(true);
                    connectStart_ = millis();
                    WiFi.reconnect();
                }
            } else {
                // Check if we connected
                if (WiFi.status() == WL_CONNECTED) {
                    state_ = State::Connected;
                    ESP_LOGI(TAG, "Connected to WiFi: %s, IP: %s",
                             WiFi.SSID().c_str(), WiFi.localIP().toString().c_str());
                }
            }
            break;

        case State::SmartConfig:
            if (WiFi.smartConfigDone()) {
                // SmartConfig received credentials — save and try connecting
                ESP_LOGI(TAG, "SmartConfig received credentials");

                // Give WiFi time to connect
                if (WiFi.status() == WL_CONNECTED) {
                    String ssid = WiFi.SSID();
                    String pass = WiFi.psk();
                    saveCredentials(ssid, pass);

                    WiFi.stopSmartConfig();
                    state_ = State::Connected;
                    ESP_LOGI(TAG, "SmartConfig: Connected to %s, IP: %s",
                             ssid.c_str(), WiFi.localIP().toString().c_str());
                }
            } else if (millis() - smartConfigStart_ > SMART_CONFIG_TIMEOUT_MS) {
                // SmartConfig timed out — fall back to SoftAP
                WiFi.stopSmartConfig();
                ESP_LOGI(TAG, "SmartConfig timed out, starting SoftAP portal");
                state_ = State::SoftAP;
                softAPStart_ = millis();
                startSoftAP();
            }
            break;

        case State::SoftAP:
            // Check if we got credentials via captive portal
            if (WiFi.status() == WL_CONNECTED) {
                stopSoftAP();
                state_ = State::Connected;
                ESP_LOGI(TAG, "SoftAP: Connected to %s, IP: %s",
                         WiFi.SSID().c_str(), WiFi.localIP().toString().c_str());
            }

            // Handle captive portal DNS
            if (dnsServer_ && captiveServer_) {
                dnsServer_->processNextRequest();
            }

            // Check for timeout
            if (millis() - softAPStart_ > SOFTAP_TIMEOUT_MS) {
                ESP_LOGW(TAG, "SoftAP provisioning timed out, restarting SmartConfig");
                stopSoftAP();
                state_ = State::SmartConfig;
                smartConfigStart_ = millis();
                startSmartConfig();
            }
            break;

        case State::Connected:
            // Monitor connection — if dropped, attempt reconnection
            if (WiFi.status() != WL_CONNECTED) {
                ESP_LOGW(TAG, "WiFi connection lost, attempting reconnect...");
                state_ = State::ConnectSaved;
                connectStart_ = millis();
                connectRetries_ = 0;
                WiFi.reconnect();
            }
            break;
    }
}

bool WifiConfigManager::isConnected() {
    return state_ == State::Connected && WiFi.status() == WL_CONNECTED;
}

IPAddress WifiConfigManager::localIP() {
    return WiFi.localIP();
}

String WifiConfigManager::getMdnsHostname() {
    const char* deviceName = ConfigManager::getDeviceName();
    String hostname = String(deviceName);
    hostname.replace(" ", "-");
    hostname.toLowerCase();
    return hostname;
}

void WifiConfigManager::saveCredentials(const String& ssid, const String& password) {
    Preferences prefs;
    prefs.begin(NVS_NAMESPACE, false);
    prefs.putString(NVS_KEY_SSID, ssid);
    prefs.putString(NVS_KEY_PASS, password);
    prefs.end();
    ESP_LOGI(TAG, "WiFi credentials saved to NVS");
}

void WifiConfigManager::clearCredentials() {
    Preferences prefs;
    prefs.begin(NVS_NAMESPACE, false);
    prefs.remove(NVS_KEY_SSID);
    prefs.remove(NVS_KEY_PASS);
    prefs.end();
    ESP_LOGI(TAG, "WiFi credentials cleared from NVS");
}

bool WifiConfigManager::hasSavedCredentials() {
    Preferences prefs;
    prefs.begin(NVS_NAMESPACE, true);
    bool hasSsid = prefs.isKey(NVS_KEY_SSID);
    prefs.end();
    return hasSsid;
}

String WifiConfigManager::getCurrentSSID() {
    if (WiFi.status() == WL_CONNECTED) {
        return WiFi.SSID();
    }
    return "";
}

int32_t WifiConfigManager::getRSSI() {
    if (WiFi.status() == WL_CONNECTED) {
        return WiFi.RSSI();
    }
    return 0;
}

void WifiConfigManager::resetState() {
    state_ = State::ConnectSaved;
    connectRetries_ = 0;
}

// ── Internal methods ──────────────────────────────────────────────────

bool WifiConfigManager::tryConnectSaved() {
    Preferences prefs;
    prefs.begin(NVS_NAMESPACE, true);

    String ssid = prefs.getString(NVS_KEY_SSID, "");
    String pass = prefs.getString(NVS_KEY_PASS, "");
    prefs.end();

    if (ssid.length() == 0) {
        ESP_LOGD(TAG, "No saved SSID found");
        return false;
    }

    ESP_LOGI(TAG, "Connecting to saved WiFi: %s", ssid.c_str());
    WiFi.begin(ssid.c_str(), pass.c_str());

    // Wait for connection with timeout
    unsigned long start = millis();
    while (millis() - start < CONNECT_TIMEOUT_MS) {
        if (WiFi.status() == WL_CONNECTED) {
            return true;
        }
        delay(100); // Small delay between checks
    }

    ESP_LOGW(TAG, "Failed to connect to saved WiFi: %s", ssid.c_str());
    return false;
}

void WifiConfigManager::startSmartConfig() {
    ESP_LOGI(TAG, "Starting SmartConfig (ESP-TOUCH)...");
    WiFi.mode(WIFI_AP_STA); // Need AP mode for SmartConfig to work
    WiFi.beginSmartConfig();
}

void WifiConfigManager::startSoftAP() {
    String ssid = generateSoftAPSSID();
    ESP_LOGI(TAG, "Starting SoftAP: %s", ssid.c_str());

    // Start AP mode
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(ssid.c_str(), nullptr, 1, 0, 1); // SSID, no password, ch1, hidden=0, max=1 client

    IPAddress apIP(192, 168, 4, 1);
    WiFi.softAPConfig(apIP, apIP, IPAddress(255, 255, 255, 0));

    ESP_LOGI(TAG, "SoftAP IP: %s", apIP.toString().c_str());

    // Start DNS server for captive portal
    if (!dnsServer_) {
        dnsServer_ = new DNSServer();
    }
    dnsServer_->setErrorReplyCode(DNSReplyCode::NoError);
    dnsServer_->start(53, "*", apIP);

    // Start captive portal HTTP server
    if (!captiveServer_) {
        captiveServer_ = new AsyncWebServer(80);
    }

    captiveServer_->on("/", HTTP_GET, [](AsyncWebServerRequest* request) {
        String html = "<!DOCTYPE html><html><head>"
                      "<meta name='viewport' content='width=device-width, initial-scale=1'>"
                      "<title>EvilCrow RF WiFi Setup</title>"
                      "<style>body{font-family:sans-serif;margin:20px;}"
                      "input{width:100%;padding:8px;margin:8px 0;}"
                      "button{width:100%;padding:10px;background:#4CAF50;color:white;border:none;}"
                      "</style></head><body>"
                      "<h2>EvilCrow RF WiFi Setup</h2>"
                      "<form method='POST' action='/connect'>"
                      "SSID: <input type='text' name='ssid'><br>"
                      "Password: <input type='password' name='pass'><br>"
                      "<button type='submit'>Connect</button>"
                      "</form></body></html>";
        request->send(200, "text/html", html);
    });

    captiveServer_->on("/connect", HTTP_POST, [](AsyncWebServerRequest* request) {
        String ssid = request->hasParam("ssid", true)
                      ? request->getParam("ssid", true)->value() : "";
        String pass = request->hasParam("pass", true)
                      ? request->getParam("pass", true)->value() : "";

        if (ssid.length() > 0) {
            saveCredentials(ssid, pass);
            request->send(200, "text/html",
                "<html><body><h2>Connecting...</h2>"
                "<p>Device will now connect to " + ssid + ".</p>"
                "<p>Reconnect your phone to your home network and open the app.</p>"
                "</body></html>");

            // Switch to STA mode and connect
            WiFi.mode(WIFI_STA);
            WiFi.begin(ssid.c_str(), pass.c_str());
        } else {
            request->send(400, "text/html",
                "<html><body><h2>Error</h2><p>SSID is required.</p>"
                "<a href='/'>Back</a></body></html>");
        }
    });

    // Catch-all: redirect to captive portal
    captiveServer_->onNotFound([](AsyncWebServerRequest* request) {
        request->redirect("http://192.168.4.1/");
    });

    captiveServer_->begin();
    ESP_LOGI(TAG, "Captive portal started on 192.168.4.1:80");
}

void WifiConfigManager::stopSoftAP() {
    if (captiveServer_) {
        captiveServer_->end();
        delete captiveServer_;
        captiveServer_ = nullptr;
    }
    if (dnsServer_) {
        dnsServer_->stop();
        delete dnsServer_;
        dnsServer_ = nullptr;
    }
    WiFi.softAPdisconnect(true);
    ESP_LOGI(TAG, "SoftAP and captive portal stopped");
}

void WifiConfigManager::handleCaptivePortal() {
    // Handled in process() via dnsServer_->processNextRequest()
}

String WifiConfigManager::generateSoftAPSSID() {
    // Generate a unique SSID based on device name + MAC suffix
    const char* deviceName = ConfigManager::getDeviceName();
    String apName = String(deviceName);
    apName.replace(" ", "-");
    apName.toLowerCase();

    // Truncate to reasonable length and append "-Config"
    if (apName.length() > 20) {
        apName = apName.substring(0, 20);
    }
    apName += "-Config";

    return apName;
}
