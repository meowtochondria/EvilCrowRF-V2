# Agent Preferences — EvilCrowRF V2

This file captures working preferences for AI coding agents on this project.
Keep it updated with any changes to how you want work done.

## Project Structure

- **Firmware**: `/firmware/` — ESP32 C++ (PlatformIO)
- **Mobile app**: `/mobile_app/` — Flutter/Dart
- **All code lives in this single repo** — no separate submodules or external SDK paths

## Communication Style

- Be concise and direct. Skip intros, summaries, and explanations of what you're about to do — just do it.
- Ground every claim in the actual codebase. Don't guess file paths or API signatures.
- If something is wrong or risky, say so plainly. Don't soften it.

## Architecture (App)

- The app uses **Provider** for state management (`ChangeNotifierProvider`, `context.read<>`, `context.watch<>`).
- Responses from the device flow through a two-layer routing model:
  - **Layer 1**: `MessageDispatcher` — broadcasts parsed `Map<String, dynamic>` firmware responses to all module providers.
  - **Layer 2**: `AppEventBus` — typed event bus for cross-provider domain events.
- Module providers (DeviceInfoProvider, SubGhzProvider, NrfProvider, FilesProvider, BruterProvider, OtaProvider) each subscribe to `MessageDispatcher.messages` and filter by `msg['type']`.
- BleProvider is a legacy god-object (5124 lines) being phased out. It coexists during transition (Option A). New code should use the new providers.
- BleProvider has a `messageDispatcher` field set externally. When set, `_handleCompleteResponse` forwards parsed responses to it.
- WifiProvider similarly has a `messageDispatcher` field. Its `_handleBinaryFrame` dispatches through it.
- All module providers have a `sendCommand` callback typed as `Future<bool> Function(Uint8List command, {bool withoutResponse})?`. Supports `withoutResponse: true` for fast BLE writes (OTA, chunked uploads).
- `ConnectionStateProvider` wraps both BleProvider and WifiProvider for unified `isConnected` / `connectedTransport`.

## Architecture (Firmware)

- ESP32 Arduino framework (not ESP-IDF directly).
- Uses NimBLE for BLE (lightweight, saves ~30-40KB RAM).
- Both BLE and WiFi transports share `BinaryProtocolHandler` for chunked binary framing.
- Binary protocol: Magic 0xAA, header (7 bytes), payload, XOR checksum.
- Response types: 0x80-0xFF (binary events like SignalRecorded, NrfDeviceFound, etc.).
- WiFi credentials stored in NVS (Preferences), not in config.txt.
- SoftAP starts immediately on boot. Captive portal and DNS server were removed — the app connects directly.
- Button 2 defaults to `WiFiSoftAP` action. Button 1 defaults to `None`.
- GPIO34/35 are input-only (no internal pull-up). External pull-up resistors required.

## Memory Constraints

- Running on a 16GB machine. System processes can get OOM-killed.
- No more than 2 sub-agents at a time. Prefer doing work directly rather than spawning.
- Avoid large parallel terminal commands. Run one build/analysis at a time.

## Preferred Workflow

1. **Read first, act second** — always read the relevant code before making changes.
2. **Verify with diagnostics tool** — after every batch of changes, call the `diagnostics` tool (no path argument) to check for errors project-wide. This catches issues that `flutter analyze` sometimes misses.
3. **Then run `flutter analyze`** as a secondary check if diagnostics is clean.
4. **Small, focused changes** — one file/task at a time. Don't batch unrelated changes.
5. **Match existing patterns** — don't introduce new architectural patterns unless the change explicitly calls for it.
6. **Don't fix unrelated bugs** — if you find a pre-existing issue, mention it but don't fix it unless asked.
7. **Don't commit** — the user commits manually. Just make the code changes.

## Refactor Progress

The canonical plan lives at `mobile_app/docs/refactor.md`.

