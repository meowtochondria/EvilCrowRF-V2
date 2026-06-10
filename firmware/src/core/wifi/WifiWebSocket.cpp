#include "WifiWebSocket.h"

static const char* TAG = "WifiWebSocket";

WifiWebSocket::WifiWebSocket(AsyncWebServer& server, const char* url)
    : ws_(url)
{
    // server reference is used to addHandler in begin()
    (void)server;
}

void WifiWebSocket::begin() {
    // Use a lambda to capture 'this' for event handling
    ws_.onEvent([this](AsyncWebSocket* server, AsyncWebSocketClient* client,
                       AwsEventType type, void* arg, uint8_t* data, size_t len) {
        this->onWsEvent(server, client, type, arg, data, len);
    });

    ESP_LOGI(TAG, "WebSocket handler registered at /api/ws");
}

size_t WifiWebSocket::sendBinary(const uint8_t* data, size_t len) {
    if (ws_.count() == 0) {
        return 0; // No clients connected
    }

    // Send binary frame to all connected clients
    ws_.binaryAll(data, len);
    return len;
}

bool WifiWebSocket::hasClient() const {
    return ws_.count() > 0;
}

void WifiWebSocket::onWsEvent(AsyncWebSocket* /*server*/,
                               AsyncWebSocketClient* client,
                               AwsEventType type,
                               void* arg,
                               uint8_t* data,
                               size_t len)
{
    switch (type) {
        case WS_EVT_CONNECT:
            ESP_LOGI(TAG, "WebSocket client connected: id=%u, IP=%s",
                     client->id(), client->remoteIP().toString().c_str());
            if (connectCallback_) {
                connectCallback_(true);
            }
            break;

        case WS_EVT_DISCONNECT:
            ESP_LOGI(TAG, "WebSocket client disconnected: id=%u", client->id());
            if (connectCallback_) {
                connectCallback_(false);
            }
            break;

        case WS_EVT_DATA:
            {
                AwsFrameInfo* info = (AwsFrameInfo*)arg;

                if (info->opcode == WS_BINARY || info->opcode == WS_TEXT) {
                    if (dataCallback_) {
                        dataCallback_(data, len);
                    }
                }
            }
            break;

        case WS_EVT_PING:
            ESP_LOGV(TAG, "WebSocket ping from client id=%u", client->id());
            break;

        case WS_EVT_PONG:
            ESP_LOGV(TAG, "WebSocket pong from client id=%u", client->id());
            break;

        case WS_EVT_ERROR:
            ESP_LOGW(TAG, "WebSocket error from client id=%u", client->id());
            break;
    }
}
