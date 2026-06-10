#include "BinaryProtocolHandler.h"
#include "core/ClientsManager.h"
#include "SD.h"
#include <LittleFS.h>
#include <algorithm>
#include <cstring>
#include <cstdio>

static const char* TAG = "BinaryProtocolHandler";

// Static mutex definition
SemaphoreHandle_t BinaryProtocolHandler::sendChunkMutex_ = nullptr;

// ── Constructor / Destructor ──────────────────────────────────────────

BinaryProtocolHandler::BinaryProtocolHandler() {
    if (sendChunkMutex_ == nullptr) {
        sendChunkMutex_ = xSemaphoreCreateMutex();
    }
}

BinaryProtocolHandler::~BinaryProtocolHandler() {}

// ── Process incoming binary data ──────────────────────────────────────

void BinaryProtocolHandler::processBinaryData(uint8_t *data, size_t len) {
    ESP_LOGD(transportName(), "Processing binary data, length: %zu", len);

    // Small hex preview for short binary messages to aid debugging
    if (len > 0 && len <= 16) {
        char hexPreview[3 * 16 + 1] = {0};
        for (size_t i = 0; i < len; ++i) {
            snprintf(hexPreview + i * 3, 4, "%02X ", data[i]);
        }
        ESP_LOGI(transportName(), "payload preview (%zu bytes): %s", len, hexPreview);
    }

    // Cleanup old uploads periodically (every 100 packets)
    static uint32_t cleanupCounter = 0;
    if (++cleanupCounter % 100 == 0) {
        cleanupOldUploads();
    }

    if (len < PACKET_HEADER_SIZE + 1) {
        ESP_LOGW(transportName(), "Message too short: %zu bytes", len);
        notifyError("Message too short");
        return;
    }

    // Extract packet fields
    uint8_t magic        = data[0];
    uint8_t packetType   = data[1];
    uint8_t chunkId      = data[2];
    uint8_t chunkNum     = data[3];
    uint8_t totalChunks  = data[4];
    uint16_t dataLength  = data[5] | (data[6] << 8);  // Little-endian

    // Validate magic byte
    if (magic != MAGIC_BYTE) {
        ESP_LOGW(transportName(), "Invalid magic byte: 0x%02X", magic);
        notifyError("Invalid magic byte");
        return;
    }

    // Validate packet type
    if (packetType != 0x01) {
        ESP_LOGW(transportName(), "Invalid packet type: 0x%02X", packetType);
        notifyError("Invalid packet type");
        return;
    }

    // Validate data length
    if (len < PACKET_HEADER_SIZE + dataLength + 1) {
        ESP_LOGW(transportName(), "Packet length mismatch: expected %d, got %zu",
                 PACKET_HEADER_SIZE + dataLength + 1, len);
        notifyError("Packet length mismatch");
        return;
    }

    // Extract payload and checksum
    uint8_t *payload = &data[PACKET_HEADER_SIZE];
    uint8_t receivedChecksum = data[PACKET_HEADER_SIZE + dataLength];

    // Calculate checksum (XOR of all bytes except checksum)
    uint8_t calculatedChecksum = 0;
    for (size_t i = 0; i < PACKET_HEADER_SIZE + dataLength; i++) {
        calculatedChecksum ^= data[i];
    }

    if (receivedChecksum != calculatedChecksum) {
        ESP_LOGW(transportName(), "Invalid checksum: received 0x%02X, calculated 0x%02X",
                 receivedChecksum, calculatedChecksum);
        notifyError("Invalid checksum");
        return;
    }

    // Handle chunked vs single packet
    if (totalChunks > 1) {
        ESP_LOGD(transportName(), "Processing chunked packet: chunkId=%d, chunkNum=%d/%d",
                 chunkId, chunkNum, totalChunks);
        handleChunkedCommand(chunkId, chunkNum, totalChunks, payload, dataLength);
    } else {
        ESP_LOGD(transportName(), "Processing single packet: chunkId=%d", chunkId);
        handleSingleCommand(payload, dataLength);
    }
}

