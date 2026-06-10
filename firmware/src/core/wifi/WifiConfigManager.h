#ifndef WifiConfigManager_h
#define WifiConfigManager_h

#include <Arduino.h>
#include <WiFi.h>
#include <DNSServer.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <Preferences.h>

/**
 * WifiConfigManager — SmartConfig + SoftAP provisioning for EvilCrowRF WiFi transport.
 *
 * Flow:
 * 1. On boot, attempt to connect to saved WiFi credentials (NVS).
 * 2. If that fails after N retries, start SmartConfig listen mode.
 * 3. If SmartConfig times out, fall back to SoftAP + Captive Portal.
 * 4. Once credentials are obtained, persist in NVS and reboot into STA mode.
 */
class WifiConfigManager {
public:
    /// Result of a provisioning attempt.
    enum class ProvisionResult {
        Connected,        // Successfully connected to WiFi
        Provisioning,     // Still in provisioning mode (SmartConfig or SoftAP)
        Failed            // Provisioning failed
    };

    /// Initialize WiFi in STA mode and attempt connection.
    /// Returns Connected immediately if credentials exist and connection succeeds.
    /// Returns Provisioning if we need to provision.
    static ProvisionResult begin();

    /// Run the provisioning loop (call from loop() when ProvisionResult is Provisioning).
    /// Handles SmartConfig and SoftAP + Captive Portal.
    static void process();

    /// Check if WiFi is connected and has an IP.
    static bool isConnected();

    /// Get the local IP address (valid only when connected).
    static IPAddress localIP();

    /// Get the mDNS hostname (derived from device name).
    static String getMdnsHostname();

    /// Save WiFi credentials to NVS.
    static void saveCredentials(const String& ssid, const String& password);

    /// Clear saved WiFi credentials from NVS.
    static void clearCredentials();

    /// Check if credentials are saved.
    static bool hasSavedCredentials();

    /// Get current SSID (or empty string if not connected).
    static String getCurrentSSID();

    /// Get RSSI of current connection.
    static int32_t getRSSI();

    /// Reset provisioning state (e.g., after credentials received).
    static void resetState();

private:
    // ── Internal state machine ───────────────────────────────────────
    enum class State {
        ConnectSaved,      // Try connecting with saved credentials
        SmartConfig,       // Listening for ESP-TOUCH broadcast
        SoftAP,            // Running SoftAP captive portal
        Connected          // Connected to WiFi
    };

    static State state_;
    static unsigned long smartConfigStart_;
    static unsigned long softAPStart_;
    static unsigned long connectStart_;
    static int connectRetries_;

    // SoftAP + Captive Portal
    static DNSServer* dnsServer_;
    static AsyncWebServer* captiveServer_;

    // NVS namespace
    static const char* NVS_NAMESPACE;
    static const char* NVS_KEY_SSID;
    static const char* NVS_KEY_PASS;

    // Constants
    static constexpr int MAX_CONNECT_RETRIES = 3;
    static constexpr unsigned long SMART_CONFIG_TIMEOUT_MS = 60000;  // 60 seconds
    static constexpr unsigned long SOFTAP_TIMEOUT_MS = 300000;       // 5 minutes
    static constexpr unsigned long CONNECT_TIMEOUT_MS = 15000;       // 15 seconds per attempt

    // ── Internal methods ─────────────────────────────────────────────
    static bool tryConnectSaved();
    static void startSmartConfig();
    static void startSoftAP();
    static void stopSoftAP();
    static void handleCaptivePortal();
    static String generateSoftAPSSID();
};

#endif // WifiConfigManager_h