| Milestone | Status |
|-----------|--------|
| M0: HomeScreen bug fix | ✅ Done |
| M1: Connection abstraction & event bus | ✅ Done |
| M2: Module provider extraction | ✅ Done (6 of 6) |
| M3: Update consumers | ✅ Done. record_screen fully migrated off BleProvider (3-pass strategy from §3.5). settings_screen migration deferred — still uses BleProvider for ~30 fields. |
| M4: Screen file splitting | 🔄 Partially done. settings_screen split into `screens/settings/about_popup.dart` (612 lines) + `screens/settings/subghz_clone_dialog.dart` (530 lines). settings_screen went 4536 → 3404 lines. nrf/record/files/brute/protopirate/file_viewer splits not yet started. |
| M5: Delete BleProvider | ❌ Not started — blocked on settings_screen migration (BleProvider still owns ~15 settings fields) |
| DevicePreferencesService (§5.4) | ✅ Done |
| F1: Module parse fix | ✅ Done |
| F2: Bluetooth/WiFi icon | ✅ Done — status_bar + quick_connect_widget now use ConnectionStateProvider. Disabled icons muted when the other transport is connected. |
| F3: Persist last connection method | ✅ Done — `ConnectionHistoryService` wired into WifiProvider.connect and BleProvider.connectToDevice success paths. |
| F4: Show active connection details in fields | ✅ Done — QuickConnectWidget prepopulates IP from history and shows live WifiProvider.deviceHost when connected. |
| D5: WiFi Provisioning | ❌ Not started — needs ESP-TOUCH plugin + app UI; deferred. |

Consult `refactor.md` before making architectural decisions.

## Testing

No automated tests exist. Validation is done via `flutter analyze` (app) and build checks.

## Progress Notes (2026-06-16 session)

Work completed in this session toward implementing `mobile_app/docs/refactor.md`:

### F2 — Bluetooth icon when WiFi active
- `status_bar_widget.dart`: BLE/WiFi icons now muted (not red) when the other transport is connected.
- `quick_connect_widget.dart`: was already correct (separate BLE/WiFi sections); no change needed.

### F3 — Persist last connection
- New: `services/connection_history_service.dart` (SharedPreferences-backed).
- Wired into `WifiProvider.connect()` and `BleProvider.connectToDevice()` success paths.

### F4 — Active connection in fields
- `QuickConnectWidget` prepopulates the WiFi IP field from `ConnectionHistoryService` and shows the live `WifiProvider.deviceHost` when connected.

### M3 — record_screen migration
- 3-pass strategy from §3.5 of refactor.md completed.
- All `BleProvider` coupling (17 patterns) replaced with `SubGhzProvider`, `DeviceInfoProvider`, `ConnectionStateProvider`, `FilesProvider`.
- Added `SubGhzProvider.validateRecordConfig(RecordConfig)` (static, moved from BleProvider).
- Added `FilesProvider.saveFileToSignalsWithName(...)` (moved from BleProvider).
- record_screen.dart: 1819 lines, no BleProvider references.

### M4 — settings_screen split (partial)
- New: `screens/settings/about_popup.dart` (~612 lines) — extracted from `settings_screen.dart` L3429-4024.
- New: `screens/settings/subghz_clone_dialog.dart` (~530 lines) — extracted from `settings_screen.dart` L3408-3920.
- settings_screen.dart: 4536 → 3404 lines (-1132 lines).
- Public APIs added: `AboutPopup.show(context)`, `SubGhzCloneDialog.show(context, bleProvider)`.

### Remaining (out of scope for this session)
- M4: split nrf_screen, record_screen, files_screen, brute_screen, protopirate_screen, file_viewer_screen.
- M4: full settings_screen provider migration (BleProvider → SettingsProvider for ~15 settings fields).
- M5: delete `ble_provider.dart` after all consumers migrated.
- D5: WiFi Provisioning UI / ESP-TOUCH plugin integration.