// ── Single command handler ────────────────────────────────────────────

void BinaryProtocolHandler::handleSingleCommand(uint8_t *payload, size_t payloadLength) {
    if (payloadLength < 1) {
        notifyError("Empty payload");
        return;
    }

    uint8_t messageType = payload[0];

    // Check if this is an upload command (0x0D)
    if (messageType == 0x0D) {
        handleUploadChunk(0, 1, 1, payload, payloadLength);
        return;
    }

    uint8_t *commandPayload = &payload[1];
    size_t commandPayloadLength = payloadLength - 1;

    ESP_LOGD(transportName(), "Handling single command: type=0x%02X, payloadLen=%zu",
             messageType, commandPayloadLength);

    if (commandHandler_ && commandHandler_->executeCommand(messageType, commandPayload, commandPayloadLength)) {
        ESP_LOGD(transportName(), "Command executed successfully: 0x%02X", messageType);
    } else {
        ESP_LOGW(transportName(), "Command execution failed: 0x%02X", messageType);
        notifyError("Command not supported or execution failed");
    }
}

// ── Chunked command handler ───────────────────────────────────────────

void BinaryProtocolHandler::handleChunkedCommand(
    uint8_t chunkId, uint8_t chunkNum, uint8_t totalChunks,
    uint8_t *payload, size_t payloadLength)
{
    ESP_LOGD(transportName(), "Handling chunked command: chunkId=%d, chunkNum=%d/%d, payloadLength=%zu",
             chunkId, chunkNum, totalChunks, payloadLength);

    // Check if this is an upload command
    bool isUploadCommand = false;
    auto uploadIt = fileUploads.find(chunkId);
    if (uploadIt != fileUploads.end() && uploadIt->second.isActive) {
        isUploadCommand = true;
    } else if (payloadLength > 0 && payload[0] == 0x0D) {
        isUploadCommand = true;
    }

    if (isUploadCommand) {
        if (handleUploadChunk(chunkId, chunkNum, totalChunks, payload, payloadLength)) {
            return;
        }
    }

    // For other chunked commands
    if (chunkNum == 1) {
        if (payloadLength < 1) {
            notifyError("Empty chunked command");
            return;
        }
        handleSingleCommand(payload, payloadLength);
    } else {
        ESP_LOGD(transportName(), "Received chunk %d/%d for chunkId %d",
                 chunkNum, totalChunks, chunkId);
    }
}

// ── Send helpers ──────────────────────────────────────────────────────

void BinaryProtocolHandler::sendBinaryResponse(const String& data) {
    if (!isTransportConnected()) return;

    const char* dataPtr = data.c_str();
    uint16_t dataLen = data.length();

    // Check if this is a binary message (first byte >= 0x80)
    bool isBinaryMessage = (dataLen > 0 &&
                            static_cast<uint8_t>(static_cast<unsigned char>(dataPtr[0])) >= 0x80);

    if (isBinaryMessage) {
        if (dataLen <= MAX_CHUNK_SIZE) {
            sendSingleChunk(0, 1, 1, dataPtr, dataLen);
        } else {
            sendChunkedResponse(data);
        }
    } else {
        if (dataLen <= MAX_CHUNK_SIZE) {
            sendSingleChunk(0, 1, 1, dataPtr, dataLen);
        } else {
            sendChunkedResponse(data);
        }
    }
}

