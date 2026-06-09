# WiFi Transport Implementation Plan — EvilCrowRF V2

> **Status:** Design Document  
> **Date:** 2026-06-07  
> **Objective:** Replace BLE with WiFi as the transport layer between the ESP32 firmware and Flutter mobile app, using TCP + WebSocket for binary protocol transport.

---

## 1. Executive Summary

The current EvilCrowRF V2 uses **BLE (Bluetooth Low Energy)** as its sole wireless transport between the ESP32 firmware and the Flutter mobile app. The protocol is a custom binary packet format layered over BLE GATT characteristics (Nordic UART Service). This document describes how to replace BLE with **WiFi**, leveraging the ESP32's shared radio hardware.

**Core constraint:** WiFi and BLE cannot operate simultaneously on the ESP32 (single 2.4 GHz RF PHY). A build-time compile flag selects one mode. Separate firmware binaries are shipped:
- `evilcrow-v2-fw-vX.Y.Z-bt.bin` (BLE)
- `evilcrow-v2-fw-vX.Y.Z-wifi.bin` (WiFi)

---

## 2. Existing Architecture Analysis

### 2.1 Firmware Side (C++, PlatformIO, ESP32-Arduino + NimBLE)

**Layer stack:**

```
┌──────────────────────────────────────────────┐
│  CommandHandler (0x01–0xFF dispatch table)   │
│  ├─ StateCommands    (0x01, 0x02, 0x03, …)   │
│  ├─ FileCommands     (0x05, 0x09, 0x0A–0x0E) │
│  ├─ TransmitterCmds  (0x06, 0x07, 0x11, 0x12)│
│  ├─ RecorderCommands (0x08, 0x10)            │
│  ├─ BruterCommands   (0x04, …)               │
│  ├─ NrfCommands      (0x20–0x2F)             │
│  ├─ OtaCommands      (0x30–0x35)             │
│  ├─ ButtonCommands   (0x40)                  │
│  ├─ ProtoPirateCmds  (0x60)                  │
│  └─ SdrCommands      (0x50–0x59)             │
├──────────────────────────────────────────────┤
│  ClientsManager (fan-out to all adapters)    │
│  ├─ BleAdapter (NimBLE server)               │
│  ├─ ControllerAdapter (abstract, task queue) │
│  └─ Serial (direct text commands in main.cpp)│
├──────────────────────────────────────────────┤
│  Notification → BinaryMessage (0x80–0xFF)    │
│  Chunked protocol: magic(0xAA)|type|chunkId| │
│                    chunkNum|total|len(2)|data│
│  BLE: 7-byte header + up to 500 bytes + CRC  │
└──────────────────────────────────────────────┘
```

**Key files:**
- `firmware/src/core/ble/BleAdapter.{h,cpp}` — BLE GATT server, chunked send/receive, file upload streaming
- `firmware/src/core/CommandHandler.h` — Command dispatch map (uint8_t → callback)
- `firmware/src/core/ClientsManager.h` — Fan-out notifications to all adapters
- `firmware/src/core/ControllerAdapter.h` — Abstract base + task queue
- `firmware/include/BinaryMessages.h` — All response message structs (0x80–0xFF)
- `firmware/include/*Commands.h` — Command handler implementations (~15 files)
- `firmware/src/main.cpp` — `setup()` registers all commands, initializes BLE
- `firmware/platformio.ini` — Uses NimBLE, no WiFi dependencies

### 2.2 Mobile App Side (Flutter/Dart)

**Layer stack:**

```
┌────────────────────────────────────────────────┐
│  Screens (home_screen, record_screen, …)       │
├────────────────────────────────────────────────┤
│  BleProvider (ChangeNotifier, BLE lifecycle)   │
│  ├─ scan / connect / disconnect                │
│  ├─ sendCommand (BLE write characteristic)     │
│  ├─ _onJsonReceived → _handleFirmwareResponse  │
│  └─ State: isConnected, deviceStatus, etc.     │
├────────────────────────────────────────────────┤
│  FirmwareBinaryProtocol (message encode/decode)│
│  ├─ createXxxCommand() → Uint8List             │
│  ├─ parseResponse(Uint8List) → Map             |
│  └─ Chunked packet handling                    │
├────────────────────────────────────────────────┤
│  Transport Layer (transport_layer.dart)        │
│  ├─ ITransportLayer (abstract)                 │
│  ├─ BLEBinaryTransport (existing skeleton)     │
│  └─ TransportFactory (create by type)          │
├────────────────────────────────────────────────┤
│  flutter_blue_plus (BLE plugin)                │
│  http (already in pubspec.yaml)                │
└────────────────────────────────────────────────┘
```

