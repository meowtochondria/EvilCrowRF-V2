#ifndef WifiConfigManager_h
#define WifiConfigManager_h

#include <Arduino.h>
#include <WiFi.h>
#include <Preferences.h>

/**
 * WifiConfigManager — WiFi provisioning for EvilCrowRF WiFi transport.
 *
 * On boot, attempts to connect to saved WiFi credentials (NVS).
 * SoftAP starts immediately so the device is always reachable.
 * The app manages WiFi credentials — no captive portal needed.
 */
class WifiConfigManager {
public:
    enum class ProvisionResult {
        Connected,        // Successfully connected to WiFi
        Provisioning,     // Still in provisioning mode (SoftAP)
        Failed            // Provisioning failed
    };

    static ProvisionResult begin();
    static void process();
    static bool isConnected();
    static IPAddress localIP();
    static String getMdnsHostname();
    static void saveCredentials(const String& ssid, const String& password);
    static void clearCredentials();
    static bool hasSavedCredentials();
    static String getCurrentSSID();
    static int32_t getRSSI();
    static void resetState();
    static void startSoftAP();
    static void stopSoftAP();
    static void softAPOnly();

private:
    enum class State {
        SoftAP,
        Connected
    };

    static State state_;
    static unsigned long connectStart_;
    static int connectRetries_;
    static bool _staDisabled;

    static const char* NVS_NAMESPACE;
    static const char* NVS_KEY_SSID;
    static const char* NVS_KEY_PASS;

    static constexpr int MAX_CONNECT_RETRIES = 3;
    static constexpr unsigned long CONNECT_TIMEOUT_MS = 15000;

    static bool tryConnectSaved();
    static String generateSoftAPSSID();
};

#endif // WifiConfigManager_h