void BinaryProtocolHandler::sendChunkedResponse(const String& data) {
    uint8_t chunkId = random(1, 255);
    uint16_t dataLen = data.length();

    // Calculate totalChunks
    uint8_t totalChunks = (dataLen + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE;
    if (totalChunks < 1) totalChunks = 1;

    const char* dataPtr = data.c_str();

    // Log the start of chunked send
    ESP_LOGD(transportName(), "Sending chunked response: total=%d chunks, dataLen=%d",
             totalChunks, dataLen);

    for (uint8_t i = 0; i < totalChunks; i++) {
        uint8_t chunkNum = i + 1;
        uint16_t startPos = i * MAX_CHUNK_SIZE;
        uint16_t endPos = startPos + MAX_CHUNK_SIZE;
        if (endPos > dataLen) endPos = dataLen;
        uint16_t chunkLen = endPos - startPos;

        sendSingleChunk(chunkId, chunkNum, totalChunks, dataPtr + startPos, chunkLen);
    }
}

void BinaryProtocolHandler::streamFileData(const uint8_t* header, size_t headerSize,
                                            File& file, size_t fileSize)
{
    // Calculate total message size
    size_t totalMessageSize = headerSize + fileSize;
    uint8_t chunkId = random(1, 255);
    uint8_t totalChunks = (totalMessageSize + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE;
    if (totalChunks < 1) totalChunks = 1;

    ESP_LOGI(transportName(), "Streaming file: totalMessageSize=%zu, chunks=%d",
             totalMessageSize, totalChunks);

    size_t totalSent = 0;
    uint8_t chunkNum = 1;

    // Send header as first chunk if it fits, or as separate
    size_t firstChunkDataSize = std::min(headerSize, static_cast<size_t>(MAX_CHUNK_SIZE));
    // For the first chunk, we combine header with file data
    // Use a temporary buffer to assemble the combined header+data
    uint8_t* combinedBuffer = (uint8_t*)malloc(MAX_CHUNK_SIZE);
    if (!combinedBuffer) {
        ESP_LOGE(transportName(), "Failed to allocate combined buffer for file stream");
        return;
    }

    // Copy header into combined buffer
    memcpy(combinedBuffer, header, headerSize);

    while (totalSent < fileSize) {
        size_t bytesToRead = std::min(static_cast<size_t>(MAX_CHUNK_SIZE) - (chunkNum == 1 ? headerSize : 0),
                                       fileSize - totalSent);
        size_t offset = (chunkNum == 1) ? headerSize : 0;

        size_t bytesRead = file.read(combinedBuffer + offset, bytesToRead);

        if (bytesRead > 0) {
            uint16_t chunkDataSize = (chunkNum == 1) ? headerSize + bytesRead : bytesRead;
            sendSingleChunk(chunkId, chunkNum, totalChunks,
                            reinterpret_cast<const char*>(combinedBuffer),
                            chunkDataSize);
            totalSent += bytesRead;
            chunkNum++;
        } else {
            ESP_LOGW(transportName(), "File read returned 0 bytes at offset %zu", totalSent);
            break;
        }
    }

    free(combinedBuffer);
    ESP_LOGI(transportName(), "File streaming complete: sent %zu bytes in %d chunks",
             totalSent, chunkNum - 1);
}

void BinaryProtocolHandler::sendSingleChunk(uint8_t chunkId, uint8_t chunkNum,
                                             uint8_t totalChunks,
                                             const char* chunkData, uint16_t dataLen)
{
    if (!isTransportConnected()) return;

    // Limit data length to MAX_CHUNK_SIZE
    if (dataLen > MAX_CHUNK_SIZE) {
        dataLen = MAX_CHUNK_SIZE;
    }

    uint16_t packetSize = PACKET_HEADER_SIZE + dataLen + 1; // +1 for checksum

    // Use static buffer
    static const size_t MAX_PACKET_SIZE = PACKET_HEADER_SIZE + 500 + 1;
    static uint8_t packetBuffer[MAX_PACKET_SIZE];

    if (xSemaphoreTake(sendChunkMutex_, pdMS_TO_TICKS(100)) != pdTRUE) {
        ESP_LOGE(transportName(), "Failed to acquire sendChunkMutex, dropping chunk %d/%d",
                 chunkNum, totalChunks);
        return;
    }

    if (packetSize > MAX_PACKET_SIZE) {
        ESP_LOGE(transportName(), "Packet size %d exceeds maximum %zu", packetSize, MAX_PACKET_SIZE);
        xSemaphoreGive(sendChunkMutex_);
        return;
    }

    uint8_t* packet = packetBuffer;

    if (chunkNum == 1) {
        ESP_LOGI(transportName(), "Sending FIRST chunk: chunkId=%d, chunkNum=%d/%d, dataLen=%d, packetSize=%d",
                 chunkId, chunkNum, totalChunks, dataLen, packetSize);
    }

    packet[0] = MAGIC_BYTE;          // Magic byte
    packet[1] = 0x01;                // Type: data
    packet[2] = chunkId;             // Chunk ID
    packet[3] = chunkNum;            // Chunk number
    packet[4] = totalChunks;         // Total chunks
    packet[5] = dataLen & 0xFF;      // Data length (low byte)
    packet[6] = (dataLen >> 8) & 0xFF; // Data length (high byte)

    // Copy data
    memcpy(packet + 7, chunkData, dataLen);

    // Calculate checksum
    packet[7 + dataLen] = calculateChecksum(packet, packetSize - 1);

    // Send the frame via the transport-specific method
    sendFrame(packet, packetSize);

    xSemaphoreGive(sendChunkMutex_);

    // Small delay to let the transport process
    vTaskDelay(pdMS_TO_TICKS(10));
}

uint8_t BinaryProtocolHandler::calculateChecksum(const uint8_t *data, size_t len) {
    uint8_t checksum = 0;
    for (size_t i = 0; i < len; i++) {
        checksum ^= data[i];
    }
    return checksum;
}

void BinaryProtocolHandler::notifyError(const char *errorMsg) {
    ESP_LOGW(transportName(), "Error: %s", errorMsg);
    // Enqueue an error notification via ClientsManager
    ClientsManager::getInstance().enqueueMessage(
        NotificationType::Unknown,
        std::string("ERROR: ") + errorMsg);
}

// ── Upload chunk handling ─────────────────────────────────────────────

bool BinaryProtocolHandler::moduleExists(uint8_t module) {
    return module < 4; // Default: support up to 4 modules
}

void BinaryProtocolHandler::cleanupOldUploads() {
    uint32_t now = millis();
    for (auto it = fileUploads.begin(); it != fileUploads.end(); ) {
        if (it->second.isActive && (now - it->second.timestamp) > 30000) {
            if (it->second.file) {
                it->second.file.close();
            }
            it->second.isActive = false;
            ESP_LOGW(transportName(), "Cleaned up stale upload: chunkId=%d", it->first);
            it = fileUploads.erase(it);
        } else {
            ++it;
        }
    }
}

bool BinaryProtocolHandler::handleUploadChunk(
    uint8_t chunkId, uint8_t chunkNum, uint8_t totalChunks,
    uint8_t *payload, size_t payloadLength)
{
    // First byte is the message type (should be 0x0D)
    if (payloadLength < 1) {
        notifyError("Empty upload chunk");
        return false;
    }

    uint8_t messageType = payload[0];

    if (messageType == 0x0D && chunkNum == 1) {
        // Start of file upload: parse path + optional initial data
        // Format: [msg_type:1][path_len:1][path_type:1][path:variable][data:variable]
        if (payloadLength < 4) {
            notifyError("Upload header too short");
            return false;
        }

        uint8_t pathLength = payload[1];
        uint8_t pathType   = payload[2];

        // Path starts at offset 3
        const char* path = reinterpret_cast<const char*>(&payload[3]);

        // Ensure path is properly terminated for string operations
        if (pathLength > payloadLength - 3) {
            notifyError("Upload path length exceeds payload");
            return false;
        }

        // Choose filesystem based on path type
        fs::FS* fsPtr = (pathType == 1) ? &SD : static_cast<fs::FS*>(&LittleFS);
        fs::FS& fs = *fsPtr;

        // Create directory structure if needed
        String pathStr = String(path, pathLength);
        int lastSlash = pathStr.lastIndexOf('/');
        if (lastSlash > 0) {
            String dirPath = pathStr.substring(0, lastSlash);
            fs.mkdir(dirPath.c_str());
        }

        // Apply path sanitization (ensure /DATA/ prefix, etc.)
        // Check if path starts correctly - if not, prepend default
        String fullPath;
        if (pathStr.startsWith("/")) {
            fullPath = pathStr;
        } else {
            fullPath = "/" + pathStr;
        }

        // Delete existing file if present
        if (fs.exists(fullPath.c_str())) {
            fs.remove(fullPath.c_str());
        }

        File file = fs.open(fullPath.c_str(), FILE_WRITE);
        if (!file) {
            ESP_LOGE(transportName(), "Failed to create file: %s", fullPath.c_str());
            notifyError("Failed to create upload file");
            return false;
        }

        // Store upload state
        FileUploadState uploadState;
        uploadState.file = file;
        uploadState.totalChunks = totalChunks;
        uploadState.receivedChunks = 1;
        uploadState.timestamp = millis();
        uploadState.isActive = true;
        strncpy(uploadState.filePath, fullPath.c_str(), sizeof(uploadState.filePath) - 1);
        uploadState.filePath[sizeof(uploadState.filePath) - 1] = '\0';

        fileUploads[chunkId] = uploadState;

        // Write initial data (everything after the path)
        size_t headerSize = 3 + pathLength; // msg_type(1) + path_len(1) + path_type(1) + path
        size_t dataToWrite = payloadLength - headerSize;
        if (dataToWrite > 0) {
            size_t bytesWritten = file.write(&payload[headerSize], dataToWrite);
            ESP_LOGD(transportName(), "Wrote %zu initial bytes to %s", bytesWritten, fullPath.c_str());
        }

        // Send ACK
        uint8_t ack[] = { 0x02, chunkId, chunkNum, 0x01 }; // type=ACK, id, num, success
        sendSingleChunk(chunkId, chunkNum, totalChunks,
                        reinterpret_cast<const char*>(ack), sizeof(ack));
        return true;
    }

    // Continue existing upload
    auto it = fileUploads.find(chunkId);
    if (it == fileUploads.end() || !it->second.isActive) {
        ESP_LOGW(transportName(), "No active upload for chunkId %d", chunkId);
        return false;
    }

    FileUploadState& uploadState = it->second;
    if (!uploadState.file) {
        ESP_LOGW(transportName(), "Upload file handle is invalid for chunkId %d", chunkId);
        fileUploads.erase(it);
        return false;
    }

    // Write payload data (skip the first byte which is the message type)
    size_t dataToWrite = payloadLength - 1;
    if (dataToWrite > 0) {
        size_t bytesWritten = uploadState.file.write(&payload[1], dataToWrite);
        if (bytesWritten != dataToWrite) {
            ESP_LOGE(transportName(), "Upload write failed: wrote %zu/%zu bytes",
                     bytesWritten, dataToWrite);
        }
    }

    uploadState.receivedChunks++;
    uploadState.timestamp = millis();

    // Determine total file size from payload if available (bytes after path)
    // For subsequent chunks without path, just accumulate data

    // Check if upload is complete
    if (chunkNum >= totalChunks || uploadState.receivedChunks >= totalChunks) {
        size_t fileSize = uploadState.file.size();
        uploadState.file.close();
        uploadState.isActive = false;

        ESP_LOGI(transportName(), "Upload complete: chunkId=%d, file=%s, size=%zu",
                 chunkId, uploadState.filePath, fileSize);

        // Send completion response
        char response[64];
        int respLen = snprintf(response, sizeof(response),
                               "\x0D%c%s%zu", 0x01, "OK", fileSize);
        sendSingleChunk(chunkId, chunkNum, totalChunks, response, respLen);

        // Remove from active uploads
        fileUploads.erase(it);
    } else {
        // Send ACK for intermediate chunk
        uint8_t ack[] = { 0x02, chunkId, chunkNum, 0x01 };
        sendSingleChunk(chunkId, chunkNum, totalChunks,
                        reinterpret_cast<const char*>(ack), sizeof(ack));
    }

    return true;
}
