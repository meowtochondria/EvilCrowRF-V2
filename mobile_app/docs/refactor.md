# Mobile App Refactor Plan — Revised

## Changelog (from initial draft)

- Replaced monolithic 6-phase plan with 5 independently deployable milestones
- Added "Event Bus / Message Routing" as a foundational step (gates everything)
- Added "Modules Busy" investigation as a prerequisite bug investigation
- Added cross-provider communication pattern decision
- Added transport layer decision (use or delete dead code)
- Made file size targets realistic, not aspirational; removed "no file > 500 lines" as a hard rule
- Clarified `ActiveConnectionProvider` interface and lifecycle
- Clarified callback ownership model
- Added test harness setup before touching `BleProvider`
- Added OTA state machine design note
- Added SharedPreferences handling note
- HomeScreen fix moved to Milestone 0 (trivial, immediate)
- Acknowledged widgets >500 lines and deferred with a plan
- Updated MessageDispatcher to accept parsed `Map<String, dynamic>` instead of raw `Uint8List` (see audit finding: WiFi JSON responses have no binary message type byte)
- Deferred "Modules Busy" investigation until after WiFi response routing is fixed
- Cleaned up `CommandResponseHandler` → `BleChunkHandler` naming
- Updated `ConnectionStateProvider` to reference new types (`BleConnectionProvider`/`WifiConnectionProvider`)
- Added D5: WiFi Provisioning via mobile app — firmware SmartConfig background listener + app-side provisioning UI

---

## 0. Pre-work: Fix the HomeScreen Bug (Immediate, Zero-Risk)

**Before any refactoring**, fix the connection check bug in `home_screen.dart`.

### Scope of the problem

This bug has two layers:

1. **Surface layer (HomeScreen navigation guard).** The tab-bar tap handler in `home_screen.dart` line ~151 correctly checks `bleProvider.isConnected || wifiProvider.isConnected`, but every other screen that reads `Provider.of<BleProvider>(context).isConnected` sees `false` when connected via WiFi — so they all show "device not connected."

2. **Deep layer (WiFi response routing is completely unwired).** Even if you bypass the HomeScreen guard, WiFi mode cannot process *any* module responses. `WifiProvider._handleBinaryFrame()` calls `onJsonReceived!(response)` (line 319 of `wifi_provider.dart`), but **nothing ever sets `onJsonReceived`**. The entire `_handleCompleteResponse` dispatch — with 50+ case handlers for Sub-GHz, NRF, Files, Bruter, OTA, settings — lives exclusively in `BleProvider`. This means **WiFi mode is completely non-functional for all modules**, not just blocked by a navigation check. Fixing this requires the `MessageDispatcher` from Milestone 1 — see §1.1 and §1.5.

### Why Milestone 0 is still zero-risk

We fix only the **surface layer** here: create `ConnectionStateProvider` so the HomeScreen navigation guard and widget connection checks work correctly for the BLE path (which already works) and return correct state for the WiFi path (which will become functional once §1.5 wires the response routing).

### The Bug

`home_screen.dart` line ~151:
```dart
final isConnected = bleProvider.isConnected || wifiProvider.isConnected;
```

This check works in `HomeTab`, but most other screens do:
```dart
Provider.of<BleProvider>(context, listen: false).isConnected
```

When connected via WiFi, `BleProvider.isConnected` is `false`, so every screen that uses the above check shows "device not connected".

### Fix

Create `ConnectionStateProvider` (see Milestone 1.2) and update `HomeScreen`'s navigation guard to use it. This is a one-file, ~50-line provider that listens to both BLE and WiFi providers and exposes `isConnected`.

**Files touched:** `providers/connection_state_provider.dart` (new ~50 lines)

---

## 0b. Investigate "Modules Busy" — Is It a Real Bug?

> **Deferred.** The "modules busy" investigation is blocked until Milestone 1.5 wires WiFi response routing to `MessageDispatcher`. Without this, you cannot send module commands over WiFi or observe firmware responses, so testing for SPI contention over WiFi is impossible. Resume this investigation after Milestone 1 is complete and both transport paths can exercise Sub-GHz and NRF commands.

For reference, the possible causes remain:

