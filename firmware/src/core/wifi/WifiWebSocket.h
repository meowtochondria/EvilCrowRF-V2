#ifndef WifiWebSocket_h
#define WifiWebSocket_h

#include <Arduino.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <stdint.h>
#include <functional>

/**
 * WifiWebSocket — WebSocket handler for the EvilCrowRF binary protocol.
 *
 * Wraps an AsyncWebSocket endpoint (typically at /api/ws) and provides
 * binary frame send/receive that connects to BinaryProtocolHandler.
 */
class WifiWebSocket {
public:
    WifiWebSocket(AsyncWebServer& server, const char* url = "/api/ws");

    /// Start the WebSocket handler (adds handler to the server).
    void begin();

    /// Send a binary frame to the connected client.
    /// Returns the number of bytes sent, or 0 if no client connected.
    size_t sendBinary(const uint8_t* data, size_t len);

    /// Check if at least one WebSocket client is connected.
    bool hasClient() const;

    /// Register a callback for incoming binary data.
    using DataCallback = std::function<void(uint8_t* data, size_t len)>;
    void onBinaryData(DataCallback cb) { dataCallback_ = cb; }

    /// Register a callback for connect/disconnect events.
    using ConnectCallback = std::function<void(bool connected)>;
    void onConnect(ConnectCallback cb) { connectCallback_ = cb; }

    /// Get the underlying AsyncWebSocket pointer (for advanced use).
    AsyncWebSocket* getSocket() { return &ws_; }

private:
    AsyncWebSocket ws_;
    DataCallback dataCallback_;
    ConnectCallback connectCallback_;

    /// Internal event handler (called via lambda from begin()).
    void onWsEvent(AsyncWebSocket* server, AsyncWebSocketClient* client,
                   AwsEventType type, void* arg, uint8_t* data, size_t len);
};

#endif // WifiWebSocket_h
