# Self-Contained Web Application — EvilCrowRF V2 over WebSocket

> **Status:** Design Document  
> **Date:** 2026-06-09  
> **Objective:** Design a self-contained, single-page web application that communicates with EvilCrowRF V2 over WiFi via WebSocket, providing a full-featured browser-based control interface.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Motivation & Goals](#2-motivation--goals)
3. [Existing WiFi Transport Architecture](#3-existing-wifi-transport-architecture)
4. [Web Application Architecture](#4-web-application-architecture)
5. [Binary Protocol Handling in the Browser](#5-binary-protocol-handling-in-the-browser)
6. [REST API Integration](#6-rest-api-integration)
7. [Device Discovery](#7-device-discovery)
8. [UI Components & Screens](#8-ui-components--screens)
9. [State Management](#9-state-management)
10. [Project Structure](#10-project-structure)
11. [Build & Deployment](#11-build--deployment)
12. [Security Considerations](#12-security-considerations)
13. [Comparison: Web App vs Flutter Mobile App](#13-comparison-web-app-vs-flutter-mobile-app)
14. [Future Considerations](#14-future-considerations)

---

## 1. Executive Summary

EvilCrowRF V2 currently provides two wireless transports for device control:

- **BLE** (Bluetooth Low Energy) — the original transport, used by the Flutter mobile app.
- **WiFi** (TCP + WebSocket) — a newer transport, with firmware support already implemented (see [`docs/tcp_transport.md`](tcp_transport.md)) and partial Flutter support via the `WifiProvider`.

This document describes a **self-contained web application** (an SPA that runs entirely in the browser) that uses the existing WiFi + WebSocket infrastructure to communicate with the EvilCrowRF device. The web app requires no native runtime, no app store installation, and no device-side firmware changes — it connects directly to the ESP32's WebSocket endpoint (`ws://<device>/api/ws`) using the standard `WebSocket` browser API.

**Key design principles:**

- **Self-contained:** Single directory of static files (HTML, CSS, JS). No build toolchain required for basic usage. Served from any static file server or even directly from the ESP32's LittleFS.
- **Zero-install for users:** Open a browser, enter the device IP, and control the device. No app store, no native dependencies.
- **Protocol-compatible:** Reuses the existing binary chunked protocol (magic byte `0xAA` framing) so it works with the already-shipped firmware WiFi mode.
- **Mobile-friendly:** Responsive UI that works on phone, tablet, and desktop browsers.

---

## 2. Motivation & Goals

### 2.1 Why a Web App?

| Requirement | BLE (Flutter App) | WiFi (Flutter App) | **Web App** |
|---|---|---|---|
| Cross-platform | Android only | Android + Linux (WIP) | **Any browser** |
| Install friction | APK download + install | APK download + install | **Open URL** |
| OTA firmware flashing | Via BLE (slow) | — | **Via ESP Web Tools + WiFi** |
| Onboarding | BLE scan + pair | SmartConfig / SoftAP | **Same WiFi setup + WebSocket** |
| Development iteration | Flutter SDK + rebuild | Flutter SDK + rebuild | **Hot-reload via live server** |

### 2.2 Goals

1. **Full device control** — Replicate the core functionality of the Flutter mobile app: mode switching, signal recording/transmission, file browser, brute-force attack control, nRF24 tools, SDR tools, ProtoPirate, and OTA updates.
2. **Zero native dependencies** — Use only standard web APIs (WebSocket, Fetch, Web Audio API, File API, BroadcastChannel for multi-tab coordination).
3. **Responsive UI** — Adapt to phone, tablet, and desktop viewports with a single codebase.
4. **Bookmarkable device connections** — Support URL-based device addressing (`?host=192.168.1.100`) so users can bookmark their device.
5. **Offline-capable scaffold** — The app shell (UI, protocol encoding/decoding) should work without a live device so the user can configure connection settings first.

### 2.3 Non-Goals

- Replacing the Flutter app entirely; both will coexist.
- Implementing BLE from the browser (Web Bluetooth API is limited and requires HTTPS + user gesture).
- Running without a WiFi-connected EvilCrowRF device.

---

## 3. Existing WiFi Transport Architecture

### 3.1 Firmware Side (Already Implemented)

The firmware's WiFi transport stack is already in place:

```
┌──────────────────────────────────────────────────────────┐
│  CommandHandler (0x01–0xFF dispatch)                     │
├──────────────────────────────────────────────────────────┤
│  BinaryProtocolHandler (chunked framing 0xAA)            │
├──────────────────────────────────────────────────────────┤
│  WifiAdapter (ControllerAdapter subclass)                 │
│  ├─ WifiWebSocket (AsyncWebSocket at /api/ws)            │
│  ├─ AsyncWebServer (port 80, REST endpoints)             │
│  ├─ WifiConfigManager (SmartConfig / SoftAP provisioning) │
│  └─ mDNS responder (_evilcrow._tcp, port 80)             │
├──────────────────────────────────────────────────────────┤
│  WiFi STA / AP (ESP32 radio)                             │
└──────────────────────────────────────────────────────────┘
```

**Key endpoints:**

| Endpoint | Method | Description |
|---|---|---|
| `/api/ws` | WebSocket | Binary protocol transport (chunked frames) |
| `/api/info` | GET | Device info: name, fw version, heap, uptime, RSSI |
| `/api/status` | GET | Connection status: WiFi state, WS state, SSID, IP |

**Binary frame format** (shared across all transports):

```
[0xAA] [type:1] [chunkId:1] [chunkNum:1] [totalChunks:1] [dataLen:2 LE] [data...] [checksum:1]
```

- **Command frames (client → device):** `type` values 0x01–0x7F. Differentiated by `chunkNum == 0` (single command) vs `chunkNum > 0` (chunked command).
- **Response frames (device → client):** `type` values 0x80–0xFF. Same framing.
- **Max data per chunk:** 500 bytes.
- **Checksum:** XOR of all bytes in the frame (header + data).

### 3.2 Transport Layer Abstraction

The Flutter app already defines a clean transport abstraction (`ITransportLayer`) with concrete implementations for BLE and WebSocket. The web app will follow the same pattern but use the browser-native `WebSocket` API.

---

## 4. Web Application Architecture

### 4.1 High-Level Design

```
┌────────────────────────────────────────────────────────────┐
│                    Browser (Any OS)                         │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │            Web Application (SPA)                      │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────────────┐  ┌────────────┐  │  │
│  │  │   UI     │  │  State Manager   │  │  Protocol  │  │  │
│  │  │  Screens │◄─┤  (EventEmitter / │◄─┤  Engine    │  │  │
│  │  │  Widgets │  │   Proxy / Store) │  │  (Binary   │  │  │
│  │  └──────────┘  └──────────────────┘  │  Framing)  │  │  │
│  │                                       └──────┬─────┘  │  │
│  │                                              │        │  │
│  │  ┌───────────────────────────────────────────┘        │  │
│  │  │  WebSocket API (native browser)                     │  │
│  │  └───────────────────────┬────────────────────────────┘  │
│  │                          │ ws://host/api/ws              │
│  └──────────────────────────┼──────────────────────────────┘
│                             │
└─────────────────────────────┼──────────────────────────────┘
                              │
                   ┌──────────┴──────────┐
                   │   WiFi Network       │
                   └──────────┬──────────┘
                              │
                   ┌──────────┴──────────┐
                   │  EvilCrowRF V2       │
                   │  (ESP32 + CC1101)    │
                   │  AsyncWebServer :80  │
                   │  AsyncWebSocket /ws  │
                   └─────────────────────┘
```

### 4.2 Technology Choices

| Layer | Choice | Rationale |
|---|---|---|
| **UI Framework** | Vanilla JavaScript (ES modules) | Zero build step, self-contained, no npm/bundler needed. Max portability. |
| **Or** | Single-file framework (Preact + HTM / Alpine.js) | If state management complexity warrants it. Decided at implementation time. |
| **CSS** | Custom CSS with CSS custom properties | Responsive design, dark/light theme via `prefers-color-scheme`. No framework dependency. |
| **WebSocket** | `new WebSocket(url)` | Native browser API. Binary frames via `Blob` or `ArrayBuffer`. |
| **HTTP** | `fetch()` | Native browser API. For `/api/info`, `/api/status`. |
| **Binary handling** | `ArrayBuffer`, `Uint8Array`, `DataView` | Native typed arrays for binary protocol encoding/decoding. |
| **File operations** | File System Access API / `<input type="file">` | For uploading signal files to device, downloading recordings. |

### 4.5 File Structure

The web app lives in a new top-level directory, `web-app/`, alongside the existing `web-flasher/`:

```
EvilCrowRF-V2/
├── web-app/                          # ← New: Web application
│   ├── index.html                    # Entry point (SPA shell)
│   ├── manifest.json                 # PWA manifest (optional)
│   ├── css/
│   │   ├── variables.css             # CSS custom properties / theme
│   │   ├── reset.css                 # Minimal CSS reset
│   │   ├── layout.css                # Grid/flex layout system
│   │   ├── components.css            # Reusable component styles
│   │   └── screens.css               # Per-screen styles
│   ├── js/
│   │   ├── app.js                    # Bootstrap / router (hash-based)
│   │   ├── protocol/
│   │   │   ├── constants.js          # Magic byte, message type enums
│   │   │   ├── frame.js              # Binary frame encode/decode (0xAA header)
│   │   │   ├── chunked.js            # Chunked send/receive assembly
│   │   │   └── commands.js           # Command builders (0x01–0x7F)
│   │   ├── transport/
│   │   │   ├── websocket.js          # WebSocket connection manager
│   │   │   ├── rest.js               # HTTP REST client for /api/info, /api/status
│   │   │   └── discovery.js          # mDNS / IP scan / manual connect
│   │   ├── state/
│   │   │   ├── store.js              # Central reactive state store
│   │   │   ├── device.js             # Device state & connection management
│   │   │   └── notifications.js      # User-facing notification queue
│   │   ├── screens/
│   │   │   ├── connect.js            # Device discovery & connection screen
│   │   │   ├── dashboard.js          # Main dashboard (status overview)
│   │   │   ├── transmitter.js        # Signal transmission
│   │   │   ├── recorder.js           # Signal recording
│   │   │   ├── files.js              # File browser
│   │   │   ├── bruter.js             # Brute force attack control
│   │   │   ├── nrf24.js              # nRF24 tools (MouseJack, jammer, scanner)
│   │   │   ├── sdr.js                # SDR mode (spectrum, raw RX)
│   │   │   ├── protopirate.js        # ProtoPirate decoder
│   │   │   ├── settings.js           # Device settings
│   │   │   └── ota.js                # OTA firmware update
│   │   ├── components/
│   │   │   ├── status-bar.js         # Connection indicator, device info
│   │   │   ├── nav-bar.js            # Sidebar / bottom navigation
│   │   │   ├── signal-viewer.js      # Signal waveform visualizer
│   │   │   ├── spectrogram.js        # Spectrum visualization (Canvas)
│   │   │   ├── file-tree.js          # Directory tree browser
│   │   │   └── modal.js              # Reusable modal dialog
│   │   └── utils/
│   │       ├── dom.js                # DOM helpers (createElement, etc.)
│   │       ├── format.js             # Frequency, time, hex formatting
│   │       ├── audio.js              # Web Audio API utilities for signal playback
│   │       └── storage.js            # localStorage wrapper for app settings
│   └── assets/
│       ├── icons/                    # SVG icons (material-style)
│       └── logo.svg                  # EvilCrowRF logo
```

---

## 5. Binary Protocol Handling in the Browser

### 5.1 WebSocket Binary Mode

The browser `WebSocket` API supports binary frames via the `binaryType` property. The web app will set:

```js
const ws = new WebSocket('ws://192.168.1.100/api/ws');
ws.binaryType = 'arraybuffer'; // Receive binary frames as ArrayBuffer
```

### 5.2 Frame Encoding (Client → Device)

All commands to the device use the chunked binary protocol format:

```js
// constants.js
export const MAGIC_BYTE = 0xAA;
export const PACKET_HEADER_SIZE = 7;
export const MAX_CHUNK_SIZE = 500;

// frame.js
export function encodeFrame(type, payload) {
    const data = typeof payload === 'string'
        ? new TextEncoder().encode(payload)
        : payload;
    
    const frame = new Uint8Array(PACKET_HEADER_SIZE + data.length + 1);
    const dv = new DataView(frame.buffer);
    
    frame[0] = MAGIC_BYTE;          // magic
    frame[1] = type;                 // command type
    frame[2] = 0;                    // chunkId (0 for single-frame)
    frame[3] = 0;                    // chunkNum
    frame[4] = 1;                    // totalChunks
    dv.setUint16(5, data.length, true); // dataLen (little-endian)
    frame.set(data, PACKET_HEADER_SIZE);  // payload
    frame[PACKET_HEADER_SIZE + data.length] = calculateChecksum(frame, data.length);
    
    return frame;
}

function calculateChecksum(frame, dataLen) {
    let checksum = 0;
    for (let i = 0; i < PACKET_HEADER_SIZE + dataLen; i++) {
        checksum ^= frame[i];
    }
    return checksum;
}
```

### 5.3 Frame Decoding (Device → Client)

```js
export function decodeFrame(buffer) {
    const data = new Uint8Array(buffer);
    if (data.length < PACKET_HEADER_SIZE + 1) return null;
    
    const magic = data[0];
    if (magic !== MAGIC_BYTE) return null;
    
    const type = data[1];
    const chunkId = data[2];
    const chunkNum = data[3];
    const totalChunks = data[4];
    const dataLen = new DataView(buffer).getUint16(5, true);
    
    // Validate length
    if (data.length < PACKET_HEADER_SIZE + dataLen + 1) return null;
    
    const payload = data.slice(PACKET_HEADER_SIZE, PACKET_HEADER_SIZE + dataLen);
    const checksum = data[PACKET_HEADER_SIZE + dataLen];
    
    // Validate checksum
    const expected = calculateChecksum(data, dataLen);
    if (checksum !== expected) return null;
    
    return { type, chunkId, chunkNum, totalChunks, payload };
}
```

### 5.4 Chunked Message Assembly

For responses split across multiple frames (file listings, SDR data), the web app maintains a buffer keyed by `chunkId`:

```js
// chunked.js
const receiveBuffers = new Map();

export function handleFrame(frame) {
    if (frame.totalChunks === 1) {
        // Single frame — process immediately
        return processPayload(frame.type, frame.payload);
    }
    
    // Multi-frame assembly
    if (!receiveBuffers.has(frame.chunkId)) {
        receiveBuffers.set(frame.chunkId, {
            chunks: [],
            total: frame.totalChunks,
            type: frame.type,
            received: 0
        });
    }
    
    const buf = receiveBuffers.get(frame.chunkId);
    buf.chunks[frame.chunkNum - 1] = frame.payload;
    buf.received++;
    
    if (buf.received === buf.total) {
        // All chunks received — concatenate and process
        const fullPayload = concatenateChunks(buf.chunks);
        receiveBuffers.delete(frame.chunkId);
        return processPayload(buf.type, fullPayload);
    }
}
```

### 5.5 Message Type Constants

Mirrored from `firmware/include/BinaryMessages.h`:

```js
// constants.js
export const MessageType = {
    // Responses (0x80–0xFF)
    MSG_MODE_SWITCH:     0x80,
    MSG_STATUS:          0x81,
    MSG_HEARTBEAT:       0x82,
    MSG_SIGNAL_DETECTED: 0x90,
    MSG_SIGNAL_RECORDED: 0x91,
    MSG_SIGNAL_SENT:     0x92,
    MSG_SIGNAL_SEND_ERROR: 0x93,
    MSG_FILE_CONTENT:    0xA0,
    MSG_FILE_LIST:       0xA1,
    MSG_DIRECTORY_TREE:  0xA2,
    MSG_FILE_ACTION_RESULT: 0xA3,
    MSG_ERROR:           0xF0,
    MSG_LOW_MEMORY:      0xF1,
    MSG_COMMAND_SUCCESS: 0xF2,
    MSG_COMMAND_ERROR:   0xF3,
    MSG_BRUTER_PROGRESS: 0xB0,
    MSG_BRUTER_COMPLETE: 0xB1,
    MSG_BRUTER_PAUSED:   0xB2,
    MSG_BRUTER_RESUMED:  0xB3,
    MSG_BRUTER_STATE_AVAIL: 0xB4,
    MSG_SETTINGS_SYNC:   0xC0,
    MSG_VERSION_INFO:    0xC2,
    MSG_BATTERY_STATUS:  0xC3,
    MSG_SDR_STATUS:      0xC4,
    MSG_SDR_SPECTRUM_DATA: 0xC5,
    MSG_SDR_RAW_DATA:    0xC6,
    MSG_DEVICE_NAME:     0xC7,
    MSG_HW_BUTTON_STATUS: 0xC8,
    MSG_SD_STATUS:       0xC9,
    MSG_NRF_STATUS:      0xCA,
    // nRF24 events (0xD0–0xD7)
    MSG_NRF_DEVICE_FOUND:    0xD0,
    MSG_NRF_ATTACK_COMPLETE: 0xD1,
    MSG_NRF_SCAN_COMPLETE:   0xD2,
    MSG_NRF_SCAN_STATUS:     0xD3,
    MSG_NRF_SPECTRUM_DATA:   0xD4,
    MSG_NRF_JAM_STATUS:      0xD5,
    MSG_NRF_JAM_MODE_CONFIG: 0xD6,
    MSG_NRF_JAM_MODE_INFO:   0xD7,
    // OTA events (0xE0–0xE2)
    MSG_OTA_PROGRESS:  0xE0,
    MSG_OTA_COMPLETE:  0xE1,
    MSG_OTA_ERROR:     0xE2,
    // ProtoPirate events (0xB5–0xBB)
    MSG_PP_DECODE_RESULT: 0xB5,
    MSG_PP_HISTORY_ENTRY: 0xB6,
    MSG_PP_STATUS:        0xB7,
    MSG_PP_HISTORY_COUNT: 0xB8,
    MSG_PP_FILE_LIST:     0xB9,
    MSG_PP_TX_STATUS:     0xBA,
    MSG_PP_SAVE_RESULT:   0xBB,
};

// Command types (0x01–0x7F) — from firmware CommandHandler
export const CommandType = {
    GET_STATE:         0x01,
    SET_MODE:          0x02,
    SET_CONFIG:        0x03,
    SET_BRUTER:        0x04,
    GET_FILE:          0x05,
    SET_TRANSMIT:      0x06,
    SET_RECORD:        0x07,
    SCAN_FREQUENCIES:  0x08,
    FILE_LIST:         0x09,
    FILE_DELETE:       0x0A,
    FILE_RENAME:       0x0B,
    FILE_MKDIR:        0x0C,
    FILE_COPY:         0x0D,
    FILE_MOVE:         0x0E,
    UPLOAD_INIT:       0x11,
    UPLOAD_CHUNK:      0x12,
    UPLOAD_FINALIZE:   0x13,
    // ... etc.
};
```

### 5.6 Response Parsers

Each message type has a dedicated parser that converts the binary payload into a structured JavaScript object:

```js
export function parseStatus(payload) {
    const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    return {
        module0Mode: payload[0],
        module1Mode: payload[1],
        numRegisters: payload[2],
        freeHeap: dv.getUint32(3, true),
        cpuTempDeciC: dv.getInt16(7, true),
        core0Mhz: dv.getUint16(9, true),
        core1Mhz: dv.getUint16(11, true),
        module0Registers: Array.from(payload.slice(13, 60)),
        module1Registers: Array.from(payload.slice(60, 107)),
    };
}
```

---

## 6. REST API Integration

The web app uses REST endpoints for lightweight polling and initial device discovery:

### 6.1 Device Info Polling

```js
// rest.js
export async function fetchDeviceInfo(host) {
    const response = await fetch(`http://${host}/api/info`, {
        signal: AbortSignal.timeout(3000)
    });
    if (!response.ok) return null;
    return await response.json();
    // Returns: { device_name, fw_version, free_heap, uptime, transport, rssi }
}

export async function fetchDeviceStatus(host) {
    const response = await fetch(`http://${host}/api/status`, {
        signal: AbortSignal.timeout(3000)
    });
    if (!response.ok) return null;
    return await response.json();
    // Returns: { connected, wifi_connected, ws_connected, ssid, ip }
}
```

### 6.2 When to Use REST vs WebSocket

| Operation | Transport | Reason |
|---|---|---|
| Device discovery | HTTP GET `/api/info` | Quick, stateless, no connection needed |
| Connection status | HTTP GET `/api/status` | Useful before establishing WebSocket |
| Real-time control | WebSocket binary frames | Low latency, full protocol support |
| File upload | WebSocket (chunked commands `0x11–0x13`) | Uses existing firmware upload protocol |
| OTA firmware flash | **ESP Web Tools** (browser serial) | Uses WebSerial API, not WebSocket. Separate UI. |

---

## 7. Device Discovery

### 7.1 Discovery Methods

| Method | How It Works | Reliability | Implementation |
|---|---|---|---|
| **Manual IP entry** | User types the device IP | Always works | Text input field + "Connect" button |
| **mDNS via .local** | Try `http://evilcrow.local/api/info` | Works on most networks (requires mDNS resolver on client OS) | Fetch with short timeout |
| **URL parameter** | `?host=192.168.1.100` from bookmark | User must know IP | Parse `URLSearchParams` on load |
| **Local subnet scan** | Probe common IPs (`.1`–`.254`) | Slow, hit-or-miss | Sequential `fetch()` with 500ms timeout per IP |
| **QR code** | Encode IP as QR code on device display | Requires display on device | Future enhancement |

### 7.2 Discovery Flow

```
                    ┌──────────────────┐
                    │  Connect Screen   │
                    │                   │
                    │  ┌─────────────┐  │
                    │  │ Manual IP   │  │
                    │  │ [________]  │  │
                    │  │ [Connect]   │  │
                    │  └─────────────┘  │
                    │                   │
                    │  [Scan Network]───┼──→ Try mDNS → Try subnet .1-.254
                    │                   │
                    │  Recent Devices:  │
                    │  ├ 192.168.1.42   │──→ Click to connect
                    │  └ evilcrow.local │
                    └──────────────────┘
```

The "Recent Devices" list is persisted to `localStorage`, keyed by `recentDevices`. Each entry stores `{ host, name, lastConnected }`.

---

## 8. UI Components & Screens

### 8.1 Navigation Structure

```
┌──────────────────────────────────────────┐
│  Status Bar: [⚡ 192.168.1.42] [FW 1.3.0] │
│  [████████████░░░░] RSSI -62 dBm          │
├──────────────────────────────────────────┤
│                                           │
│  ┌───┬──────────────────────────────┐    │
│  │ 🏠 │  Dashboard                  │    │
│  │ 📡 │  Transmitter                │    │
│  │ 🎙 │  Recorder                   │    │
│  │ 📁 │  Files                      │    │
│  │ 🔨 │  Bruter                     │    │
│  │ 📻 │  nRF24                      │    │
│  │ 📊 │  SDR                        │    │
│  │ 🔑 │  ProtoPirate                │    │
│  │ ⚙  │  Settings                   │    │
│  │ 📥 │  OTA Update                 │    │
│  └───┴──────────────────────────────┘    │
│                                           │
│  Notification Tray: [3]                   │
└──────────────────────────────────────────┘
```

On mobile (viewport < 768px), navigation collapses to a bottom tab bar with 5 primary tabs; a "More" menu provides access to remaining screens.

### 8.2 Screen Descriptions

#### Connect Screen (`connect.js`)
- Manual IP/hostname input
- "Scan Network" button
- Recent connections list (from `localStorage`)
- Connection status indicator
- Auto-connect on page load if `?host=` param present

#### Dashboard (`dashboard.js`)
- Real-time device status (modes, free heap, CPU temp, uptime)
- CC1101 register visualization
- Battery level (from `MSG_BATTERY_STATUS`)
- SD card mount status, nRF24 module status
- Mode indicator for both CC1101 modules

#### Transmitter (`transmitter.js`)
- Select signal from file browser
- Set module, frequency, modulation, power
- Configure repeats and gap timing
- Send signal button with progress
- History of sent signals

#### Recorder (`recorder.js`)
- Select module, frequency, modulation, sample settings
- Start/stop recording
- Recorded signals list
- Raw signal visualization (Canvas)

#### Files (`files.js`)
- Tree view of LittleFS and SD card filesystems
- File download (save to local machine via File API)
- File upload (drag-and-drop to device via chunked upload protocol)
- Delete, rename, create directory actions
- .sub file preview

#### Bruter (`bruter.js`)
- Select protocol from list (33+ protocols)
- Configure power, delay, repeats
- Start/pause/resume/stop attack
- Real-time progress bar, codes per second, current code
- Saved state resume indicator
- De Bruijn mode support

#### nRF24 (`nrf24.js`)
- Switch between MouseJack, Jammer, Scanner, Spectrum modes
- MouseJack: target scan, attack, status
- Jammer: mode selection, channel config, start/stop
- Scanner: real-time device discovery
- Spectrum: 80-channel RSSI bar chart (Canvas)

#### SDR (`sdr.js`)
- Start/stop spectrum scan
- Frequency range and step size configuration
- Spectrum waterfall display (Canvas)
- Raw RX mode (live signal monitor)
- Modulation selection

#### ProtoPirate (`protopirate.js`)
- Decode automotive key fob signals
- Historical decode results list
- Save/export decoded signals
- Replay saved signals

#### Settings (`settings.js`)
- View/change device configuration (scanner RSSI threshold, bruter power/delay/repeats, radio power per module)
- Device name display
- Firmware version info
- WiFi credentials management
- Reboot device

#### OTA Update (`ota.js`)
- **Option A (WebSocket):** Use the existing OTA over WebSocket protocol (`0x30–0x35` commands) for firmware upload via binary frames.
- **Option B (ESP Web Tools):** Integrate the existing `web-flasher/` ESP Web Tools manifest for serial-based flashing (requires WebSerial API + USB connection).
- Show OTA progress, completion, and error states.
- MD5 verification display.

### 8.3 Reusable Components

| Component | Description |
|---|---|
| **StatusBar** | Connection state, device host, RSSI, heartbeat indicator |
| **NavBar** | Sidebar (desktop) or bottom tab bar (mobile) |
| **SignalViewer** | Canvas-based OOK/FSK signal waveform visualization |
| **Spectrogram** | Real-time spectrum waterfall (Canvas 2D) |
| **FileTree** | Expandable directory tree with file icons, sizes |
| **Modal** | Reusable modal dialog for confirmations, forms |
| **NotificationToast** | Slide-in notifications for events (errors, completions) |
| **FrequencyInput** | Input with unit selector (MHz/kHz) and common band presets |
| **ProgressBar** | Animated progress bar with percentage and label |

---

## 9. State Management

### 9.1 Reactive Store Pattern

The web app uses a lightweight pub/sub store instead of a full reactive framework:

```js
// store.js
class Store {
    constructor() {
        this._state = {
            connection: {
                host: null,
                status: 'disconnected', // 'disconnected' | 'connecting' | 'connected' | 'error'
                error: null,
                deviceInfo: null,
                rssi: 0,
            },
            device: {
                module0Mode: 0,
                module1Mode: 0,
                freeHeap: 0,
                cpuTemp: 0,
                batteryVoltage: 0,
                batteryPercent: 0,
                sdMounted: false,
                nrfPresent: false,
            },
            ui: {
                activeScreen: 'connect',
                theme: 'system', // 'light' | 'dark' | 'system'
                notifications: [],
            },
        };
        this._listeners = new Map(); // key → Set<callback>
    }

    get(key) {
        return key.split('.').reduce((o, k) => o?.[k], this._state);
    }

    set(key, value) {
        const keys = key.split('.');
        const lastKey = keys.pop();
        const target = keys.reduce((o, k) => o?.[k], this._state);
        if (target && target[lastKey] !== value) {
            target[lastKey] = value;
            this._notify(key, value);
        }
    }

    subscribe(key, callback) {
        if (!this._listeners.has(key)) this._listeners.set(key, new Set());
        this._listeners.get(key).add(callback);
        return () => this._listeners.get(key)?.delete(callback);
    }

    _notify(key, value) {
        this._listeners.get(key)?.forEach(cb => cb(value));
        // Also notify wildcard subscribers
        this._listeners.get('*')?.forEach(cb => cb(key, value));
    }
}

export const store = new Store();
```

State changes flow in one direction: WebSocket data → protocol parser → store update → UI re-render.

### 9.2 Connection State Machine

```
                    ┌──────────┐
                    │ START    │
                    └────┬─────┘
                         │
                    ┌────▼─────┐
          ┌─────────│ DISCONN- │
          │         │ ECTED    │◄──────────┐
          │         └────┬─────┘           │
          │              │ connect()       │ disconnect()
          │         ┌────▼─────┐           │
          │         │ CONNECT- │           │
          ├─────────│ ING      │───────────┤
          │  error  └────┬─────┘  timeout  │
          │              │ WebSocket open  │
          │         ┌────▼─────┐           │
          │         │ CONNECT- │           │
          ├─────────│ ED       │───────────┘
          │  error  └────┬─────┘
          │              │ WebSocket close
          │         ┌────▼─────┐
          └─────────│ RECONN-  │
          timeout   │ ECTING   │
                    └──────────┘
```

### 9.3 Heartbeat Monitoring

Once connected, the device sends periodic `MSG_HEARTBEAT` (0x82) messages containing `uptimeMs`. The web app uses these to:

- Detect stale connections (no heartbeat for > 10 seconds → show warning, attempt reconnect).
- Display uptime in the status bar.
- Estimate round-trip latency (optional timestamp echo in future firmware).

---

## 10. Build & Deployment

### 10.1 Development

Since the web app uses vanilla JS (no build step), development is straightforward:

```bash
# Serve the web-app directory with any static file server
cd EvilCrowRF-V2/web-app
python3 -m http.server 8080
# Open http://localhost:8080 in browser
```

For hot-reload during development, any of these work:

```bash
npx live-server web-app
# or
npx serve web-app
```

### 10.2 Deployment Options

| Method | Description | Pros | Cons |
|---|---|---|---|
| **GitHub Pages** | Host in the same repo as the web flasher | Free, HTTPS, CDN | Requires CI or manual deploy |
| **Serve from device** | Upload `web-app/` to ESP32 LittleFS | No network dependency for serving | Limited storage on ESP32 (~1.5 MB available) |
| **Local file** | Open `index.html` from disk | Zero setup | `file://` protocol restrictions (WebSocket may work, `fetch()` may not) |
| **Docker / Nginx** | Containerized deployment | Full control | Overkill for most users |

**Recommendation:** Host on GitHub Pages (same infrastructure as the existing web flasher) at e.g. `https://senape3000.github.io/EvilCrowRF-V2/web-app/`. The device is accessed by IP so no server-side logic is needed.

### 10.3 PWA Support (Optional)

Add a `manifest.json` and a service worker to make the app installable as a PWA:

```json
// manifest.json
{
    "name": "EvilCrowRF V2 Web Controller",
    "short_name": "EvilCrowRF",
    "start_url": "?source=pwa",
    "display": "standalone",
    "background_color": "#1a1a2e",
    "theme_color": "#16213e",
    "icons": [
        { "src": "assets/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
        { "src": "assets/icons/icon-512.png", "sizes": "512x512", "type": "image/png" }
    ]
}
```

### 10.4 Release Artifacts

For each firmware release, the web app should be tagged and released alongside:

```
evilcrow-v2-web-vX.Y.Z.zip
├── index.html
├── manifest.json
├── css/...
├── js/...
└── assets/...
```

A CI workflow (GitHub Actions) can:

1. Zip the `web-app/` directory.
2. Attach it to the GitHub release.
3. Deploy to GitHub Pages on tag push.

---

## 11. Security Considerations

### 11.1 Same-Origin & CORS

- The WebSocket connects to `ws://<device-ip>/api/ws`. The WebSocket API is **not** subject to same-origin policy in browsers, so this works from any origin.
- HTTP `fetch()` calls to the ESP32's REST API are cross-origin requests. The ESP32's `AsyncWebServer` must include CORS headers:

```cpp
// In WifiAdapter.cpp or a middleware
server_.onNotFound([](AsyncWebServerRequest* request) {
    request->send(404);
});
// Set default CORS headers
DefaultHeaders::Instance().addHeader("Access-Control-Allow-Origin", "*");
DefaultHeaders::Instance().addHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
DefaultHeaders::Instance().addHeader("Access-Control-Allow-Headers", "Content-Type");
```

### 11.2 Network Exposure

- The device exposes an open WebSocket endpoint with no authentication. Anyone on the same WiFi network can connect and send commands.
- **Mitigation:** The device is intended for lab/testing environments on trusted networks. The existing design (shared by both BLE and WiFi transports) does not include authentication. Future firmware enhancements could add a simple token-based handshake or WiFi password-derived session key.
- **Recommendation for documentation:** Clearly advise users to only use the WiFi web app on trusted, isolated networks.

### 11.3 HTTPS

- The ESP32 serves plain HTTP (no TLS). Browsers will show a "Not Secure" indicator for the REST API calls but will not block the WebSocket connection.
- **Future:** If WebSerial is used for OTA, the page must be served over HTTPS (`self` or localhost). Hosting on GitHub Pages (HTTPS) solves this.

### 11.4 Input Validation

- All data received from the WebSocket should be treated as untrusted. The binary protocol parser must bounds-check array accesses and validate lengths before reading.
- File uploads from the web app to the device should verify filename lengths and path safety (no path traversal).

---

## 12. Comparison: Web App vs Flutter Mobile App

| Aspect | Flutter Mobile App | Web App |
|---|---|---|
| **Platform** | Android (BLE + WiFi) Linux (WiFi only, WIP) | Any browser on any OS |
| **Installation** | APK download + install | Open URL (no install) |
| **Transport** | BLE (NimBLE) or WiFi (WebSocket) | WiFi only (WebSocket) |
| **BLE support** | ✅ Full | ❌ (Web Bluetooth impractical for this use case) |
| **Offline use** | ✅ (once installed) | ❌ (requires network to load) |
| **OTA flashing** | ✅ via BLE (chunked transfer) | ✅ via WebSerial (direct USB) or WebSocket |
| **Performance** | Native (fast) | JS (adequate for RF control) |
| **File operations** | Direct file system access | Web File API + download |
| **Signal playback** | Via phone speaker | Web Audio API (oscillators) |
| **Screen real estate** | Phone-optimized | Responsive (phone → desktop) |
| **Development** | Flutter SDK, rebuild needed | Live reload with any editor |
| **Code sharing** | Dart-based | JS-based (different codebase) |

---

## 13. Future Considerations

### 13.1 Two-Factor Transport (WiFi + BLE)

If the user wants both BLE and WiFi simultaneously, a first-gen ESP32 cannot support it (single 2.4 GHz radio). However, future ESP32 variants (ESP32-C6, ESP32-S3 with dual radio) may allow simultaneous operation.

### 13.2 WebRTC Data Channels

For ultra-low-latency streaming (e.g., SDR raw audio), WebRTC data channels could be explored as an alternative to WebSocket. This would require a WebRTC-compatible transport on the firmware side.

### 13.3 WebAssembly Protocol Optimizations

The binary protocol encoder/decoder could be ported to WebAssembly (Rust or C compiled with Emscripten) for performance-critical operations like checksum calculation over large file transfers.

### 13.4 Multi-Device Dashboard

A "network view" that shows all EvilCrowRF devices on the local network with their status, similar to the BLE device list but over mDNS.

### 13.5 Browser Extension

A companion browser extension could:
- Automatically detect EvilCrowRF devices on the network.
- Inject a control panel into supported web pages.
- Provide keyboard shortcuts for common actions.

### 13.6 Direct Sharing

Integration with the Web Share API to share recorded signals as `.sub` files between devices, and QR code generation of device connection info.

---

## Appendix: Cross-Reference

| Component | Flutter App Equivalent | Firmware File |
|---|---|---|
| WebSocket transport | `WifiWebSocketTransport` in `transport_layer.dart` | `WifiWebSocket.h/cpp`, `WifiAdapter.h/cpp` |
| Binary protocol | `FirmwareBinaryProtocol` in `firmware_protocol.dart` | `BinaryProtocolHandler.h/cpp` |
| Device discovery | `WifiProvider.startDiscovery()` in `wifi_provider.dart` | REST `/api/info` endpoint |
| State management | `BleProvider`, `WifiProvider` (ChangeNotifier) | N/A (firmware dispatches to `ClientsManager`) |
| Message types | `BinaryMessageParser` in `binary_message_parser.dart` | `BinaryMessages.h` |
| REST API client | `_queryDeviceInfo()` in `wifi_provider.dart` | `WifiAdapter::registerRestEndpoints()` |
| WiFi provisioning | `WifiProvider.provisionViaSmartConfig()` | `WifiConfigManager.h/cpp` |
| OTA over WS | BLE chunked OTA | `OtaCommands.h` (0x30–0x35) |
| Web flasher | — | `web-flasher/` (existing, ESP Web Tools) |

---

## Appendix: Implementation Phases

### Phase 1: Scaffold & Core Transport (Week 1)
- `index.html` + CSS base
- `websocket.js` — WebSocket connection manager with reconnect
- `frame.js` — Binary frame encode/decode
- `constants.js` — Message type enums
- `store.js` — Reactive state store
- `connect.js` — Connect screen (manual IP, scan)
- `dashboard.js` — Basic status display

### Phase 2: Core Device Control (Week 2)
- `commands.js` — Command builders for all command types
- `transmitter.js` — Signal transmission
- `recorder.js` — Signal recording
- `files.js` — File browser with download/upload
- `chunked.js` — Chunked message assembly

### Phase 3: Advanced Features (Week 3)
- `bruter.js` — Brute force attack control with real-time progress
- `sdr.js` — SDR spectrum visualization (Canvas)
- `nrf24.js` — nRF24 tools
- `protopirate.js` — ProtoPirate decoder
- `ota.js` — OTA update via WebSocket + WebSerial integration

### Phase 4: Polish & Release (Week 4)
- Responsive design for mobile
- Dark/light theme
- PWA manifest + service worker
- `localStorage` persistence for settings and recent connections
- GitHub Actions workflow for deployment
- Documentation
- Testing with real hardware