1. **A real SPI contention bug** (NRF24 and CC1101 share SPI; commands may race)
2. **Missing command queuing** (module A receives a command while still processing module B's previous command)
3. **A firmware-side issue** (firmware reports "busy" when SPI is locked)

### How to investigate (after Milestone 1)

1. In `ble_provider.dart`, search for "busy" and "module" in string literals — find where this error originates
2. Check `_handleFirmwareResponse` and its dispatch logic: when a module is busy, does the firmware return a specific error code?
3. Check if `NRF24` and `CC1101` share an SPI bus on the device — if so, a mutex/lock pattern should exist in firmware, and the app should not send commands to CC1101 while NRF24 is actively scanning (or vice versa)
4. Check the `_cleanupNrf()` call in `nrf_screen.dart` dispose — does it reliably release the SPI bus before Sub-GHz operations?

**This matters because:** if "modules busy" is a real race condition, no amount of architecture refactoring will fix it. The bug investigation determines whether we need a firmware-side fix, an app-side command queue, or just the connection abstraction.

---

## 1. Milestone: Connection Abstraction & Event Bus

**Goal:** Define how raw BLE/WiFi notifications become module-level state changes. This gates all subsequent milestones.

### 1.1 Define the Message Routing Architecture

This is the most important design decision in the entire refactor. Every subsequent step depends on it.

**Two-layer routing model — do NOT conflate them:**

```
Layer 1 - MessageDispatcher (parsed firmware responses)
  BLE: raw BLE notify bytes
    → BleChunkHandler reassembles chunks → complete Uint8List
    → FirmwareBinaryProtocol.parseResponse() → Map<String, dynamic>
    → MessageDispatcher.dispatch(parsedMap)
  WiFi: raw WebSocket binary frame
    → FirmwareBinaryProtocol.parseResponse() → Map<String, dynamic> (complete, no chunks)
    → MessageDispatcher.dispatch(parsedMap)
  → [providers filter by type field]
  → Module providers update their state

Layer 2 - AppEventBus (domain events, Milestone 2.7)
  AppEventBus.emit(SubGhzRecordingStarted(moduleIndex))
  → DeviceInfoProvider absorbs for its own state
  → SubGhzProvider absorbs for its own state
  → RecordScreen rebuilds
```

**Layering rule (the rule that prevents the double-listening bug):**
> *`MessageDispatcher` handles binary/transport frames. `AppEventBus` handles domain events. A provider never listens to both for the same piece of state.*

Why this matters in practice: `BleChunkHandler` emits a `ChunkComplete` event (binary-layer concern). `SubGhzProvider` does **not** need to react to `ChunkComplete` — it reacts only to `SubGhzRecordingStarted` (domain-layer concern). The transport layer fires `ChunkComplete`, the domain layer fires `RecordingStarted`, and they live in separate streams. This eliminates the question of whether a provider should "listen on the dispatcher, the bus, or both." It listens on exactly one.

**Why this rules out some alternatives:**
- Option B (Router pattern) would require `ConnectionProvider` to grow a `switch (msgType)` block — adding new modules means modifying `ConnectionProvider`, violating open-closed.
- A single unified bus with both binary and domain events would force every subscriber to filter noise and risk missing events.

**Decision for this codebase:** Two-layer model (MessageDispatcher + AppEventBus) because it maps cleanly onto the existing binary protocol while giving providers a type-safe domain API.

**Important — why `dispatch` accepts parsed `Map<String, dynamic>`, not raw `Uint8List`:**

The current `BleProvider._handleFirmwareResponse()` (line 1690) receives a `Map<String, dynamic>` from `FirmwareBinaryProtocol.parseResponse()`. This function parses both binary payloads (where `messageType` is `payload[0]`) and JSON payloads (where `type` is a string like `"SignalRecorded"`). If `MessageDispatcher` accepted raw `Uint8List`, JSON responses would have no meaningful `messageType` byte. The dispatcher must accept the **already-parsed** form so all providers can filter uniformly on the `type` field.

```dart
// connection/message_dispatcher.dart
class MessageDispatcher {
  // Broadcast: multiple providers observe simultaneously
  final StreamController<Map<String, dynamic>> _controller = StreamController.broadcast();

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  /// Dispatch a parsed firmware response to all subscribers.
  ///
  /// Called by:
  /// - BleConnectionProvider: after BleChunkHandler reassembles chunks and
  ///   FirmwareBinaryProtocol.parseResponse() parses the complete payload
  /// - WifiConnectionProvider: after FirmwareBinaryProtocol.parseResponse()
  ///   parses the complete WebSocket frame
  void dispatch(Map<String, dynamic> parsedResponse) {
    _controller.add(parsedResponse);
  }

  void dispose() => _controller.close();
}
```

**Critical contract for all providers consuming `MessageDispatcher.messages`:**
```dart
// Every provider subscriber MUST filter by the 'type' field before acting.
// A provider reacting to the wrong response type is a bug, not a feature.
_messageDispatcher.messages
    .where((msg) => msg['type'] == 'SignalRecorded')
    .listen(_handleSignalRecorded);
```

This is the same filtering pattern that `_handleCompleteResponse` (line 1978 of `ble_provider.dart`) already uses — a `switch` on `data['type']`. The MessageDispatcher simply broadcasts the parsed map and lets each provider run its own filter.

### 1.2 Create `ConnectionStateProvider` (~50 lines)

A lightweight `ChangeNotifier` that:
- Watches both `BleConnectionProvider` and `WifiConnectionProvider` via `addListener`
- Exposes `isConnected` (true if either is connected)
- Exposes `connectedTransport` ('ble' | 'wifi' | null)

> **Transition note:** During Milestones 0-2, `ConnectionStateProvider` will reference `BleProvider` and `WifiProvider` directly since `BleConnectionProvider` and `WifiConnectionProvider` don't exist yet. Once Milestone 1 creates the new transport providers, update the constructor. The public API (`isConnected`, `connectedTransport`) stays the same.

```dart
class ConnectionStateProvider extends ChangeNotifier {
  final BleConnectionProvider _ble;
  final WifiConnectionProvider _wifi;

  ConnectionStateProvider(this._ble, this._wifi) {
    _ble.addListener(_onChange);
    _wifi.addListener(_onChange);
  }

  bool get isConnected => _ble.isConnected || _wifi.isConnected;
  String? get connectedTransport => _ble.isConnected ? 'ble' : (_wifi.isConnected ? 'wifi' : null);
  // deviceName and fwVersion come from DeviceInfoProvider, not the transport

  void _onChange() { notifyListeners(); }

  @override
  void dispose() {
    _ble.removeListener(_onChange);
    _wifi.removeListener(_onChange);
    super.dispose();
  }
}
```

### 1.3 Extract `ble_chunk_handler.dart` (~200 lines)

Extract from `BleProvider` the chunked response assembly logic (L1773-L1978 approximately):
- `_handleChunkedResponse`
- `_cleanupStaleChunkBuffers`
- `_chunkData`, `_expectedChunks`, `_receivedChunks` maps
- `_chunkStartTimes`, `_chunkLastReceived` maps
- Chunk timeout constants (`_chunkTimeout`, `_chunkStaleTimeout`)

**Important: Verify before extracting.**

`WifiProvider` currently handles incoming frames as **complete WebSocket messages** — not chunked BLE notifications. In `WifiProvider._handleBinaryFrame()`:
```dart
void _handleBinaryFrame(List<int> data) {
  // Parse binary protocol frame (single complete message)
  final payload = data.sublist(PACKET_HEADER_SIZE, PACKET_HEADER_SIZE + dataLen);
  final response = FirmwareBinaryProtocol.parseResponse(Uint8List.fromList(payload));
  onJsonReceived!(response);  // complete, not chunked
}
```

**This means `BleChunkHandler` is NOT shared with WiFi.**

**Decision:** Keep chunk assembly **inside `BleConnectionProvider`** only. `WifiConnectionProvider` does NOT use `BleChunkHandler` since WebSocket already delivers complete frames. `BleChunkHandler` is a pure in-memory buffer class that `BleConnectionProvider` owns.

```dart
// connection/ble_chunk_handler.dart
class BleChunkHandler {
  final Map<int, Map<int, Uint8List>> _chunkData = {};
  final Map<int, int> _expectedChunks = {};
  final Map<int, Set<int>> _receivedChunks = {};
  final Map<int, DateTime> _chunkStartTimes = {};
  final Map<int, DateTime> _chunkLastReceived = {};

  static const Duration _chunkTimeout = Duration(seconds: 10);
  static const Duration _chunkStaleTimeout = Duration(seconds: 4);

  /// Process an incoming chunk. Returns complete assembled bytes when all chunks received.
  Uint8List? processChunk(int chunkId, int chunkNumber, int totalChunks, Uint8List data);
  void cleanupStaleBuffers();
  void dispose();
}
```

### 1.4 Create `BleConnectionProvider` (~300 lines) — Transport Only

Extract from `BleProvider`:
- BLE scanning (start/stop, scan results, permission handling)
- BLE device connection/disconnection
- Characteristic discovery and subscription setup
- Calling `BleChunkHandler.processChunk()` on incoming BLE notifications
- After chunk assembly: `FirmwareBinaryProtocol.parseResponse()` → `MessageDispatcher.dispatch(parsedMap)`

**Does NOT contain:** any module logic, any response handlers beyond chunk assembly, any module state.

### 1.5 Create `WifiConnectionProvider` (~200 lines) — Transport Only

Refactor `WifiProvider` to:
- Parse incoming WebSocket binary frames via `FirmwareBinaryProtocol.parseResponse()` (same parser BLE uses after chunk assembly)
- Dispatch parsed `Map<String, dynamic>` through `MessageDispatcher.dispatch()` — this is the **critical fix** that makes WiFi mode functional for modules
- Expose `sendCommand(Uint8List)` via WebSocket
- **Remove** the `onJsonReceived` / `onBinaryReceived` callback pattern — these are replaced by `MessageDispatcher`

**WiFi wiring (the critical path that currently doesn't exist):**
```dart
// WifiConnectionProvider._handleBinaryFrame — replaces current WifiProvider L299-324
void _handleBinaryFrame(List<int> data) {
  if (data.length < FirmwareBinaryProtocol.PACKET_HEADER_SIZE + 1) return;
  if (data[0] != FirmwareBinaryProtocol.MAGIC_BYTE) return;

  // Parse → same format BleProvider._handleFirmwareResponse receives today.
  // Pass the full frame — FirmwareBinaryProtocol.parseResponse handles
  // header extraction internally (do NOT strip the header manually).
  final parsed = FirmwareBinaryProtocol.parseResponse(Uint8List.fromList(data));
  // Route to all module providers (replaces onJsonReceived callback)
  _messageDispatcher.dispatch(parsed);
}
```

**Does NOT contain:** any module logic, any chunk assembly.

### 1.6 Delete or Integrate Dead `transport/` Code

The existing `transport/transport_layer.dart` with `ITransportLayer`, `BLEBinaryTransport`, `WifiWebSocketTransport`, and `TransportFactory` is **dead code** — never wired to the providers.

**Decision:** Delete it. The new `BleChunkHandler` + `MessageDispatcher` approach is cleaner and better suited for this codebase. The existing transport abstractions were a prior attempted design that was abandoned.

---

## 2. Milestone: Module Provider Extraction

**Goal:** Create focused providers for each module, each consuming `MessageDispatcher.messages`.

### 2.1 `DeviceInfoProvider` (~400 lines)

Extract from `BleProvider`:
- `deviceStatus`, `freeHeap`, `cpuTempC`, `core0Mhz`, `core1Mhz`
- `firmwareVersion`, `_fwMajor`, `_fwMinor`, `_fwPatch`
- `batteryVoltage`, `batteryPercent`, `batteryCharging`, `hasBatteryInfo`
- `deviceName`, `wifiApName`, `wifiApPassword`
- `cc1101Modules`, `sdMounted`, `sdTotalMB`, `sdFreeMB`
- `nrfPresent`
- `deviceBtn1Action`, `deviceBtn2Action`, `deviceBtn1PathType`, `deviceBtn2PathType`
- `_handleVersionInfo`, `_handleDeviceName`, `_handleWifiApConfig`, `_handleBatteryStatus`, `_handleHwButtonStatus`, `_handleSdStatus`, `_handleNrfModuleStatus`, `_handleSettingsSync`

Handles: Settings sync (when device connects, it pushes all device state). Subscribes to `MessageDispatcher.messages` and filters for `type == 'VersionInfo'`, `type == 'SettingsSync'`, `type == 'State'`, `type == 'DeviceName'`, `type == 'BatteryStatus'`, `type == 'HwButtonStatus'`, `type == 'SdStatus'`, `type == 'NrfModuleStatus'`, `type == 'WifiApConfig'`, `type == 'SdrStatus'`, `type == 'ModeSwitch'.

### 2.2 `SubGhzProvider` (~500 lines)

Extract from `BleProvider`:
- `isRecording`, `isFrequencySearching`, `isJamming`
- `detectedSignals`, `frequencySpectrum`
- `selectedModule`, `rssiThreshold`
- `recordedRuntimeFiles`
- `sdrModeActive`, `sdrSubMode`, `sdrFrequencyMHz`, `sdrModulation`
- `sendRecordCommand`, `sendIdleCommand`, `sendTransmitCommand`, `sendStartJamCommand`
- `startFrequencySearch`, `setSelectedModule`, `setRssiThreshold`
- `parseSignalFile`, `generateSignalFile`, `validateRecordConfig`
- `getSignalFileInfo`, `getSupportedFileExtensions`, `getSupportedGenerationFormats`
- `createRecordConfigFromSignal`, `getCC1101Calculator`, `getCC1101Values`
- `transmitFromFile`, `sendSetTimeCommand`
- `_handleSignalDetectedResponse`, `_handleSignalRecordedResponse`, `_handleSignalSentResponse`, `_handleSignalSendingErrorResponse`

Subscribes to: `MessageDispatcher.messages` and filters for `type == 'SignalDetected'`, `type == 'SignalRecorded'`, `type == 'SignalRecordError'`, `type == 'SignalSent'`, `type == 'SignalSendingError'`, `type == 'ModeSwitch'`.

### 2.3 `FilesProvider` (~500 lines)

Extract from `BleProvider`:
- `fileList`, `currentPath`, `currentPathType`
- `isLoadingFiles`, `fileListProgress`
- `isFormattingSD`, `sdFormatSuccess`, `sdFormatProgress`
- `refreshFileList`, `navigateToDirectory`, `navigateUp`, `switchPathType`
- `clearFileCache`, `invalidateCacheForPath`, `resetFileLoadingState`
- `readFileContent`, `downloadFile`
- `renameFile`, `deleteFile`, `moveFile`, `copyFile`, `createDirectory`
- `getDirectoryTree`, `_rebuildDirectoryTree`
- `_handleFilesListResponse`, `_handleFileDataResponse`, `_handleFileSystemResponse`, `_handleFileLoadResponse`, `_handleFileUploadResponse`

Subscribes to: `MessageDispatcher.messages` and filters for `type == 'files_list'`, `type == 'file_data'`, `type == 'FileSystem'`, `type == 'FileUpload'`, `type == 'DirectoryTree'`.

**Note:** All file system methods currently return `Future` using `_pendingFileReadCompleter`, `_pendingRenameCompleter`, etc. The `FilesProvider` should replace these completers with proper `Completer` instances inside each method, not stored as provider fields.

### 2.4 `NrfProvider` (~500 lines)

Extract from `BleProvider`:
- `nrfInitialized`, `nrfScanning`, `nrfAttacking`, `nrfSpectrumRunning`, `nrfJammerRunning`
- `nrfJamMode`, `nrfJamChannel`, `nrfJamDwellTimeMs`
- `nrfTargets`, `nrfSpectrumLevels`
- `nrfJamModeConfigs`, `nrfJamModeInfos`
- `awaitNrfInitResult`, `_nrfInitResult`
- `createNrfInitCommand`, `createNrfScanStartCommand`, `createNrfScanStopCommand`, etc.
- `ppStartDecode`, `ppStopDecode`, `ppGetHistoryCount`, etc. (ProtoPirate)
- `_handleNrfModuleStatus`, `_handleBruterProgress`, `_handleBruterComplete`, `_handlePPDecodeResult`, etc.

**Caveat:** The NRF provider also handles ProtoPirate state (`ppDecoding`, `ppResults`, etc.). Consider keeping ProtoPirate in `NrfProvider` for now to avoid over-splitting. ProtoPirate shares the NRF hardware module, so their state is inherently coupled.

Subscribes to: `MessageDispatcher.messages` and filters for `type == 'NrfModuleStatus'`, `type == 'NrfDeviceFound'`, `type == 'NrfAttackComplete'`, `type == 'NrfScanComplete'`, `type == 'NrfScanStatus'`, `type == 'NrfSpectrumData'`, `type == 'NrfJamStatus'`, `type == 'NrfJamModeConfig'`, `type == 'NrfJamModeInfo'`, plus ProtoPirate types (`PPDecodeResult`, `PPHistoryEntry`, `PPStatus`, `PPHistoryCount`, `PPFileList`, `PPTxStatus`, `PPSaveResult`).

### 2.5 `BruterProvider` (~400 lines)

Extract from `BleProvider`:
- `isBruterRunning`, `bruterActiveProtocol`, `bruterCurrentCode`, `bruterTotalCodes`
- `bruterPercentage`, `bruterCodesPerSec`, `bruterDelayMs`, `bruterPower`, `bruterRepeats`
- `bruterSavedStateAvailable`, `bruterSavedMenuId`, `bruterSavedCurrentCode`, `bruterSavedTotalCodes`, `bruterSavedPercentage`
- `lastBruterCompletionStatus`, `lastBruterCompletionMenuId`
- `sendBruterCommand`, `sendBruterCancelCommand`, `sendBruterPauseCommand`, `sendBruterResumeCommand`
- `queryBruterSavedState`, `setBruterDelay`, `setBruterModule`, `_resetBruterState`
- `_handleBruterProgress`, `_handleBruterComplete`, `_handleBruterPaused`, `_handleBruterResumed`, `_handleBruterStateAvail`

Subscribes to: `MessageDispatcher.messages` and filters for `type == 'BruterProgress'`, `type == 'BruterComplete'`, `type == 'BruterPaused'`, `type == 'BruterResumed'`, `type == 'BruterStateAvail'`.

### 2.6 `OtaProvider` (~300 lines)

Extract from `BleProvider`:
- `otaProgress`, `otaBytesWritten`, `otaComplete`, `otaErrorMessage`
- `_otaRebootPending`, `_otaPreRebootVersion`, `_otaReconnectTimer`
- `notifyOtaReboot`, `_scheduleOtaReconnect`, `uploadFile`, `uploadFileFromBytes`

**Design note:** OTA has a special state machine:
```
IDLE → UPLOADING (begin → chunks → end) → REBOOTING → WAITING_RECONNECT → COMPLETE/ERROR
```
The `OtaProvider` should implement this as a proper state machine (use a `state` field with an enum, not scattered booleans). This is the most stateful extraction and warrants careful design.

Subscribes to: `MessageDispatcher.messages` and filters for `type == 'OtaProgress'`, `type == 'OtaComplete'`, `type == 'OtaError'`.

---

### 2.7 Cross-Provider State Synchronization

**Decision:** Use a lightweight event bus. The previous "computed properties" recommendation was unworkable because `ChangeNotifier` doesn't propagate changes from sibling providers automatically. Adding `addListener` chains between every pair of providers creates tight coupling and memory leaks.

**Lightweight Event Bus Implementation (~30 lines):**
```dart
// services/app_event_bus.dart
import 'package:flutter/foundation.dart';

class AppEventBus {
  static final AppEventBus _instance = AppEventBus._internal();
  factory AppEventBus() => _instance;
  AppEventBus._internal();

  final _controllers = <Type, dynamic>{};

  void emit<T>(T event) {
    if (_controllers.containsKey(T)) {
      (_controllers[T]! as _EventController<T>).add(event);
    }
  }

  void on<T>(void Function(T) callback) {
    if (!_controllers.containsKey(T)) {
      _controllers[T] = _EventController<T>();
    }
    (_controllers[T]! as _EventController<T>).subscribe(callback);
  }

  void off<T>(void Function(T) callback) {
    if (_controllers.containsKey(T)) {
      (_controllers[T]! as _EventController<T>).unsubscribe(callback);
    }
  }
}

class _EventController<T> {
  final List<void Function(T)> _listeners = [];
  void add(T event) => _listeners.toList().forEach((l) => l(event));
  void subscribe(void Function(T) callback) => _listeners.add(callback);
  void unsubscribe(void Function(T) callback) => _listeners.remove(callback);
}
```

**Usage for the recording example:**
```dart
// SubGhzProvider
void startRecording() {
  _connection.sendCommand(FirmwareProtocol.createRequestRecordCommand(...));
  AppEventBus().emit(SubGhzStartedRecording(moduleIndex: _selectedModule));
}

// DeviceInfoProvider
class DeviceInfoProvider extends ChangeNotifier {
  DeviceInfoProvider() {
    AppEventBus().on<SubGhzStartedRecording>((event) {
      _isModuleRecording[event.moduleIndex] = true;
      notifyListeners();
    });
  }
}
```

**Only 3 event types are needed:**
1. `SubGhzStartedRecording(int moduleIndex)` / `SubGhzStoppedRecording(int moduleIndex)`
2. `NrfModuleStateChanged(bool busy, {String? reason})`
3. `ConnectionLost(String reason)` — used by OTA, Bruter, any provider that needs cleanup

**Why this is mobile-friendly:** Zero memory overhead when no events are flowing. No persistent streams. Listeners are cleaned up by `off()` in provider `dispose()`. No isolate communication. No dependency on `BuildContext`.

---

## 3. Milestone: Update Consumers

**Goal:** Replace all `Provider.of<BleProvider>(context)` calls with the appropriate new providers.

This spans nearly every file in the app. Work file-by-file:

### 3.1 Widgets that need updating

| File | Current Usage | Replace With |
|------|-------------|-------------|
| `widgets/quick_connect_widget.dart` | `BleProvider` | `WifiProvider` (discovery) + `ConnectionStateProvider` |
| `widgets/status_bar_widget.dart` | `BleProvider` | `DeviceInfoProvider` + `ConnectionStateProvider` |
| `widgets/module_status_widget.dart` | `BleProvider` | `DeviceInfoProvider` + `SubGhzProvider` + `NrfProvider` |
| `widgets/record_screen_widgets.dart` | `BleProvider` | `SubGhzProvider` + `FilesProvider` |
| `widgets/transmit_screen_widgets.dart` | `BleProvider` | `SubGhzProvider` |
| `widgets/file_list_widget.dart` | `BleProvider` | `FilesProvider` |
| `widgets/file_explorer_widget.dart` | `BleProvider` | `FilesProvider` |
| `widgets/transmit_file_dialog.dart` | `BleProvider` | `SubGhzProvider` + `FilesProvider` |
| `widgets/directory_tree_widget.dart` | `BleProvider` | `FilesProvider` |
| `widgets/file_preview_widget.dart` | `BleProvider` | `FilesProvider` |

### 3.2 Screens that need updating

| File | Notes |
|------|-------|
| `screens/home_screen.dart` | Replace connection check with `ConnectionStateProvider`; replace `BleProvider` with individual module providers |
| `screens/nrf_screen.dart` | `NrfProvider` for all NRF state; `DeviceInfoProvider` for `nrfPresent` |
| `screens/record_screen.dart` | `SubGhzProvider` for recording state; `FilesProvider` for recorded files |
| `screens/brute_screen.dart` | `BruterProvider` |
| `screens/protopirate_screen.dart` | `NrfProvider` (ProtoPirate state is in NrfProvider) |
| `screens/files_screen.dart` | `FilesProvider` |
| `screens/settings_screen.dart` | `DeviceInfoProvider` for device info; `ConnectionStateProvider` for connection state |
| `screens/ota_screen.dart` | `OtaProvider` |
| `screens/transmit_screen.dart` | `SubGhzProvider` |
| `screens/signal_scanner_screen.dart` | `SubGhzProvider` for `detectedSignals`, `frequencySpectrum` |
| `screens/file_viewer_screen.dart` | `FilesProvider` |
| `screens/debug_screen.dart` | `ConnectionStateProvider` or `BleProvider` directly (debug screen may need raw BLE access) |
| `screens/home_screen.dart` | Update the `_onConnectionStateChanged` listener |

### 3.3 Update `main.dart`

Replace:
```dart
ChangeNotifierProvider(create: (context) => BleProvider()),
ChangeNotifierProvider(create: (context) => WifiProvider()),
```

With all new providers registered in `MultiProvider`. The `ConnectionStateProvider` should be constructed with references to `BleConnectionProvider` and `WifiConnectionProvider` (or the existing `BleProvider`/`WifiProvider` if they're kept as-is during transition).

### 3.4 Migration Status — Screens

| File | Status | Provider(s) Used |
|------|--------|-----------------|
| `signal_scanner_screen.dart` | ✅ Done | `SubGhzProvider` |
| `transmit_screen.dart` | ✅ Done | `SubGhzProvider` + `DeviceInfoProvider` + `ConnectionStateProvider` |
| `file_viewer_screen.dart` | ✅ Done | `FilesProvider` + `ConnectionStateProvider` |
| `brute_screen.dart` | ✅ Done | `BruterProvider` + `SettingsProvider` |
| `protopirate_screen.dart` | ✅ Done | `NrfProvider` + `ConnectionStateProvider` |
| `nrf_screen.dart` | ✅ Done | `NrfProvider` + `DeviceInfoProvider` + `ConnectionStateProvider` |
| `home_screen.dart` | ✅ Done | `ConnectionStateProvider` + `BleProvider` (status only) |
| `files_screen.dart` | ✅ Done | `FilesProvider` + `ConnectionStateProvider` |
| `ota_screen.dart` | ✅ Done | `OtaProvider` + `ConnectionStateProvider` + `DeviceInfoProvider` |
| `directory_picker_dialog.dart` | ✅ Done | `FilesProvider` |
| `record_screen.dart` | ⏳ Blocked — see §3.5 | — |
| `settings_screen.dart` | ⏳ Deferred to M4 | — |

### 3.5 `record_screen.dart` Migration — Blocking Issues

**17 distinct `BleProvider` coupling points:**

| # | Pattern | Occurrences | Target |
|---|---------|-------------|--------|
| 1 | `BleProvider? _bleProvider` field | 1 | `SubGhzProvider? _subGhz` |
| 2 | `Provider.of<BleProvider>(context, listen: false)` in `didChangeDependencies` | 1 | `context.read<SubGhzProvider>()` |
| 3 | `_bleProvider?.addListener` / `.removeListener` | 4 | `_subGhz?.addListener` (ChangeNotifier supports it) |
| 4 | `_bleProvider?.recordedRuntimeFiles` | 1 | `_subGhz?.recordedRuntimeFiles` (same field name) |
| 5 | `bleProvider.isModuleJamming(i)` — method call | 8 | `subGhz.isJamming[i]` — map access |
| 6 | `bleProvider.isModuleRecording(i)` — method call | 8 | `subGhz.isRecording[i]` — map access |
| 7 | `bleProvider.isModuleAvailable(i)` | 5 | `context.read<DeviceInfoProvider>().isModuleAvailable(i)` |
| 8 | `bleProvider.getModuleStatus(i)` | 4 | `context.read<DeviceInfoProvider>().getModuleStatus(i)` |
| 9 | `bleProvider.sendStartJamCommand(...)` | 1 | `subGhz.sendStartJamCommand(...)` |
| 10 | `bleProvider.sendIdleCommand(...)` | 2 | `subGhz.sendIdleCommand(...)` |
| 11 | `bleProvider.sendRecordCommand(...)` | 1 | `subGhz.sendRecordCommand(...)` |
| 12 | `bleProvider.sendGetStateCommand()` | 3 | `context.read<DeviceInfoProvider>().requestGetState()` |
| 13 | `bleProvider.isConnected` | 5 | `context.read<ConnectionStateProvider>().isConnected` |
| 14 | `bleProvider.validateRecordConfig(config)` | 1 | Not on `SubGhzProvider` — needs inlining or adding |
| 15 | `final bleProvider = Provider.of<BleProvider>(...)` in action methods | 6 | `final subGhz = context.read<SubGhzProvider>()` |
| 16 | `Consumer<BleProvider>` in widget tree | ~15 | `Consumer<SubGhzProvider>` |
| 17 | Function signatures `(BleProvider bleProvider)` | 6 | `(SubGhzProvider subGhz)` |

**Root cause of previous failed attempt:** Blind `sed` replacement of `bleProvider` → `subGhz` throughout the 1,819-line file corrupted the Dart AST. The widget tree has ~15 `Consumer<BleProvider>` blocks where `bleProvider` is the **builder parameter name** used both for reading state AND as the variable name in surrounding widget expression code (lines 1300-1360). The replacement turned widget tree expressions into class-level declarations.

**Safe migration plan (3 passes):**

Pass 1 — **Field + lifecycle** (6 edits, low risk):
- Change `BleProvider? _bleProvider` to `SubGhzProvider? _subGhz`
- Update `didChangeDependencies`: `Provider.of<BleProvider>(...)` → `context.read<SubGhzProvider>()`
- Update `dispose`: `_bleProvider?.removeListener(...)` → `_subGhz?.removeListener(...)`
- Update listener methods: `_bleProvider?.recordedRuntimeFiles` → `_subGhz?.recordedRuntimeFiles`
- Update `_onModuleStateChanged`: `_bleProvider?.isModuleJamming(...)` → `_subGhz?.isJamming[...]`

Pass 2 — **Action methods** (~50 lines, medium risk):
- `_isModuleBusy`: `BleProvider` param → `SubGhzProvider` param, method calls → field/map access + `DeviceInfoProvider`
- `_startJamming`: `Provider.of<BleProvider>` → `context.read<SubGhzProvider>()`, `isConnected` → `ConnectionStateProvider`, `isModuleAvailable` → `DeviceInfoProvider`, `sendGetStateCommand` → `DeviceInfoProvider.requestGetState`
- `_startRecording`: Same pattern as `_startJamming` + `validateRecordConfig` inline
- `_stopJamming`: Same pattern
- `_startFrequencySearch` / `_stopFrequencySearch`: Same pattern

Pass 3 — **Widget tree** (~300 lines across 15+ consumers, high risk):
- Change `Consumer<BleProvider>` to `Consumer<SubGhzProvider>`
- Rename builder parameter from `bleProvider` to `subGhz`
- Replace `bleProvider.isModuleRecording(i)` with `subGhz.isRecording[i] ?? false`
- Replace `bleProvider.isModuleJamming(i)` with `subGhz.isJamming[i] ?? false`
- Replace `bleProvider.isModuleFrequencySearching(i)` with `subGhz.isFrequencySearching[i] ?? false`
- Replace `bleProvider.getModuleStatus(i)` with `context.read<DeviceInfoProvider>().getModuleStatus(i)`
- Replace `bleProvider.cc1101Modules` with `context.read<DeviceInfoProvider>().cc1101Modules`
- Replace `bleProvider.recordedRuntimeFiles` with `subGhz.recordedRuntimeFiles`
- Replace `bleProvider.detectedSignals` with `subGhz.detectedSignals`
- Replace `bleProvider.isConnected` with `context.read<ConnectionStateProvider>().isConnected`

---

## 4. Milestone: Screen File Splitting (Pragmatic, Not Dogmatic)

**Goal:** Reduce large screens to manageable size with clear responsibilities.

**Note on line counts:** The 500-line rule is a heuristic, not a law. A 450-line screen with 3 well-defined sections is preferable to a 350-line screen + 200-line sub-widget with excessive widget tree depth and indirection. Split files when the split adds clarity, not just to hit a line count.

### 4.1 `settings_screen.dart` (4,536 lines → ~3 sub-files)

Keep `_SettingsScreenState` as the scroll container that builds sections. Split into:
- `settings/sections/device_info_section.dart` (~400 lines) — battery, temp, firmware, HW buttons
- `settings/sections/radio_section.dart` (~400 lines) — CC1101 power, frequency calibration
- `settings/sections/wifi_section.dart` (~250 lines) — AP config
- `settings/sections/system_section.dart` (~300 lines) — device name, factory reset, format SD, about

**Target main file:** ~400 lines (the scroll container + section dispatch)

**Data flow for all screen splits — choose one:**

| Option | Data Access | Mobile Impact | When to Use |
|--------|-------------|---------------|-------------|
| **A** `context.read<T>()` | Each sub-widget uses `context.read<DeviceInfoProvider>()` directly | ✅ Lowest memory — providers are already in memory, no extra copies | **Recommended.** Default for all splits. |
| **B** `Consumer<T>` wrappers | Parent screen wraps child in `Consumer<SubGhzProvider>` | ⚠️ More rebuilds, but localized. Acceptable for deeply nested widgets that need frequent updates. | Use for a widget that updates at >10Hz (spectrum, jammer visualizer) where `ListenableBuilder` is too verbose. |
| **C** Constructor prop-drilling | Parent passes `final SubGhzProvider provider` down | ❌ Avoid. Adds boilerplate, increases widget tree size, harder to test. | Only if the sub-widget is genuinely reusable across screens and shouldn't be coupled to `Provider`. |

**Decision for this codebase:** Use **Option A** (`context.read<T>()`) for all sub-widgets. The only exceptions are high-frequency widgets (spectrum, jammer) which use **Option B** with `Consumer<T>` or `Selector<T, R>` to prevent full rebuilds.

```dart
// RECOMMENDED: Option A — sub-widget reads directly
class DeviceInfoSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final deviceInfo = context.read<DeviceInfoProvider>();
    return Column(...);
  }
}