**Key files:**
- `lib/providers/ble_provider.dart` — Monolithic provider (~5085 lines) managing BLE lifecycle, command dispatch, and all state
- `lib/providers/firmware_protocol.dart` — Binary protocol encoder/decoder
- `lib/transport/transport_layer.dart` — Abstract transport interface with BLE implementation skeleton
- `lib/transport/transport_adapter.dart` — Adapter wrapping transport layer
- `lib/main.dart` — App entry, wires `BleProvider` via `Provider`
- `pubspec.yaml` — Dependencies already include `http: ^1.2.1`

### 2.3 Binary Protocol (Shared)

| Field | Size | Description |
|-------|------|-------------|
| Magic | 1 | `0xAA` |
| Type | 1 | `0x01`=data, `0x02`=ACK, `0x03`=NAK |
| ChunkID | 1 | Random session identifier |
| ChunkNum | 1 | 1-based chunk index |
| TotalChunks | 1 | Total chunks in message |
| DataLen | 2 | Payload length (LE) |
| Data | N | Payload (command or response bytes) |
| Checksum | 1 | XOR of all preceding bytes |

- **Command messages** (app → device) use IDs `0x01`–`0x60`.
- **Response messages** (device → app) use IDs `0x80`–`0xFF`.
- The protocol is identical between BLE and WiFi modes — only the transport medium changes.

### 2.4 Memory & Partition Layout

```
Partition        Size      Use
nvs             20 KB     NVS (WiFi credentials will live here)
otadata          8 KB     OTA metadata
app0           1.8 MB     Factory / OTA_0 slot
app1           1.8 MB     OTA_1 slot
coredump        64 KB     Crash dumps
littlefs       256 KB     Config, recordings, signal files
```

**RAM budget comparison:**

| Component | BLE Build | WiFi Build |
|-----------|-----------|------------|
| NimBLE | ~40 KB | 0 KB |
| WiFi + lwIP | 0 KB | ~35 KB |
| AsyncTCP + WebServer | 0 KB | ~8 KB |
| WebSocket frame buffers | 0 KB | ~4 KB |
| **Net change** | baseline | **~+7 KB free** (NimBLE savings mostly offset WiFi cost) |

---

## 3. Proposed WiFi Architecture

### 3.1 High-Level Design

```
┌───────────────────────────────────────────────────────┐
│  Firmware (ESP32)                                     │
│                                                       │
│  ┌───────────────────────────────┐                    │
│  │  CommandHandler (unchanged)   │                    │
│  │  ClientsManager (unchanged)   │                    │
│  │  ControllerAdapter (unchanged)│                    │
│  └──────────┬────────────────────┘                    │
│             │                                         │
│  ┌──────────▼────────────────────┐                    │
│  │  WifiAdapter (NEW)            │                    │
│  │  ┌─────────────────────────┐  │                    │
│  │  │  WiFiManager            │  │  ← SoftAP / STA    │
│  │  │  AsyncWebServer (port 80)│ │  ← REST API        │
│  │  │  WebSocket (port 81)    │  │  ← Binary protocol │
│  │  │  mDNS responder         │  │  ← evilcrow-XXXX   │
│  │  └─────────────────────────┘  │                    │
│  └───────────────────────────────┘                    │
│                                                       │
│  ┌───────────────────────────────┐                    │
│  │  WifiConfigManager (NEW)      │                    │
│  │  - SoftAP portal on first boot│                    │
│  │  - Captive portal via DNS     │                    │
│  │  - Persists SSID/pass in NVS  │                    │
│  └───────────────────────────────┘                    │
└───────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│  Mobile App (Flutter)                                │
│                                                      │
│  ┌───────────────────────────────┐                   │
│  │  WifiProvider (NEW)           │                   │
│  │  - mDNS discovery             │                   │
│  │  - HTTP / WebSocket client    │                   │
│  │  - Same FirmwareBinaryProtocol│                   │
│  │  - Replaces BleProvider role  │                   │
│  └───────────────────────────────┘                   │
└──────────────────────────────────────────────────────┘
```

### 3.2 Onboarding — No Prior WiFi Required

**Primary approach: SmartConfig / ESP-TOUCH**

ESP32 supports ESP-TOUCH (SmartConfig), where the app broadcasts SSID/password over 2.4 GHz 802.11 packets before the device is on any network. The device sniffs these in promiscuous mode.

**Flow:**
1. Device boots in **SoftAP + SmartConfig listen** mode.
2. App (knows current WiFi SSID via `network_info_plus`) sends credentials via SmartConfig.
3. Device connects to the home network in STA mode.
4. On subsequent boots, device connects directly via saved credentials (stored in NVS).
5. If connection fails after N retries, device reverts to SoftAP + SmartConfig mode.

**Fallback: SoftAP + Captive Portal**
- Device creates `EvilCrowRF-Config` SSID (open or WPA2 if hardware supports it).
- User connects phone to this network.
- DNS captures all HTTP requests → redirect to config page at `192.168.4.1`.
- User enters WiFi credentials on a web form.
- Device reboots in STA mode.

