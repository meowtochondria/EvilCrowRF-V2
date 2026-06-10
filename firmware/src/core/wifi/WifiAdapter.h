#ifndef WifiAdapter_h
#define WifiAdapter_h

#include <Arduino.h>
#include "config.h"
#include "core/ControllerAdapter.h"
#include <string>
#include <stdint.h>
#include "core/CommandHandler.h"

#include <WiFi.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <ESPmDNS.h>

#include "core/BinaryProtocolHandler.h"
#include "WifiWebSocket.h"

/**
 * WifiAdapter — WiFi + WebSocket transport adapter for EvilCrowRF.
 *
 * Replaces BleAdapter as a ControllerAdapter subclass when built with
 * EVILCROW_WIFI_MODE=1. Provides:
 *   - WiFi STA connection (with SmartConfig / SoftAP provisioning)
 *   - AsyncWebServer for REST API (port 80)
 *   - WebSocket binary transport for the binary protocol (at /api/ws)
 *   - mDNS responder (_evilcrow._tcp)
 */
class WifiAdapter : public ControllerAdapter, public BinaryProtocolHandler {
public:
    WifiAdapter();
    ~WifiAdapter();

    void begin();
    void notify(String type, std::string message) override;
    String getName() override { return "WifiAdapter"; }
    bool isConnected() const override;

    // Set CommandHandler (overrides BinaryProtocolHandler's setter)
    void setCommandHandler(CommandHandler* handler) override { commandHandler_ = handler; }

    // Get the singleton instance
    static WifiAdapter* getInstance() { return instance; }

    // Access the web server for REST endpoint registration
    AsyncWebServer* getServer() { return &server_; }

private:
    static WifiAdapter* instance;

    // Web server (port 80)
    AsyncWebServer server_;

    // WebSocket handler
    WifiWebSocket ws_;

    // ── BinaryProtocolHandler overrides ────────────────────────────
protected:
    void sendFrame(const uint8_t* data, size_t len) override;
    bool isTransportConnected() const override;
    const char* transportName() const override { return "WifiAdapter"; }

private:
    // ── REST API handlers ──────────────────────────────────────────
    void registerRestEndpoints();

    // WebSocket callbacks
    void onWsData(uint8_t* data, size_t len);
    void onWsConnect(bool connected);

    // ── State ──────────────────────────────────────────────────────
    bool wifiConnected_ = false;
    bool wsClientConnected_ = false;

    // ── JSON helpers (non-static — access member state) ────────────
    String formatDeviceInfo();
    String formatDeviceStatus();
};

#endif // WifiAdapter_h