// For high-frequency updates: Option B with Selector
class SpectrumTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<NrfProvider, List<int>>(
      selector: (_, provider) => provider.nrfSpectrumLevels,
      builder: (_, levels, __) => CustomPaint(
        painter: SpectrumPainter(levels),
      ),
    );
  }
}
```

**Mobile resource justification:** `context.read<T>()` is a single hashmap lookup — ~100ns, no memory allocation. `Selector` caches its selector result and only rebuilds when the extracted value changes. This avoids the memory bloat of prop-drilling and the CPU cost of `Consumer` on the entire subtree.

### 4.2 `nrf_screen.dart` (1,546 lines → 3 sub-files)

Keep `_NrfScreenState` as the tab controller. Extract:
- `nrf/tabs/mousejack_tab.dart` (~400 lines)
- `nrf/tabs/spectrum_tab.dart` (~300 lines) — includes `_SpectrumPainter`
- `nrf/tabs/jammer_tab.dart` (~350 lines)

**Target main file:** ~300 lines

### 4.3 `record_screen.dart` (1,819 lines → 2 sub-files)

- `record/record_config_panel.dart` (~500 lines) — frequency, modulation, presets, advanced
- `record/record_file_list.dart` (~300 lines) — recorded files list

**Target main file:** ~500 lines (tab controller + layout)

### 4.4 `files_screen.dart` (1,360 lines → 2 sub-files)

- `files/files_file_list.dart` (~500 lines) — the main file list with navigation
- `files/files_actions.dart` (~400 lines) — copy, move, rename, delete, create directory

**Target main file:** ~400 lines

### 4.5 `brute_screen.dart` (1,362 lines → 2 sub-files)

- `brute/brute_protocol_grid.dart` (~500 lines) — protocol categories, De Bruijn
- `brute/brute_progress_panel.dart` (~400 lines) — progress bar, stats, pause/resume

**Target main file:** ~400 lines

### 4.6 `protopirate_screen.dart` (1,309 lines → 2 sub-files)

- `protopirate/protopirate_decode_panel.dart` (~500 lines) — frequency, decode, results
- `protopirate/protopirate_emulate_panel.dart` (~400 lines) — emulate + save

**Target main file:** ~350 lines

### 4.7 `file_viewer_screen.dart` (936 lines → 2 sub-files)

- `file_viewer/file_viewer_hex.dart` (~400 lines)
- `file_viewer/file_viewer_text.dart` (~300 lines)

**Target main file:** ~200 lines (tab controller for hex/text toggle)

### 4.8 Remaining widgets >500 lines

| File | Current Lines | Action |
|------|--------------|--------|
| `status_bar_widget.dart` | 760 | Keep as-is for now; screen splitting will reduce its usage. If still >500 after screen refactors, split by section. |
| `record_screen_widgets.dart` | 716 | Will be significantly reduced once `record_screen.dart` is split; revisit afterward. |
| `module_status_widget.dart` | 501 | Split into `module_status_basic.dart` + `module_status_expanded.dart` if needed. |

---

## 5. Milestone: Delete `BleProvider`, Verify, Clean Up

**Goal:** Remove the god object once all its consumers are migrated.

### 5.1 Delete `ble_provider.dart`
Only delete after every consumer has been moved to new providers. This is the final step.

### 5.2 Run diagnostics
```bash
flutter analyze
make apk
```
Fix any remaining references to `BleProvider`.

### 5.3 Verify both transport paths work
- BLE: Connect via BLE, test Sub-GHz record, NRF scan, Files list, Settings
- WiFi: Connect via WiFi, test the same — this validates the entire refactor goal

### 5.4 Handle SharedPreferences

The SharedPreferences-based device cache (known device IDs, temp offsets) currently lives in `BleProvider` (`_loadKnownDevice`, `saveKnownDevice`, `_clearKnownDevice`, `_deviceIdKey`, `_knownDeviceId`).

Move this to a dedicated `DevicePreferencesService`:
```dart
class DevicePreferencesService {
  Future<String?> getSavedDeviceId();
  Future<void> saveDeviceId(String id);
  Future<void> clearDeviceId();
  Future<double> getTempOffset();
  Future<void> setTempOffset(double offset);
}
```
`BleConnectionProvider` (or the existing `BleProvider` if kept) uses this service instead of inline SharedPreferences calls.

---

## Appendix: Open Design Decisions

### D1. Do we keep `BleProvider` as a wrapper during transition?

**Option A:** Keep `BleProvider` alongside new providers until migration is complete. It wraps `BleConnectionProvider` + all module providers, delegating calls. Pros: incremental, safe. Cons: `BleProvider` still exists during transition.

**Option B:** Delete `BleProvider` immediately and let new providers fill the gap. Pros: cleaner, forces complete migration. Cons: risky if something is missed.

**Recommendation:** Option A with a deprecation timeline. Mark `BleProvider` as `@deprecated` and have it delegate to new providers. Delete in Milestone 5.

### D2. Callback ownership (`setLogCallback`, `setNotificationCallback`)

Currently:
- `BleProvider.setLogCallback(fn)` — external (HomeScreen) sets a callback on BleProvider
- `BleProvider.setNotificationCallback(fn)` — external sets a callback on BleProvider

New model:
- `LogProvider` and `NotificationProvider` are already separate providers
- `ConnectionProvider` (and its BLE/WiFi implementations) should **not** hold these callbacks
- Instead, `ConnectionProvider` dispatches log/notification events through the `MessageDispatcher`
- `LogProvider` subscribes to `MessageDispatcher.messages` and filters for log events
- `NotificationProvider` subscribes similarly for user-facing notifications
- Screens set callbacks on `LogProvider`/`NotificationProvider`, not on connection providers

### D3. How does a screen send a command?

**Current:**
```dart
bleProvider.sendBinaryCommand(cmd);
```

**New (two options):**

Option A — Module providers own sending:
```dart
context.read<SubGhzProvider>().sendRecordCommand(...);
```

Option B — Centralized command bus:
```dart
connection.sendCommand(cmd); // any provider or screen can call
```

**Recommendation:** Option A. Each module provider exposes high-level methods (`sendRecordCommand`, `createNrfAttackStringCommand`, etc.) that internally call `connection.sendCommand()`. Screens never call `connection.sendCommand()` directly — they go through the module provider. This keeps command construction logic in module providers where it belongs.

### D4. OTA state machine

The OTA flow has 6 distinct states:
```
idle → uploading → rebooting → waitingReconnect → complete/error
```

Implement as a proper state machine in `OtaProvider`:
```dart
enum OtaState { idle, uploading, rebooting, waitingReconnect, complete, error }