**Supported provisioning flow (in order of attempt):**
1. **SmartConfig / ESP-TOUCH** — App broadcasts credentials over 2.4 GHz 802.11. Requires the phone to already be on a 2.4 GHz network. Most reliable on open/unencrypted networks.
2. **SoftAP + Captive Portal** — Device creates its own AP. User enters credentials in the captive portal. Works on any router, including 5 GHz and enterprise networks.
3. **Manual IP entry** — If mDNS is blocked or the above methods fail, the app settings screen provides a text field for direct IP address entry.

If the device has a display, show a QR code containing `WIFI:T:WPA;S:<ssid>;P:<password>;;` that the user can scan with their phone's camera to join the SoftAP network without typing credentials.

### 3.3 Data Transport — WebSocket

**Primary transport: WebSocket (binary frames)**

The existing binary protocol maps to WebSocket opcode `0x02` (binary frame). All existing `FirmwareBinaryProtocol.createXxxCommand()` methods work unchanged. All existing `BinaryMessages.h` response structs work unchanged.

**Why WebSocket over pure REST:**
- The protocol is bidirectional and event-driven. REST would require polling for device-initiated messages (signal detected, bruter progress, battery updates).
- WebSocket maps 1:1 to BLE GATT notify/write semantics.
- OTA (including progress notifications) runs entirely over WebSocket — no separate HTTP endpoint needed.

