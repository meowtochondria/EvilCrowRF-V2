#ifndef BinaryProtocolHandler_h
#define BinaryProtocolHandler_h

#include <Arduino.h>
#include <FS.h>
#include <stdint.h>
#include <map>
#include <atomic>

#include "core/CommandHandler.h"

/**
 * BinaryProtocolHandler — Shared binary protocol logic extracted from BleAdapter.
 *
 * Handles the chunked binary protocol (magic 0xAA, type, chunkId, chunkNum,
 * totalChunks, dataLen, data, checksum) used by both BLE and WiFi transports.
 *
 * Usage: subclass and implement the pure-virtual sendChunk() method to
 * deliver a formatted binary frame over the concrete transport.
 */
class BinaryProtocolHandler {
public:
    BinaryProtocolHandler();
    virtual ~BinaryProtocolHandler();

    // ── Public interface ────────────────────────────────────────────

    /// Process an incoming binary data buffer (full frame with header+payload+checksum).
    void processBinaryData(uint8_t *data, size_t len);

    /// Set the CommandHandler for command dispatch.
    virtual void setCommandHandler(CommandHandler* handler) { commandHandler_ = handler; }

    /// Set the "is from serial" flag (atomic, cross-core safe).
    void setSerialCommand(bool flag) { isSerialCommand.store(flag); }

    // ── Protocol send helpers (public for FileCommands access) ───────

    /// Send a response (string or binary) as single or chunked frames.
    void sendBinaryResponse(const String& data);

    /// Send a chunked response (multi-frame) for large payloads.
    void sendChunkedResponse(const String& data);

    /// Build and send a single chunk frame.
    void sendSingleChunk(uint8_t chunkId, uint8_t chunkNum, uint8_t totalChunks,
                         const char* chunkData, uint16_t dataLen);

    /// Stream file data over the transport in chunked frames.
    void streamFileData(const uint8_t* header, size_t headerSize,
                        File& file, size_t fileSize);

    /// Calculate XOR checksum over a buffer.
    static uint8_t calculateChecksum(const uint8_t *data, size_t len);

    /// Notify error to the client (enqueues a text notification).
    void notifyError(const char *errorMsg);

    // ── Constants (shared with transport-specific subclasses) ────────
    static const uint8_t  MAGIC_BYTE          = 0xAA;
    static const uint16_t MAX_CHUNK_SIZE      = 500;
    static const uint8_t  PACKET_HEADER_SIZE   = 7;

    // ── File upload support ──────────────────────────────────────────
    struct FileUploadState {
        File file;
        uint8_t totalChunks;
        uint8_t receivedChunks;
        uint32_t timestamp;
        bool isActive;
        char filePath[256];
    };

protected:
    // ── Subclass must implement these ────────────────────────────────

    /// Send a single fully-formed binary frame (header+payload+checksum) to the client.
    /// The frame is already fully assembled in `data[0..len-1]`.
    virtual void sendFrame(const uint8_t* data, size_t len) = 0;

    /// Return true when at least one client is connected.
    virtual bool isTransportConnected() const = 0;

    /// Return a human-readable adapter name for logging.
    virtual const char* transportName() const = 0;

    // ── State ────────────────────────────────────────────────────────
    CommandHandler* commandHandler_ = nullptr;
    std::atomic<bool> isSerialCommand{false};

    // File upload states
    std::map<uint8_t, FileUploadState> fileUploads;

    // Mutex for static send buffer protection (cross-core safety)
    static SemaphoreHandle_t sendChunkMutex_;

private:
    // ── Internal protocol handlers ───────────────────────────────────
    void handleSingleCommand(uint8_t *payload, size_t payloadLength);
    void handleChunkedCommand(uint8_t chunkId, uint8_t chunkNum,
                              uint8_t totalChunks, uint8_t *payload,
                              size_t payloadLength);
    void cleanupOldUploads();
    bool handleUploadChunk(uint8_t chunkId, uint8_t chunkNum,
                           uint8_t totalChunks, uint8_t *payload,
                           size_t payloadLength);

    // Upload management
    bool moduleExists(uint8_t module);
};

#endif // BinaryProtocolHandler_h