class OtaProvider extends ChangeNotifier {
  OtaState _state = OtaState.idle;
  OtaState get state => _state;

  void transition(OtaState newState) {
    _state = newState;
    notifyListeners();
  }
}
```

The `_otaRebootPending`, `_otaPreRebootVersion`, `_otaReconnectTimer` fields in the old BleProvider map directly to `OtaState.rebooting` and `OtaState.waitingReconnect` states.

### D5. WiFi Provisioning from the Mobile App

**Firmware behavior (already implemented):**

On boot without saved credentials, the device immediately starts **SoftAP** mode and simultaneously listens for **SmartConfig (ESP-TOUCH)** in the background. This means:
- The device's WiFi network is visible within ~1 second of boot — phone can connect directly
- If the user opens an ESP-TOUCH provisioning app and sends credentials, the device picks them up and switches to STA mode

**Provisioning flow:**
```
Device boots
  ├─ Saved STA credentials exist → connect to home WiFi
  │     └─ Success → mDNS + WebSocket + REST API available
  └─ No credentials / connection fails → SoftAP + background SmartConfig
        ├─ Phone connects to device's WiFi (e.g. "EvilCrow_RF2-Config")
        │     └─ Captive portal at 192.168.4.1 → enter home WiFi credentials
        │           └─ Device saves to NVS, switches to STA mode
        └─ Phone sends credentials via ESP-TOUCH (optional)
              └─ Device receives in background, saves, switches to STA
