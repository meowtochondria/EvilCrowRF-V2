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

---

## 0. Pre-work: Fix the HomeScreen Bug (Immediate, Zero-Risk)

**Before any refactoring**, fix the connection check bug in `home_screen.dart`.

### Why this is zero-risk
This is a single-line addition to use `ActiveConnectionProvider` (or a simple helper) that wraps both BLE and WiFi providers.

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

Create `ConnectionStateProvider` (the simpler cousin of `ActiveConnectionProvider` — see Milestone 1) and update `HomeScreen`'s navigation guard to use it. This is a one-file, ~50-line provider that listens to both BLE and WiFi providers and exposes `isConnected`.

**Files touched:** `providers/connection_state_provider.dart` (new ~50 lines)

---

## 0b. Investigate "Modules Busy" — Is It a Real Bug?

Before touching architecture, determine whether "Sub-GHz modules are busy" is:

1. **An architectural issue** (screens using wrong provider — already identified above)
2. **A real SPI contention bug** (NRF24 and CC1101 share SPI; commands may race)
3. **Missing command queuing** (module A receives a command while still processing module B's previous command)
4. **A firmware-side issue** (firmware reports "busy" when SPI is locked)

### How to investigate

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

**Option A — Event Bus (simpler, recommended for this codebase):**
```
BLE/WiFi notification
  → ConnectionProvider parses header
  → ConnectionProvider emits raw payload on a stream (StreamController)
  → Each module provider subscribes to the stream and filters for its message types
```

**Option B — Router pattern (more explicit but more boilerplate):**
```
BLE/WiFi notification
  → ConnectionProvider parses header + routes to specific module provider's handler
  → Each module provider implements a `handleMessage(type, payload)` method
  → ConnectionProvider calls the correct handler based on message type
```

**Decision for this codebase:** Option A (Event Bus) is better because:
- Message types are already defined in `FirmwareBinaryProtocol` as `MSG_*` constants
- Each module provider only cares about a subset of messages
- Adding a new module doesn't require modifying `ConnectionProvider`
- Less boilerplate for a codebase of this size

**Implementation:**
```dart
// connection/message_dispatcher.dart
class MessageDispatcher {
  final StreamController<RawMessage> _controller = StreamController.broadcast();

  Stream<RawMessage> get messages => _controller.stream;

  // ConnectionProviders call this for every incoming notification
  void dispatch(Uint8List payload) {
    _controller.add(RawMessage(payload));
  }
}

class RawMessage {
  final Uint8List payload;
  final int messageType; // first byte of payload
  RawMessage(this.payload) : messageType = payload.isNotEmpty ? payload[0] : 0;
}
```

### 1.2 Create `ConnectionStateProvider` (~50 lines)

A lightweight `ChangeNotifier` that:
- Watches both `BleProvider` and `WifiProvider` via `addListener`
- Exposes `isConnected` (true if either is connected)
- Exposes `connectedTransport` ('ble' | 'wifi' | null)
- Exposes `deviceName`, `fwVersion` from the active transport

```dart
class ConnectionStateProvider extends ChangeNotifier {
  final BleProvider _ble;
  final WifiProvider _wifi;

  ConnectionStateProvider(this._ble, this._wifi) {
    _ble.addListener(_onChange);
    _wifi.addListener(_onChange);
  }

  bool get isConnected => _ble.isConnected || _wifi.isConnected;
  String? get connectedTransport => _ble.isConnected ? 'ble' : (_wifi.isConnected ? 'wifi' : null);
  String get deviceName => _ble.isConnected ? _ble.deviceName : _wifi.deviceName;

  void _onChange() { notifyListeners(); }
}
```

### 1.3 Extract `command_response_handler.dart` (~200 lines)

Extract from `BleProvider` the chunked response assembly logic (L1773-L1978 approximately):
- `_handleChunkedResponse`
- `_cleanupStaleChunkBuffers`
- `_chunkData`, `_expectedChunks`, `_receivedChunks` maps
- `_chunkStartTimes`, `_chunkLastReceived` maps
- Chunk timeout constants (`_chunkTimeout`, `_chunkStaleTimeout`)

This is the only BLE-specific chunking code that needs to be preserved. It's clean enough to extract and makes the subsequent transport split easier.

**This file is shared** between BLE and WiFi connection providers.

### 1.4 Create `BleConnectionProvider` (~300 lines) — Transport Only

Extract from `BleProvider`:
- BLE scanning (start/stop, scan results, permission handling)
- BLE device connection/disconnection
- Characteristic discovery and subscription setup
- Calling `MessageDispatcher.dispatch()` on incoming notifications
- Calling `_chunkData` assembly (via `CommandResponseHandler`)

**Does NOT contain:** any module logic, any response handlers beyond chunk assembly, any module state.

### 1.5 Create `WifiConnectionProvider` (~200 lines) — Transport Only

Refactor `WifiProvider` to:
- Use `MessageDispatcher` for incoming messages
- Use `CommandResponseHandler` for chunk assembly
- Expose `sendCommand(Uint8List)` via WebSocket

**Does NOT contain:** any module logic.

### 1.6 Delete or Integrate Dead `transport/` Code

The existing `transport/transport_layer.dart` with `ITransportLayer`, `BLEBinaryTransport`, `WifiWebSocketTransport`, and `TransportFactory` is **dead code** — never wired to the providers.

**Decision:** Delete it. The new `CommandResponseHandler` + `MessageDispatcher` approach is cleaner and better suited for this codebase. The existing transport abstractions were a prior attempted design that was abandoned.

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

Handles: Settings sync (when device connects, it pushes all device state). Subscribes to `MessageDispatcher` and filters for `MSG_VERSION_INFO`, `MSG_SETTINGS_SYNC`, `MSG_SETTINGS_UPDATE`, etc.

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

Subscribes to: `MessageDispatcher.messages` and filters for `MSG_REQUEST_RECORD`, `MSG_FREQUENCY_SEARCH`, `MSG_START_JAM`, `MSG_TRANSMIT_BINARY`, `MSG_TRANSMIT_FROM_FILE`, signal-related types (0x81, 0x82, etc.)

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

Subscribes to: File list messages (0xA1), file data chunks, error responses for file operations.

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

### 2.5 `BruterProvider` (~400 lines)

Extract from `BleProvider`:
- `isBruterRunning`, `bruterActiveProtocol`, `bruterCurrentCode`, `bruterTotalCodes`
- `bruterPercentage`, `bruterCodesPerSec`, `bruterDelayMs`, `bruterPower`, `bruterRepeats`
- `bruterSavedStateAvailable`, `bruterSavedMenuId`, `bruterSavedCurrentCode`, `bruterSavedTotalCodes`, `bruterSavedPercentage`
- `lastBruterCompletionStatus`, `lastBruterCompletionMenuId`
- `sendBruterCommand`, `sendBruterCancelCommand`, `sendBruterPauseCommand`, `sendBruterResumeCommand`
- `queryBruterSavedState`, `setBruterDelay`, `setBruterModule`, `_resetBruterState`
- `_handleBruterProgress`, `_handleBruterComplete`, `_handleBruterPaused`, `_handleBruterResumed`, `_handleBruterStateAvail`

Subscribes to: `MSG_BRUTER` messages.

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

Subscribes to: `MSG_OTA_BEGIN`, `MSG_OTA_DATA`, `MSG_OTA_END`, `MSG_OTA_STATUS`, `MSG_OTA_REBOOT`.

### 2.7 Cross-Provider State Synchronization

When `SubGhzProvider.startRecording()` is called, `DeviceInfoProvider` may need to know (`isRecording = true`). Define one of these patterns:

**Pattern A — Events (simplest for this codebase):**
```dart
// In SubGhzProvider
void startRecording() {
  _connection.sendCommand(FirmwareProtocol.createRequestRecordCommand(...));
  // Emit an event
  AppEvents.emit(SubGhzStartedRecording(moduleIndex: _selectedModule));
}

// In DeviceInfoProvider
class DeviceInfoProvider {
  DeviceInfoProvider() {
    AppEvents.on<SubGhzStartedRecording>((event) {
      _isModuleRecording[event.moduleIndex] = true;
      notifyListeners();
    });
  }
}
```

**Pattern B — Computed properties:**
`DeviceInfoProvider.isRecording` reads directly from `SubGhzProvider.isRecording`. Requires `context.read<SubGhzProvider>().isRecording`.

**Decision:** Pattern B (computed) is simpler for this codebase — it avoids introducing an event system. Module providers that need to know each other's state use `context.read` at build time, or subscribe to the other provider's `addListener` at init time.

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
kIdle → kUploading → kRebooting → kWaitingReconnect → kComplete/kError
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

The `_otaRebootPending`, `_otaPreRebootVersion`, `_otaReconnectTimer` fields in the old BleProvider map directly to `kRebooting` and `kWaitingReconnect` states.

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