**WebSocket advantage over BLE:** WebSocket MTU is typically 65,535 bytes (vs BLE's 509 bytes). `MAX_CHUNK_SIZE` can be raised to ~16,000 bytes for much better throughput on file operations.

**Message formats:**

*Single-chunk messages* (all commands, most responses — fits in one WebSocket frame):

```
[1 byte: magic 0xAA] [1 byte: msg_type] [2 bytes: data_len (LE)] [N bytes: data] [1 byte: xor_checksum]
```

*Multi-chunk messages* (file uploads, firmware downloads — only when payload exceeds one frame):

```
[1 byte: magic 0xAA] [1 byte: type 0x01] [1 byte: chunk_id] [1 byte: chunk_num] [1 byte: total_chunks] [2 bytes: data_len (LE)] [N bytes: data] [1 byte: xor_checksum]
```

The chunked format is **only** for multi-chunk transfers. Most command/response paths use the single-chunk format, reducing per-message overhead from 7+ bytes to 5 bytes.

### 3.4 REST API Endpoints

REST endpoints handle out-of-band operations that don't need the binary protocol's bidirectional channel:

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/info` | Device identity, version, heap, uptime |
| `GET` | `/api/status` | Current state (same as BinaryStatus struct) |
| `GET` | `/api/files/*` | Download files (SD/LittleFS) |
| `POST` | `/api/files/*` | Upload files (multipart) |
| `GET` | `/scan` | SoftAP captive portal landing page |

**OTA over WebSocket:** All OTA operations run over the binary protocol WebSocket channel using command IDs `0x30`–`0x35`. The device sends `OTA_PROGRESS` notification messages back via WebSocket as chunks are received. No separate HTTP OTA endpoints are needed.

### 3.5 Ports

| Port | Protocol | Service |
|------|----------|---------|
| 80 | TCP/HTTP + WebSocket | REST API + WebSocket upgrade at `/api/ws` |
| 5353 | UDP | mDNS (`_evilcrow._tcp`) |

A single WebSocket endpoint handles all binary protocol traffic. REST and binary traffic share port 80 with path-based routing.

### 3.6 mDNS Identifier (Configurable, Not Hardcoded)

The mDNS hostname must be based on the user-configurable device name from `ConfigManager::getDeviceName()`, not a hardcoded string:

```cpp
// In WifiAdapter::begin():
const char* deviceName = ConfigManager::getDeviceName();

String mdnsHostname = String(deviceName);
mdnsHostname.replace(" ", "-");
mdnsHostname.toLowerCase();

if (!MDNS.begin(mdnsHostname.c_str())) {
    ESP_LOGE("WifiAdapter", "mDNS responder failed to start");
} else {
    MDNS.addService("_evilcrow", "_tcp", 80);
    MDNS.addServiceTxt("_evilcrow", "_tcp", "name", deviceName);
    MDNS.addServiceTxt("_evilcrow", "_tcp", "fw_version", FIRMWARE_VERSION_STRING);
    MDNS.addServiceTxt("_evilcrow", "_tcp", "transport", "websocket");
    ESP_LOGI("WifiAdapter", "mDNS started as %s.local", mdnsHostname.c_str());
}
```

The app discovers devices by browsing for `_evilcrow._tcp.local` and reads the `name` TXT record. Since the device name is changeable via the existing `MSG_SET_DEVICE_NAME` (0x17) command, the mDNS hostname follows automatically after reboot.

---

## 4. Why TCP + WebSocket (Not QUIC)

**QUIC is not appropriate for this use case.** Here is the comparison:

| Consideration | TCP (AsyncTCP + WebSocket) | QUIC |
|---|---|---|
| **ESP32 support** | Mature. AsyncTCP (maintained fork) is well-tested. | No stable ESP32 Arduino implementation. ESP-IDF has experimental support only. Porting `lsquic` or `msquic` is a multi-week effort. |
| **RAM footprint** | ~15–30 KB (lwIP + AsyncTCP + WS) | ~40–60 KB+ (QUIC needs connection state, TLS 1.3 crypto contexts, stream buffers) |
| **Use case fit** | Local network, low latency, binary frames map to WebSocket perfectly. | Designed for internet-scale connection migration and multiplexed streams. Overkill for a LAN-connected RF tool. |
| **Head-of-line blocking** | Not an issue for a single command/response stream. | QUIC solves HOL blocking for HTTP/2 multiplexing, but this app has one stream. |
| **TLS overhead** | Optional (no TLS on LAN; add later if needed). | QUIC requires TLS 1.3 by spec, adding hundreds of KB of code and flash. |
| **Connection setup** | TCP: 1 RTT. WebSocket upgrade: +1 RTT. Total ~2 RTT. | QUIC: 0–1 RTT (with TLS). Marginal gain on LAN (~1 ms difference). |
| **Library maintenance** | ESP32Async/AsyncTCP is actively maintained. | No maintained Arduino-compatible QUIC library exists. |

**Verdict:** TCP + WebSocket is the correct choice. It is well-supported, low-overhead, and directly maps the existing BLE binary protocol to binary WebSocket frames. QUIC adds complexity, RAM pressure, and an experimental dependency for zero measurable gain on a local-only device.

---

## 5. Required Libraries & Dependencies

### 5.1 Firmware (C++, PlatformIO)

| Library | Purpose | Source |
|---------|---------|--------|
| **WiFi** | ESP32 STA + SoftAP | Built-in (`ESP32 WiFi`) |
| **AsyncTCP** | Async TCP engine | `https://github.com/ESP32Async/AsyncTCP.git` (maintained fork) |
| **ESPAsyncWebServer** | Async HTTP server + WebSocket | `https://github.com/ESP32Async/ESPAsyncWebServer.git` |
| **DNSServer** | Captive portal DNS hijack | Built-in (`DNSServer`) |
| **ESPmDNS** | mDNS responder | Built-in (`ESPmDNS`) |
| **SmartConfig** | ESP-TOUCH provisioning | Built-in (`WiFi.beginSmartConfig()`) |

### 5.2 Mobile App (Flutter/Dart)

| Package | Purpose | Already in pubspec? |
|---------|---------|---------------------|
| `http` | REST API calls | ✅ Yes (`^1.6.0`) |
| `web_socket_channel` | WebSocket client | ⬜ New (`^3.0.3`) |
| `network_info_plus` | Get phone's WiFi SSID for auto-config | ⬜ New (`^8.1.0`) |

**Add to `pubspec.yaml`:**
```yaml
dependencies:
  web_socket_channel: ^3.0.3
  network_info_plus: ^8.1.0
```

---

## 6. Build Configuration

### 6.1 `platformio.ini` — Two Environments

The `[env:esp32dev]` is renamed to `[env:evilcrow-bt]`. A new `[env:evilcrow-wifi]` is added using the maintained ESP32Async library forks.

```ini
[platform]
default_envs = evilcrow-bt

[common]
board = esp32dev
framework = arduino
board_build.partitions = partitions.csv

build_flags =
    -std=gnu++17
    -Os
    -ffunction-sections -fdata-sections -Wl,--gc-sections
    -DARDUINO_USB_MODE=0 -DARDUINO_USB_CDC_ON_BOOT=0
    -fexceptions -fno-threadsafe-statics
    -fmerge-all-constants -DDISABLE_ALL_LIBRARY_WARNINGS
    -DCORE_DEBUG_LEVEL=3 -I src

build_unflags = -std=gnu++11
monitor_speed = 115200
monitor_filters = esp32_exception_decoder, time


[env:evilcrow-bt]
platform = espressif32@^6.13.0
board = ${common.board}
framework = ${common.framework}
board_build.partitions = ${common.board_build.partitions}
board_build.flash_mode = qio
board_build.f_cpu = 240000000L

lib_deps =
    h2zero/NimBLE-Arduino@^2.5.0

build_flags =
    ${common.build_flags}
    -DEVILCROW_BT_MODE=1
    -DCONFIG_BT_ENABLED=1
    -DCONFIG_BT_NIMBLE_MAX_CONNECTIONS=1
    -DCONFIG_BT_NIMBLE_ROLE_CENTRAL_DISABLED
    -DCONFIG_BT_NIMBLE_ROLE_OBSERVER_DISABLED
    -DCONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE=8192

lib_ignore = HTTPUpdate


[env:evilcrow-wifi]
platform = espressif32@^6.13.0
board = ${common.board}
framework = ${common.framework}
board_build.partitions = ${common.board_build.partitions}
board_build.flash_mode = qio
board_build.f_cpu = 240000000L

lib_deps =
    https://github.com/ESP32Async/AsyncTCP.git#3.4.10
    https://github.com/ESP32Async/ESPAsyncWebServer.git#3.11.1

build_flags =
    ${common.build_flags}
    -DEVILCROW_WIFI_MODE=1
    -DCONFIG_BT_ENABLED=0 -DCONFIG_BT_NIMBLE_ENABLED=0
    -DCONFIG_LWIP_TCP_MSS=1460
    -DCONFIG_LWIP_TCP_WND=5840
    -DCONFIG_LWIP_TCP_SND_BUF=2920
    -DCONFIG_LWIP_TCP_RCV_BUF=2920
    -DCONFIG_LWIP_MAX_SOCKETS=4
    -DCONFIG_MDNS_MAX_SERVICES=1
    -DASYNC_TCP_QUEUE_SIZE=32
    -DWS_MAX_QUEUED_MESSAGES=32
    -DWS_LOG_LEVEL=3

lib_ignore = NimBLE-Arduino, HTTPUpdate
```

### 6.2 Firmware Makefile Targets

```
make build              # build evilcrow-bt (default)
make build-bt           # build evilcrow-bt
make build-wifi         # build evilcrow-wifi
make flash              # flash evilcrow-bt
make flash-bt           # flash evilcrow-bt
make flash-wifi         # flash evilcrow-wifi
make flash-monitor      # flash-bt + monitor
make flash-monitor-bt   # flash-bt + monitor
make flash-monitor-wifi # flash-wifi + monitor
```

### 6.3 Mobile App Makefile Targets

```
make apk            # build with TRANSPORT_MODE=bt (existing)
make apk-bt         # build with --dart-define=TRANSPORT_MODE=bt
make apk-wifi       # build with --dart-define=TRANSPORT_MODE=wifi
make install-bt     # build bt + install over USB
make install-wifi   # build wifi + install over USB
make deploy-wifi-bt   # build bt + deploy over WiFi ADB
make deploy-wifi-wifi # build wifi + deploy over WiFi ADB
```

---

## 7. Implementation Plan

### Phase 1: Firmware — WiFi Infrastructure & Configuration

**Files to create:**
- `firmware/src/core/wifi/WifiAdapter.h` / `.cpp` — Replaces `BleAdapter` as a `ControllerAdapter` subclass
- `firmware/src/core/wifi/WifiConfigManager.h` / `.cpp` — SmartConfig + SoftAP provisioning
- `firmware/src/core/wifi/WifiWebSocket.h` / `.cpp` — WebSocket handler wrapping binary protocol

**Modifications:**
- `firmware/src/main.cpp`: Add `#ifdef EVILCROW_WIFI_MODE` to init `WifiAdapter` instead of `BleAdapter`
- `firmware/src/core/ble/BinaryProtocolHandler.h/.cpp` — **NEW** shared class extracted from `BleAdapter` containing `processBinaryData()`, `handleSingleCommand()`, `sendSingleChunk()`, reused by both adapters
- The generalized abstractions (`ControllerAdapter`, `ClientsManager`, `CommandHandler`) live in `firmware/src/core/`, not under `ble/`. Both `BleAdapter` (BLE) and the planned `WifiAdapter` (WiFi) inherit from `ControllerAdapter` and register with `ClientsManager`.
- `Request.h` / `Request.cpp` (previously in `core/ble/`) were removed — their only used struct `RequestScan` was inlined into `StateCommands.h`, and `calculateCRC32`, `RequestRecord`, `TransmitFromFileRequest` were unused.

**WifiAdapter responsibilities:**
- `begin()`: Start config portal or connect to saved WiFi, start mDNS, start WebSocket server
- `notify(type, message)`: Send via WebSocket binary frame (same chunked protocol)
- `isConnected()`: WebSocket client connected
- `setCommandHandler(handler)`: Route incoming WebSocket binary frames to command handler
- `streamFileData(header, file, size)`: Stream file contents over WebSocket binary frames

### Phase 2: Firmware — Binary Protocol over WebSocket

The `WifiWebSocketHandler` processes incoming binary frames identically to `BleAdapter::processBinaryData()`, delegating to the shared `BinaryProtocolHandler`.

### Phase 3: Firmware — OTA over WebSocket

OTA uses the existing binary protocol channel (commands `0x30`–`0x35`) over WebSocket instead of BLE chunked writes. No separate HTTP OTA endpoints are used.

**OTA command sequence over WebSocket:**
- `0x30 OTA_BEGIN` — Initialize OTA session, validate there is enough space in `app1`
- `0x31 OTA_DATA` — Stream firmware chunks as binary WebSocket frames (single-chunk or multi-chunk format as appropriate for size)
- `0x32 OTA_END` — Finalize, verify MD5, mark boot partition
- `0x33 OTA_ABORT` — Cancel session, clean up
- `0x34 OTA_REBOOT` — Reboot into new firmware
- `0x35 OTA_PROGRESS` — Device-initiated notification sent back to app as chunks are received

Progress is reported back to the app via device-initiated `OTA_PROGRESS` messages, so the app receives real-time feedback without polling.

**Partition table (`partitions.csv`):**
```csv
# Name,   Type, SubType, Offset,  Size, Flags
nvs,      data, nvs,     0x9000,  0x5000,
spiffs,   data, spiffs,  0xe000,  0x20000,
otadata,  data, ota,     0x110000,0x2000,
app0,     app,  ota_0,   0x120000,0x1C0000,
app1,     app,  ota_1,   0x3E0000,0x1C0000,
coredump, data, coredump,0x5A0000,0x10000,
littlefs, data, littlefs,0x5B0000,0x50000,
```
- `app0`/`app1`: 1.8 MB each — accommodates firmware + WiFi stack with headroom for OTA
- Total flash: 6 MB (standard ESP32-WROOM module)

### Phase 3.5: Mobile App — Linux Build & Desktop Testing

This phase is enabled by the WiFi transport itself: the WebSocket + HTTP approach replaces
BLE, which was the single blocker for Linux desktop support. Once complete, developers can
build, run, and debug the full app on a Linux machine without a phone or BLE adapter.

**Prerequisite:** Phases 1–3 must be complete (or at least the firmware must be built in
`EVILCROW_WIFI_MODE` so there is a WiFi-capable device to test against).

---

#### 3.5.1 Scaffold the Linux Platform

```bash
cd mobile_app
flutter create --platforms linux .
```

This generates:

| File | Purpose |
|------|---------|
| `linux/flutter/generated_plugin_registrant.h` / `.cc` | Auto-managed plugin registration |
| `linux/my_application.h` / `.cc` | GTK application entry point, window creation |
| `linux/main.cc` | `main()` — instantiates `MyApplication` |
| `linux/CMakeLists.txt` | Build rules; may need edits for custom deps |

After scaffolding, verify it compiles:

```bash
cd mobile_app && flutter build linux --debug
```

---

#### 3.5.2 Why WiFi Unblocks Linux

| Dependency | BLE mode (existing) | WiFi mode (this plan) | Linux support |
|------------|---------------------|----------------------|---------------|
| `flutter_blue_plus` | **Required** | Not used | ❌ No Linux support |
| `web_socket_channel` | Not used | **Required** | ✅ Pure Dart — works everywhere |
| `http` | Not used | **Required** | ✅ Pure Dart — works everywhere |
| `network_info_plus` | Not used | **Required** | ✅ Yes (via NetworkManager/connman) |
| `permission_handler` | Bluetooth perms | Network perms | ✅ Yes (v9.0+, D-Bus) |
| `shared_preferences` | Used | Used | ✅ Yes |
| `path_provider` | Used | Used | ✅ Yes (XDG dirs) |
| `file_picker` | Used | Used | ✅ Yes (GTK file dialog) |
| `wakelock_plus` | Used | Used | ✅ Yes (GNOME inhibit) |
| `package_info_plus` | Used | Used | ✅ Yes (AppStream/CMake) |

**Key insight:** Every dependency that the WiFi-mode app needs already supports Linux.
The only Linux-hostile dependency (`flutter_blue_plus`) is eliminated by the WiFi transport.

---

#### 3.5.3 Linux-Specific Configuration

**Permissions (AppStream / D-Bus):**

The `linux/my_application.cc` runner must request network permission. Add the following to
the generated `.desktop` file or the AppStream metainfo:

```xml
<!-- linux/io.evilcrow.evilcrowrf.metainfo.xml -->
<component>
  <id>io.evilcrow.evilcrowrf</id>
  <name>EvilCrow RF</name>
  <summary>RF device controller</summary>
  <url type="homepage">https://github.com/EvilCrowRF/EvilCrowRF-V2</url>
  <metadata_license>MIT</metadata_license>
  <project_license>MIT</project_license>
  <requires>
    <!-- Minimum screen width for usable UI -->
    <display_length compare="ge">800</display_length>
  </requires>
</component>
```

**Note:** `<display_length>` restricts the display width, not network access. Network access is implicitly granted by the `linux` platform in Flutter. No explicit D-Bus or AppStream network permission is needed.

**mDNS on Linux:**

The app discovers devices via mDNS (`_evilcrow._tcp`). Linux needs `avahi-daemon` running.
For development, wrap the app launch:

```bash
sudo systemctl start avahi-daemon
```

**Window configuration (`linux/my_application.cc`):**

```cpp
// Set minimum window size appropriate for the app's UI
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window = GTK_WINDOW(gtk_application_get_active_window(
      GTK_APPLICATION(application)));

  gtk_window_set_default_size(window, 400, 700);
  gtk_window_set_resizable(window, TRUE);
  gtk_window_set_title(window, "EvilCrow RF");
}
```

---

#### 3.5.4 Build Profiles

| Profile | Command | Use case |
|---------|---------|----------|
| Debug | `flutter build linux --debug` | Development, hot reload available |
| Profile | `flutter build linux --profile` | Performance tracing, no asserts |
| Release | `flutter build linux --release` | End-user builds, stripped binary |

---

#### 3.5.5 Desktop-Specific Considerations

| Concern | Guidance |
|---------|----------|
| **Hot reload** | Works on Linux desktop — the fastest development cycle for UI work. |
| **No BLE dependencies** | `flutter_blue_plus` is never bundled in WiFi mode, so no link errors from missing native BLE libraries. |
| **Manual IP fallback** | Add a text field in app settings to enter device IP directly (for environments where mDNS is blocked). |
| **Multiple windows** | GTK runner creates one window by default; the app does not need more. |
| **Packaging** | Use `flutter build linux --release` then package with `linuxdeploy` or distribute as an AppImage. |
| **Testing without hardware** | The `WifiProvider` can be driven by a mock WebSocket server for unit/integration tests. |

---

### Phase 4: Mobile App — WifiProvider

**File to create:** `lib/providers/wifi_provider.dart`

**Responsibilities:**
- mDNS discovery of `_evilcrow._tcp.local` services
- SmartConfig provisioning using `network_info_plus` (get current SSID)
- WebSocket connection management
- Same `FirmwareBinaryProtocol` command creation/response parsing
- Same notification/callback interface as `BleProvider`

### Phase 5: Mobile App — Build-Time Mode Switch

**Build-time approach (default):**
- `main.dart` checks `--dart-define=TRANSPORT_MODE`:
  - `bt` → inject `BleProvider`
  - `wifi` → inject `WifiProvider`
- All screens remain unchanged — they consume via `Provider.of<DeviceProvider>()` using a shared abstract interface.

**Alternative: Runtime mode (single binary)**
Instead of two separate builds, compile both `BleProvider` and `WifiProvider` into the same binary. At runtime, detect available hardware or let the user choose from a settings screen. Use a `DeviceTransport` enum:

```dart
enum DeviceTransport { auto, bluetooth, wifi }
```

This allows a single APK to support both BLE and WiFi devices, which is useful for developers who work with both transport types. The `lib_ignore` pattern in `platformio.ini` still applies to the firmware builds, but the mobile app can ship as a single binary with runtime selection. The downside is a modestly larger APK (~500 KB from including both provider implementations).

### Phase 6: Test & Validation

| Test | Method |
|------|--------|
| Provisioning | Fresh device, SmartConfig from app |
| Reconnection | Device reboot, auto-connect to saved WiFi |
| Throughput | File list, file upload/download, OTA |
| Command round-trip | End-to-end scan → record → transmit cycle |
| Bruter live updates | WebSocket binary messages during attack |
| nRF24/MouseJack | Live scan results over WebSocket |
| SDR spectrum | Streaming spectrum data over WebSocket |

---

## 8. Security Considerations

| Concern | Mitigation |
|---------|------------|
| Local network access | Device binds to `0.0.0.0`. Any client on the LAN can connect — appropriate for a lab device, but differs from BLE's physical-proximity requirement. |
| Unauthorized commands | **v1:** Device generates a random 8-character alphanumeric **device key** on first boot, stored in NVS and displayed on the device's screen (or accessible via `GET /api/info`). The app prompts the user to enter this key on first connection. Subsequent connections from the same app instance are trusted. **Future v2:** Token exchange on WebSocket connect. |
| OTA hijacking | MD5 verification (already implemented in BLE OTA) reused as-is. |
| SoftAP snooping | WPA2 on config SoftAP where possible; sensitive operations disabled in AP mode. |
| No TLS on LAN | Acceptable for v1 since the device is intended for controlled testing environments. TLS/WSS can be added later when internet-connected features are introduced. |

**Device key flow:** On first boot, the device generates a random key (e.g., `A3F7K9X2`). This key is:
- Written to NVS
- Returned in the `GET /api/info` response as `"device_key": "A3F7K9X2"`
- Shown on the device display (if available) or accessible via the captive portal
- Entered once by the user in the app when connecting to a new device
- Stored in the app's `shared_preferences` and sent with every WebSocket connection (header field or first message)

This provides protection against accidental (not adversarial) network access without the complexity of a full PKI.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| SmartConfig unreliable on some routers (5 GHz band, enterprise networks) | Fallback to SoftAP captive portal with QR code (documented in Section 3.2). |
| WebSocket reconnection on network change | Reconnection state machine with exponential backoff: **1 s → 2 s → 4 s → 8 s → 16 s → 30 s (max)**. On each retry, re-discover device via mDNS. After successful reconnect, replay any pending command that was in-flight when the connection dropped. |
| OTA large firmware (1.8 MB) over WiFi | WebSocket binary streaming at ~1–2 MB/s at close range (estimate ~1–2 s for 1.8 MB). App shows real-time progress via `OTA_PROGRESS` notifications. |
| mDNS blocked on some networks | Manual IP entry field in app settings. On first manual connection, attempt mDNS alongside IP entry for resilience. |
| AsyncWebServer + CC1101 ISR conflicts | WebServer on Core 0, CC1101 worker on Core 1 (already the architecture). Ensure no shared data access without mutex. |
| AsyncTCP static buffer threading | Share `sendChunkMutex` pattern from `BleAdapter`. Ensure WebSocket sends are serialized. |
| DHCP lease renewal changes device IP | mDNS handles name resolution — app always resolves `device.local` rather than caching IP. |
| Device key leaked | Key is low-security (lab environment device). An attacker on the same LAN can already send commands. Key prevents accidental cross-device confusion, not adversarial access. |

---

## 10. Future Considerations

- **Web-based control panel:** The AsyncWebServer makes it trivial to add a web UI for desktop users without the app.
- **Internet-connected features:** Check GitHub releases directly from the device, sync signal databases, forward captured signals.
- **Bridge mode:** A standalone ESP32 could act as a BLE-to-WiFi bridge for legacy devices.
- **TLS:** Add HTTPS + WSS for encrypted transport on untrusted networks.

---

## Appendix: File Change Summary

### Firmware (C++)

| File | Action |
|------|--------|
| `platformio.ini` | Rename `[env:esp32dev]` → `[env:evilcrow-bt]` + `[env:evilcrow-wifi]` |
| `Makefile` | Add `build-bt`, `build-wifi`, `flash-bt`, `flash-wifi` targets |
| `src/main.cpp` | Add `#ifdef EVILCROW_WIFI_MODE` init path |
| `src/core/ble/BinaryProtocolHandler.h/.cpp` | **NEW** — shared protocol logic from BleAdapter |
| `src/core/ble/BleAdapter.h/.cpp` | Extract shared logic into BinaryProtocolHandler |
| `src/core/ControllerAdapter.h` | Reference at `core/` (was `core/ble/`) — abstract base for both BleAdapter and WifiAdapter |
| `src/core/ClientsManager.h` | Reference at `core/` (was `core/ble/`) — fan-out to all adapters |
| `src/core/CommandHandler.h` | Reference at `core/` (was `core/ble/`) — command dispatch |
| `src/core/wifi/WifiAdapter.h/.cpp` | **NEW** — ControllerAdapter subclass, WebSocket server, mDNS |
| `src/core/wifi/WifiConfigManager.h/.cpp` | **NEW** — SmartConfig + SoftAP portal |

### Mobile App (Flutter/Dart)

| File | Action |
|------|--------|
| `pubspec.yaml` | Add `web_socket_channel`, `network_info_plus` |
| `lib/providers/wifi_provider.dart` | **NEW** — WiFi connection, WebSocket, SmartConfig |
| `lib/providers/ble_provider.dart` | Keep unchanged (BT mode still exists) |
| `lib/transport/transport_layer.dart` | Add `WifiWebSocketTransport` implementation |
| `lib/transport/transport_adapter.dart` | Add wifi transport type |
| `lib/main.dart` | Conditionally inject `WifiProvider` or `BleProvider` |
| `Makefile` | Add `apk-bt`, `apk-wifi` targets |

### Linux Platform (Flutter/Dart)

| File | Action |
|------|--------|
| `linux/flutter/generated_plugin_registrant.h` / `.cc` | **NEW** — auto-generated by `flutter create --platforms linux` |
| `linux/my_application.h` / `.cc` | **NEW** — GTK runner, window sizing, app name |
| `linux/main.cc` | **NEW** — entry point |
| `linux/CMakeLists.txt` | **NEW** — build rules; add `GTK3`, `avahi-client` linkage if needed |
| `linux/io.evilcrow.evilcrowrf.metainfo.xml` | **NEW** — AppStream metadata, permissions |