```

**App-side provisioning — new feature plan:**

The app needs three provisioning entry points, all of which send ESP-TOUCH broadcasts to configure the device without the user needing to join the device's SoftAP network:

| Entry Point | Location | User Flow |
|------------|----------|-----------|
| **Quick Connect** | `widgets/quick_connect_widget.dart` | User opens app, sees "No device found" → tap "Provision WiFi" → enters SSID/password → app sends ESP-TOUCH |
| **Settings > WiFi** | `screens/settings_screen.dart` (WiFi section) | Already connected? Send new credentials. Not connected? Same ESP-TOUCH flow as Quick Connect. |
| **Home Page banner** | `screens/home_screen.dart` | When `ConnectionStateProvider.isConnected == false` for >5s and BLE scan finds nothing, show a banner: "No device found — tap to configure WiFi" |

**New files to create:**

| File | Purpose | Lines |
|------|---------|-------|
| `services/wifi_provisioning_service.dart` | Encodes SSID/password as ESP-TOUCH UDP broadcast packets, sends over WiFi | ~150 |
| `widgets/provision_wifi_dialog.dart` | Reusable dialog: SSID input, password input, "Send" button with progress indicator | ~120 |

**Required dependencies:**

This requires a Flutter ESP-TOUCH plugin. Two options:

| Option | Package | Pros | Cons |
|--------|---------|------|------|
| **A** | [`esp_touch_flutter`](https://pub.dev/packages/esp_touch_flutter) | Wraps Espressif's ESP-TOUCH SDK natively (Android + iOS) | Larger APK, platform-specific native code |
| **B** | Manual UDP broadcast | No native dependencies, pure Dart | Only works if phone is on 2.4 GHz WiFi, less reliable |

**Recommendation:** Use **Option A** for reliability, with **Option B** as a fallback if the native plugin fails. This matches what the firmware expects (ESP-TOUCH packet sniffing in promiscuous mode).

**`WifiProvisioningService` API:**
```dart
class WifiProvisioningService {
  /// Send ESP-TOUCH credentials via UDP broadcast.
  /// [ssid] - The 2.4 GHz WiFi SSID.
  /// [password] - The WiFi password (may be empty for open networks).
  /// Returns true if the packet was sent successfully.
  Future<bool> provision(String ssid, String password);

