#include "WifiConfigManager.h"
#include "ConfigManager.h"

static const char* TAG = "WifiConfigManager";

// ── Static member definitions ─────────────────────────────────────────

WifiConfigManager::State WifiConfigManager::state_ = State::SoftAP;
unsigned long WifiConfigManager::connectStart_ = 0;
int WifiConfigManager::connectRetries_ = 0;
bool WifiConfigManager::_staDisabled = false;

const char* WifiConfigManager::NVS_NAMESPACE = "wificfg";
const char* WifiConfigManager::NVS_KEY_SSID   = "ssid";
const char* WifiConfigManager::NVS_KEY_PASS   = "pass";

// ── Public API ────────────────────────────────────────────────────────

WifiConfigManager::ProvisionResult WifiConfigManager::begin() {
    ESP_LOGI(TAG, "WifiConfigManager::begin()");

    // Start SoftAP immediately so the device is reachable within ~1 second of boot.
    // STA mode connection runs in the background — process() checks outcome.
    state_ = State::SoftAP;
    startSoftAP();

    // Attempt to connect with saved credentials (non-blocking)
    if (hasSavedCredentials()) {
        ESP_LOGI(TAG, "Saved WiFi credentials found for SSID, connecting in background...");
        connectStart_ = millis();
        connectRetries_ = 0;
        tryConnectSaved();  // Kicks off async WiFi.begin()
    } else {
        ESP_LOGI(TAG, "No saved WiFi credentials found — SoftAP only");
        ESP_LOGI(TAG, "Connect phone to WiFi SSID: '%s' and use the app on 192.168.4.1",
                 WiFi.softAPSSID().c_str());
    }

    return ProvisionResult::Provisioning;
}

void WifiConfigManager::process() {
    switch (state_) {
        case State::SoftAP:
            // If STA credentials exist AND STA is not disabled,
            // monitor the background connection attempt.
            if (hasSavedCredentials() && !_staDisabled) {
                if (WiFi.status() == WL_CONNECTED) {
                    // STA connection succeeded — transition out of SoftAP
                    stopSoftAP();
                    state_ = State::Connected;
                    ESP_LOGI(TAG, "STA connection succeeded: %s, IP: %s",
                             WiFi.SSID().c_str(), WiFi.localIP().toString().c_str());
                    return;
                }

                // Check timeout for the current STA attempt
                if (millis() - connectStart_ > CONNECT_TIMEOUT_MS) {
                    connectRetries_++;
                    ESP_LOGW(TAG, "STA connection attempt %d/%d timed out",
                             connectRetries_, MAX_CONNECT_RETRIES);

                    if (connectRetries_ < MAX_CONNECT_RETRIES) {
                        // Retry — SoftAP remains active so device is still reachable
                        connectStart_ = millis();
                        WiFi.disconnect(true);
                        delay(10);
                        tryConnectSaved();
                    } else {
                        // Give up on STA — stay in SoftAP mode
                        ESP_LOGW(TAG, "Max STA retries reached. Staying in SoftAP mode.");
                        ESP_LOGI(TAG, "Connect phone to SSID '%s' and use the app on 192.168.4.1",
                                 WiFi.softAPSSID().c_str());
                        connectRetries_ = 0;
                    }
                }
            }
            break;

        case State::Connected:
            // Monitor connection — if dropped, restart SoftAP + try STA reconnect
            if (WiFi.status() != WL_CONNECTED) {
                ESP_LOGW(TAG, "WiFi connection lost to %s, restarting SoftAP + reconnect",
                         WiFi.SSID().c_str());
                state_ = State::SoftAP;
                connectStart_ = millis();
                connectRetries_ = 0;
                startSoftAP();
                WiFi.reconnect();
            }
            break;

        default:
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
    prefs.begin(NVS_NAMESPACE, false);
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
    state_ = State::SoftAP;
    connectRetries_ = 0;
}

void WifiConfigManager::softAPOnly() {
    ESP_LOGI(TAG, "Entering SoftAP-only mode — STA disabled");
    _staDisabled = true;
    WiFi.disconnect(true);
    WiFi.mode(WIFI_AP);
    state_ = State::SoftAP;
    connectRetries_ = 0;
    connectStart_ = 0;
}

// ── Internal methods ──────────────────────────────────────────────────

bool WifiConfigManager::tryConnectSaved() {
    Preferences prefs;
    prefs.begin(NVS_NAMESPACE, false);

    String ssid = prefs.getString(NVS_KEY_SSID, "");
    String pass = prefs.getString(NVS_KEY_PASS, "");
    prefs.end();

    if (ssid.length() == 0) {
        ESP_LOGD(TAG, "No saved SSID found");
        return false;
    }

    ESP_LOGI(TAG, "Initiating connection to saved WiFi: %s", ssid.c_str());
    WiFi.begin(ssid.c_str(), pass.c_str());

    return true;
}

void WifiConfigManager::startSoftAP() {
    String ssid = generateSoftAPSSID();
    ESP_LOGI(TAG, "Starting SoftAP: %s", ssid.c_str());

    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(ssid.c_str(), nullptr, 1, 0, 1);

    IPAddress apIP(192, 168, 4, 1);
    WiFi.softAPConfig(apIP, apIP, IPAddress(255, 255, 255, 0));

    ESP_LOGI(TAG, "SoftAP ready: SSID='%s', IP=%s", ssid.c_str(), apIP.toString().c_str());
    ESP_LOGI(TAG, "Connect phone to WiFi '%s' and open the app — it will find the device at %s",
             ssid.c_str(), apIP.toString().c_str());
}

void WifiConfigManager::stopSoftAP() {
    WiFi.softAPdisconnect(true);
    ESP_LOGI(TAG, "SoftAP stopped");
}

String WifiConfigManager::generateSoftAPSSID() {
    const char* deviceName = ConfigManager::getDeviceName();
    String apName = String(deviceName);
    apName.replace(" ", "-");
    apName.toLowerCase();

    if (apName.length() > 24) {
        apName = apName.substring(0, 24);
    }

    return apName;
}