  /// Listen for a device to appear on the network after provisioning.
  /// Polls mDNS or IP subnet for up to [timeout].
  /// Returns the device's IP or null.
  Future<String?> waitForDevice({Duration timeout = const Duration(seconds: 30)});
}
```

**`ProvisionWifiDialog` widget:**
```dart
// Shows a dialog prompting for WiFi credentials and sends via ESP-TOUCH.
// Usage:
//   final result = await ProvisionWifiDialog.show(context);
//   if (result != null) {
//     // Device provisioned, now connect via WifiProvider
//   }
class ProvisionWifiDialog extends StatefulWidget { ... }
```

**Wiring into existing screens:**

1. `QuickConnectWidget` — add a "Provision New Device" button below the scan results list. Tapping it opens `ProvisionWifiDialog`. On success, auto-connect via `WifiProvider.connect(ip)`.

2. `SettingsScreen` WiFi section — add "Provision WiFi" button that opens `ProvisionWifiDialog`. This is useful when the user already has a device but wants to move it to a different network.

3. `HomeScreen` — add a `Consumer<ConnectionStateProvider>` that shows a persistent info banner when no device has been found for 5+ seconds. Banner says: "No EvilCrow RF device found. Tap to provision a new device over WiFi." Tapping opens `ProvisionWifiDialog`.

**Implementation order:**
```
1. Install esp_touch_flutter dependency in pubspec.yaml
2. Create WifiProvisioningService (wraps the plugin)
3. Create ProvisionWifiDialog (UI for SSID/password entry)
4. Update QuickConnectWidget — add provisioning button
5. Update settings_screen.dart WiFi section — add provisioning button
6. Update home_screen.dart — add provisioning banner
```

---

## Build Commands

```bash
cd /home/dev/src/EvilCrowRF-V2/mobile_app

# Check for compilation errors (fast)
flutter analyze

# Build Android APK
make apk

# Build Linux desktop
make linux-deps
make linux
```

---

## Success Criteria

1. **WiFi + all modules works**: User connects via WiFi, navigates to Sub-GHz/NRF/Files, and all work.
2. **BLE still works**: All features work over BLE as before.
3. **No god objects**: `BleProvider` is deleted; no other provider exceeds ~500 lines.
4. **Clean compilation**: `flutter analyze` reports zero errors.
5. **Message routing is clean**: Raw BLE/WiFi notifications flow through `MessageDispatcher` → module providers. No direct BLE characteristic handling outside `BleConnectionProvider`.
6. **OTAU works**: Firmware upload and reboot-reconnect works via `OtaProvider` state machine.

---

## 6. Fixes (Immediate Bugs & UX Improvements)

### F1. Module Providers Not Receiving Responses After WiFi Connect

**Symptoms:** WiFi discovery and WebSocket connection succeed, but Sub-GHz scanner shows "Module Busy", NRF scan shows no devices, and file list stays empty. BLE mode works fine.

**Root cause (fixed):** `WifiProvider._handleBinaryFrame()` was manually stripping the 7-byte binary protocol header from incoming frames before calling `FirmwareBinaryProtocol.parseResponse()`. But `parseResponse()` expects the **full frame with header** — it parses the header internally. The stripped payload (starting with `{` = 0x7b for JSON responses) failed the magic-byte check inside `parseResponse`, throwing `Invalid magic byte: 0x7b`. None of the responses were reaching `MessageDispatcher`, so no module provider state was updated.

**Fix:** Pass the full `data` frame to `parseResponse()` instead of the manually extracted payload, matching how `BleProvider` already calls it:
```dart
// Before (broken)
final payload = data.sublist(PACKET_HEADER_SIZE, PACKET_HEADER_SIZE + dataLen);
final parsed = FirmwareBinaryProtocol.parseResponse(Uint8List.fromList(payload));

// After (fixed — pass full frame, parseResponse handles header)
final parsed = FirmwareBinaryProtocol.parseResponse(Uint8List.fromList(data));
```

### F2. Bluetooth Icon Shown When Connected via WiFi

**Symptom:** The status bar or connection indicator always shows a Bluetooth icon even when the device is connected via WiFi.

**Root cause:** Several UI components hardcode the Bluetooth icon without checking which transport is active:

| File | Line(s) | Problem |
|------|---------|---------|
| `home_screen.dart` | `HomeTab` (line ~261) | `Icon(Icons.bluetooth_connected)` always shown when connected, regardless of transport |
| `status_bar_widget.dart` | Likely similar | Hardcoded BLE icon |
| `quick_connect_widget.dart` | Likely | Shows BLE scan results only, no WiFi option |

**Fix plan:**

1. Create a helper function or widget that returns the correct icon based on `ConnectionStateProvider.connectedTransport`:
   ```dart
   Widget _connectionIcon(BuildContext context) {
     final transport = context.watch<ConnectionStateProvider>().connectedTransport;
     switch (transport) {
       case 'ble': return const Icon(Icons.bluetooth_connected, color: AppColors.success);
       case 'wifi': return const Icon(Icons.wifi, color: AppColors.success);
       default: return const Icon(Icons.cloud_off, color: AppColors.error);
     }
   }
   ```

2. Update `home_screen.dart` HomeTab to use this instead of hardcoded `Icons.bluetooth_connected`.

3. Update `status_bar_widget.dart` to show the correct transport icon.

### F3. Persist Last Connection Method & Prepopulate Fields

**Symptom:** Every time the user opens the app, they must re-select connection method (BLE scan vs WiFi IP). No memory of the last successful connection.

**Fix plan — new `ConnectionHistoryService`:**

```dart
// services/connection_history_service.dart
class ConnectionHistoryService {
  static const _keyLastTransport = 'last_transport';  // 'ble' | 'wifi'
  static const _keyWifiHost = 'last_wifi_host';        // IP or FQDN
  static const _keyBleDeviceId = 'last_ble_device_id';

  /// Save the last successful connection details.
  static Future<void> saveConnection({
    required String transport,
    String? wifiHost,
    String? bleDeviceId,
  });

  /// Load the last transport method.
  static Future<String?> getLastTransport();

  /// Load the last WiFi host (IP/FQDN/mDNS).
  static Future<String?> getLastWifiHost();

  /// Load the last BLE device ID.
  static Future<String?> getLastBleDeviceId();

  /// Clear saved connection history.
  static Future<void> clear();
}
```

**Widget updates:**

| Widget | Change |
|--------|--------|
| `widgets/quick_connect_widget.dart` | On init, call `ConnectionHistoryService.getLastTransport()`. If `'wifi'`, show the IP/FQDN field prepopulated with the saved host and a "Connect" button. If `'ble'`, start BLE scan automatically. |
| `screens/settings_screen.dart` WiFi section | Prepopulate the IP/FQDN field with `ConnectionHistoryService.getLastWifiHost()`. |
| `WifiProvider.connect()` | On successful connection, call `ConnectionHistoryService.saveConnection(transport: 'wifi', wifiHost: host)`. |
| `BleProvider.connectToDevice()` | On successful connection, call `ConnectionHistoryService.saveConnection(transport: 'ble', bleDeviceId: device.id)`. |

**Connection button validation:**

The "Connect" button in both Quick Connect and Settings > WiFi should be:
- **Disabled** when IP/FQDN field is empty or contains only whitespace
- **Enabled** when field is non-empty (do NOT validate IP format — let the connection attempt fail gracefully)

```dart
// Pattern for all connection buttons
final canConnect = _hostController.text.trim().isNotEmpty;
ElevatedButton(
  onPressed: canConnect ? _connect : null,
  child: Text(l10n.connect),
)
```

### F4. Show Active Connection Details in Fields

**Symptom:** When already connected, Quick Connect and Settings show empty fields or stale data instead of the active device identity.

**Fix plan:**

When `ConnectionStateProvider.isConnected == true`, populate the corresponding fields with live data:

| Transport | Field | Value |
|-----------|-------|-------|
| WiFi | IP/FQDN | `WifiProvider.deviceHost` (the IP or hostname connected to) |
| WiFi | mDNS Hostname | `evilcrow_rf2.local` or whatever the device advertises |
| BLE | Device name | `BleProvider.deviceName` |

**Quick Connect widget** should:
1. Watch `ConnectionStateProvider.isConnected`
2. When connected via WiFi: show the active IP/hostname in the IP field (read-only style), disable the scan button, show a green "Connected" badge
3. When connected via BLE: show the device name, show a green "Connected" badge
4. When disconnected: restore editable fields, enable scan/connect buttons

**Settings > WiFi section** should:
1. Watch `ConnectionStateProvider`
2. When connected via WiFi: prepopulate IP/FQDN field with `WifiProvider.deviceHost`, show a "Connected" indicator
3. When not connected via WiFi: show the last saved host from `ConnectionHistoryService`

The pattern:
```dart
// Quick Connect or Settings > WiFi
final connectionState = context.watch<ConnectionStateProvider>();
final wifiProvider = context.watch<WifiProvider>();

// Prepopulate from live connection or history
final host = connectionState.isConnected && connectionState.connectedTransport == 'wifi'
    ? (wifiProvider.deviceHost ?? '')
    : _lastSavedHost;
_hostController.text = host;
```

**Implementation order for F3 + F4:**
```
1. Create ConnectionHistoryService (SharedPreferences-based, ~80 lines)
2. Wire saveConnection into WifiProvider.connect() success path
3. Wire saveConnection into BleProvider.connectToDevice() success path
4. Update QuickConnectWidget — prepopulate, validate, show live state
5. Update Settings > WiFi section — prepopulate, validate, show live state
6. Update HomeTab connection indicator — show correct transport icon
```