# EvilCrowRF-V2 → Home Assistant Integration Plan

## TL;DR

A custom_component is the right approach, and the existing `hass/custom_components/evilcrow_rf/` tree (~10k LOC, Phases 1–4 marked "Complete") is structurally correct (matches the `broadlink` / `rfxtrx` pattern). However, its binary protocol definitions and `/api/info` field expectations do **not** match the firmware actually running on the device — the code was written against an aspirational spec. Before it can capture and replay signals on real hardware, the protocol must be rewritten against `firmware/include/*.h` and `mobile_app/lib/providers/firmware_protocol.dart` (the source of truth).

**Decision (per user):** fresh start in a new folder `hass-evilcrow-rf/`, services + entities UX, Phase 0 (capture/replay end-to-end) + Phase 1 (wizard/notifications/reauth). The existing tree is mined for reusable ideas (config-flow shape, `.sub` parser, fccid.io scraper, state-machine design) but the wire format is rebuilt from scratch against the real firmware.

---

## 1. How other HA RF integrations do this

| Integration | Transport | Protocol | UX pattern |
|---|---|---|---|
| `broadlink` | TCP socket (LAN) | Length-prefixed binary | `remote.send_command` service + per-entity learn/replay |
| `rfxtrx` | USB serial | Async serial | `send_command` service + event bus for received frames |
| `xiaomi_miio` | UDP (LAN) | Encrypted JSON-RPC | Service calls + auto-discovered entities |
| `telldus` | HTTPS (cloud) | REST | Service calls |
| `flipper` (community) | MQTT bridge | MQTT pub/sub | Topics per remote |
| `evilcrow_rf` (new) | WebSocket LAN | Binary frames `0xAA \| type \| chunkId \| chunkNum \| total \| len \| data \| xor` | Services + per-button Button entities |

The pattern being followed (one `ConfigEntry` per device → `DataUpdateCoordinator` → `aiohttp` WebSocket client → frame codec → state machine → HA services + entities) is the standard, lowest-friction way to add a non-MQTT, non-cloud RF device to HA.

---

## 2. Existing state of the repo (reference only)

`hass/custom_components/evilcrow_rf/` contains:

- `binary_protocol.py`, `wifi_transport.py`, `coordinator.py`
- `subghz.py` (capture/replay state machine + wizard)
- `services.py` (11 services: `learn_signal`, `replay_signal`, `confirm_capture`, `cancel_capture`, `rename_signal`, `delete_signal`, `refresh_files`, `scan_frequency`, `start_monitoring`, `stop_monitoring`, `start_wizard`)
- `sensor.py`, `button.py`, `select.py`, `text.py`
- `config_flow.py`, `target_device_store.py`, `fcc_lookup.py`, `flipper_sub.py`
- `timeout_tracker.py`, `notification_manager.py`, `smartconfig.py`, `signal_monitor.py`
- Tests: `test_binary_protocol.py`, `test_flipper_sub.py`, `test_timeout_tracker.py`
- `Makefile`, `pyproject.toml` (uv), `manifest.json`, `strings.json`, `translations/en.json`
- 2,831-line `plan.md`

Phases 1–4 are flagged "Complete". The code is structurally sound but its protocol definitions are fabricated — see §3.

---

## 3. Critical gap (why it doesn't work on your device today)

Verified by reading `firmware/include/RecorderCommands.h`, `TransmitterCommands.h`, `FileCommands.h`, `StateCommands.h`, `firmware/src/core/wifi/WifiAdapter.cpp`, and `mobile_app/lib/providers/firmware_protocol.dart`:

| Operation | Existing integration | Actual firmware | Mobile app canonical |
|---|---|---|---|
| Record | `0x09`, payload `(uint32 freq, u8 module, u8 preset)` | `0x08`, 68-byte struct: `(float32 freq, char preset[50], u8 module, u8 modulation, float32 deviation, float32 rxBandwidth, float32 dataRate)` | `MSG_REQUEST_RECORD = 0x08` |
| Transmit from file | `0x0B`, payload `(u8 pathLen, path)` | `0x07`, payload `(u8 pathLen, path, u8 pathType)` | `MSG_TRANSMIT_FROM_FILE = 0x07` |
| Idle | `0x03`, no payload | `0x03`, payload `(u8 module)` | matches (with module byte) |
| File list | `0xA0`, `(u8 pathLen, path)` | `0x05`, `(u8 pathLen, path, u8 pathType)` | `MSG_GET_FILES_LIST = 0x05` |
| Load file | `0xA5` | `0x09` | `MSG_LOAD_FILE_DATA = 0x09` |
| Remove file | (none) | `0x0B` | `MSG_REMOVE_FILE = 0x0B` |
| Rename file | `0xA4` | `0x0C` | `MSG_RENAME_FILE = 0x0C` |
| `/api/info` fields | `name`, `fw_version`, `fw_major`, `fw_minor`, `fw_patch`, `sd_present`, `nrf24_present`, `cc1101_count` | `device_name`, `fw_version`, `free_heap`, `uptime`, `transport`, `rssi` | n/a |

Response parsing is also stale — it handles `RESP_SIGNAL_DETECTED = 0x90` etc., but the firmware's file-list response `0xA1` is the **streaming** format `[0xA1][pathLen][path][flags][totalFiles:u16][fileCount][files...]` (`firmware/include/BinaryMessages.h:25`), not a plain newline list.

As written, the integration will connect (because `/api/ws` and `/api/info` exist) but every command frame will be silently ignored or misinterpreted.

---

## 4. Plan

### Phase 0 — Reconcile with the real protocol (no firmware changes)

The whole capture → replay loop works on stock firmware today; the existing component just has the wrong wire format. Rebuild `protocol.py` and `const.py` against `firmware/include/*.h` and `mobile_app/lib/providers/firmware_protocol.dart`:

1. Rewrite `const.py` command bytes to match the mobile app (`MSG_REQUEST_RECORD=0x08`, `MSG_TRANSMIT_FROM_FILE=0x07`, `MSG_GET_FILES_LIST=0x05`, `MSG_LOAD_FILE_DATA=0x09`, `MSG_REMOVE_FILE=0x0B`, `MSG_RENAME_FILE=0x0C`, `MSG_GET_STATE=0x01`, `MSG_REQUEST_IDLE=0x03`).
2. Rewrite command builders to emit the **exact** firmware payloads (`request_record` = 68-byte struct; `transmit_from_file` includes `pathType`; `rename_file` includes both path types; `idle` requires the module byte).
3. Rewrite `parse_response` to handle the streaming file-list format and signal-record/send response layouts in `firmware/include/BinaryMessages.h`.
4. Fix `transport.fetch_device_info` to read `device_name`/`fw_version`/`free_heap`/`uptime`/`rssi`. Drop `sd_present`/`nrf24_present`/`cc1101_count` from coordinator capabilities — derive SD presence lazily by probing `CMD_GET_FILES_LIST("/")`; CC1101 count is unknown until `CMD_GET_STATE` responds (deferred to Phase 3).
5. Update tests to round-trip the real payloads. Capture golden bytes via `tools/capture_frames.py` (see §6.1) and check them in under `tests/fixtures/captured_frames/`.

**Acceptance:** `evilcrow_rf.learn_signal` from Developer Tools captures a real remote button and `replay_signal` fires it back; `refresh_files` shows existing `.sub` files; `rename_signal` renames a file on the SD card.

### Phase 1 — UX hardening (no firmware changes)

6. **Config flow** — guided wizard: `STEP_USER` (host/port or zeroconf) → `STEP_FCC_TEST` (scrape fccid.io, "Revert to default" option) → `STEP_REGISTER` (name device, persist) → `STEP_OPTIONS` (post-setup: monitoring module, expose-unknown toggle, RSSI threshold, scan interval) → `STEP_RECONFIGURE` / `STEP_REAUTH`.
7. **Persistent notifications** — typed wrappers around `persistent_notification.create/dismiss` for the wizard, capture-timeout, version-mismatch, capture-confirm prompt, and onboarding (shown on first run when no targets are known). Namespaced notification IDs for easy dismissal.
8. **`ConfigEntryNotReady` on offline devices** — coordinator returns this on connect failure; verify reload behavior.
9. **Reconfigure / reauth flow** — `async_step_reauth` (if WebSocket disconnects 3× in 60 s, mark entry `SETUP_REAUTH`) and `async_step_reconfigure` (re-enter host/port without losing learned target store).
10. **`.sub` filename UX** — `TextRenameSignal` takes only the stem (no `.sub` suffix); rename service appends it. Matches Flipper conventions.
11. **Diagnostics** — `async_get_config_entry_diagnostics` returns redacted `/api/info`, last 20 captured frames, target-store snapshot.
12. **Repair issue** — `repairs.async_create_issue` when major firmware version != supported major; user can dismiss to continue.

### Phase 3 (deferred — firmware PRs required)

13. **Persistent UUID sync** (`CMD_HA_CONFIG_SYNC 0xD8` / `RESP_HA_CONFIG_SYNC 0xD9`) — write the HA-assigned UUID to `/config/ha_device_id` on the SD card so it survives resets and is stable across firmware updates.
14. **Continuous monitoring on the second CC1101** (`CMD_START_MONITOR 0x1B`) — passive listener mode that doesn't block the TX module. Surfaces button presses from physical remotes as HA events.
15. **SmartConfig WiFi provisioning** (`CMD_SMART_CONFIG 0xDC`) — ESP-TOUCH mode with `RESP_SMART_CONFIG_STATUS` frames.

Per `hass/docs/prompts.md` line 102, these stay at the end.

---

## 5. Layout (new folder `hass-evilcrow-rf/`)

```
hass-evilcrow-rf/
├── custom_components/
│   └── evilcrow_rf/
│       ├── __init__.py            # entry: setup/teardown, service registry
│       ├── manifest.json          # iot_class=local_push, zeroconf
│       ├── const.py               # CMD_*, RESP_*, services, attributes — single source of truth
│       ├── config_flow.py         # wizard: discover → FCC test → register → onboard
│       ├── coordinator.py         # DataUpdateCoordinator per device
│       ├── transport.py           # aiohttp WebSocket + /api/info
│       ├── protocol.py            # EvilCrowBinaryProtocol (frame codec + command builders + response parsers)
│       ├── device_info.py         # /api/info parser, capability detection, version check
│       ├── subghz.py              # capture/replay/rename/delete state machine
│       ├── signal_monitor.py      # passive RX (Phase 3 stub for now)
│       ├── target_store.py        # JSON-persisted learned remotes + buttons
│       ├── fcc_lookup.py          # configurable HTML scraper
│       ├── notifications.py       # HA persistent_notification wrapper
│       ├── entities/
│       │   ├── __init__.py
│       │   ├── sensor.py          # device status + capture state
│       │   ├── button.py          # Replay (per learned button) + Scan + Capture
│       │   ├── select.py          # signal file picker
│       │   └── text.py            # rename filename
│       └── services.yaml          # service definitions (loaded by HA from manifest)
├── tests/
│   ├── conftest.py
│   ├── test_protocol.py           # frame codec, all CMD_* round-trip, response parsing
│   ├── test_transport.py          # WebSocket connect/reconnect (mocked)
│   ├── test_subghz_state_machine.py
│   ├── test_fcc_lookup.py         # with frozen fccid.io HTML
│   ├── test_target_store.py
│   └── fixtures/
│       ├── captured_frames/       # real bytes from the device (see §6.1)
│       └── fccid_pages/
├── tools/
│   └── capture_frames.py          # one-shot CLI: connect → list files → record → dump bytes
├── docs/
│   ├── README.md
│   ├── protocol.md                # CMD/RESP table, payload layouts, examples
│   └── architecture.md
├── pyproject.toml                 # uv; dev deps = pytest, ruff, pytest-homeassistant-custom-component
├── Makefile                       # dev-env, lint, test, run, capture-frames, deploy
└── README.md
```

---

## 6. Implementation details

### 6.1 `tools/capture_frames.py` — capture real frames first

Before writing any protocol code, this one-shot CLI runs against the user's device to populate `tests/fixtures/captured_frames/` with golden bytes:

```bash
uv run python tools/capture_frames.py --host 192.168.x.x \
    --out tests/fixtures/captured_frames/ \
    --commands get-state,files-list,record,stop-record,idle
```

It connects via WebSocket, sends each command, captures the raw frames (header + payload + checksum), and writes them as `.bin` files alongside a `manifest.json` describing what they are. The test suite replays these bytes through `BinaryFrame.decode()` + `parse_response()` to lock in the wire format. If the firmware ever changes, re-running the capture shows the exact diff.

### 6.2 Protocol map (single source of truth — `const.py`)

```python
# Command bytes (from mobile_app MSG_*)
CMD_GET_STATE         = 0x01
CMD_REQUEST_SCAN      = 0x02
CMD_REQUEST_IDLE      = 0x03
CMD_GET_FILES_LIST    = 0x05
CMD_TRANSMIT_BINARY   = 0x06
CMD_TRANSMIT_FROM_FILE= 0x07
CMD_REQUEST_RECORD    = 0x08
CMD_LOAD_FILE_DATA    = 0x09
CMD_REMOVE_FILE       = 0x0B
CMD_RENAME_FILE       = 0x0C
CMD_GET_DIRECTORY_TREE= 0x14
CMD_SETTINGS_UPDATE   = 0xC1

# Responses (firmware/include/BinaryMessages.h)
RESP_SIGNAL_DETECTED     = 0x90   # RSSI int8
RESP_SIGNAL_RECORDED     = 0x91   # filename string
RESP_SIGNAL_SENT         = 0x92
RESP_SIGNAL_SEND_ERROR   = 0x93
RESP_FILE_LIST           = 0xA1   # streaming, see below
RESP_FILE_CONTENT        = 0xA0   # raw .sub bytes
RESP_FILE_ACTION_RESULT  = 0xA3
RESP_DEVICE_NAME         = 0xC8
RESP_SETTINGS_SYNC       = 0xC9
RESP_ERROR               = 0xF0
RESP_LOW_MEMORY          = 0xF1
RESP_COMMAND_SUCCESS     = 0xF2
RESP_COMMAND_ERROR       = 0xF3
```

### 6.3 Key payload layouts (must match firmware struct sizes)

- **Record (`CMD_REQUEST_RECORD`, 68 B)** — `(freq:float32, preset:char[50], module:u8, modulation:u8, deviation:float32, rxBandwidth:float32, dataRate:float32)`. **Float, not int Hz**; conversion `Hz = round(MHz * 1_000_000) / 1e6`.
- **Transmit from file** — `(pathLen:u8, path:bytes, pathType:u8)`. `pathType=0` (SD card path).
- **File list** — `(pathLen:u8, path:bytes, pathType:u8)`. Response is streaming: `0xA1 [pathLen][path][flags][totalFiles:u16][fileCount:u8][files...]`.
- **Rename** — `(fromLen:u8, from:bytes, toLen:u8, to:bytes)`.
- **Idle** — `(module:u8)` — required byte, not optional.

### 6.4 `/api/info` (WifiAdapter.cpp:193)

```json
{"device_name":"...", "fw_version":"3.0.0_wifi", "free_heap":12345,
 "uptime":678, "transport":"websocket", "rssi":-55}
```

`device_info.py` parses `fw_version` with regex `^(\d+)\.(\d+)\.(\d+)`. SD presence is detected lazily by trying `CMD_GET_FILES_LIST("/")`.

### 6.5 SubGhz state machine

`IDLE → RECORDING → RECORDED → REPLAYING_VERIFY → CONFIRMING → CONFIRMED/ERROR`. Each state has an explicit timeout (default 30 s) handled by a small `TimeoutTracker` dataclass (no external dep).

### 6.6 Target store

JSON at `<config_dir>/evilcrow_rf_targets.json`. Schema:

```json
{
  "<ec_device_id>": {
    "<target_device_id>": {
      "name": "Garage Door",
      "fcc_id": "...",
      "frequency_mhz": 433.92,
      "modulation": "OOK",
      "buttons": {"open": "/Garage/door_open.sub", "close": "/Garage/door_close.sub"}
    }
  }
}
```

Atomic write (`tmp` → `rename`).

### 6.7 FCC lookup

`fccid.io` scraper; endpoint and test ID live in `<config_dir>/evilcrow_rf.yaml`. If the scrape fails, surface a notification asking the user to enter the frequency manually.

### 6.8 Entities

- **`SensorDeviceStatus`** (enum: connected/disconnected/error) — diagnostic
- **`SensorCaptureState`** (enum: idle/capturing/recorded/confirming/confirmed/error) — diagnostic
- **`ButtonStartCapture`** — wired to `learn_signal` service, takes target/button name via extra fields
- **`ButtonReplay`** — one per **learned button** under each target device (dynamically added/removed as buttons are learned)
- **`SelectSignalFile`** — dropdown of `.sub` files on SD card; selecting + pressing `ButtonReplay` triggers `replay_signal`
- **`TextRenameSignal`** — filename input for renaming the selected file (stem only, `.sub` appended server-side)

### 6.9 Services (registered in `__init__.py`)

`learn_signal`, `confirm_capture`, `cancel_capture`, `replay_signal`, `rename_signal`, `delete_signal`, `refresh_files`, `scan_frequency`, `start_wizard`. Each looks up its coordinator via `hass.data[DOMAIN][ec_device_id]`.

---

## 7. Files to create (in order)

| Order | File | LOC est. | Depends on |
|---|---|---|---|
| 1 | `tools/capture_frames.py` | ~120 | — |
| 2 | `custom_components/evilcrow_rf/const.py` | ~120 | step 1 |
| 3 | `custom_components/evilcrow_rf/protocol.py` | ~400 | captured frames |
| 4 | `tests/test_protocol.py` + fixtures | ~300 + bin files | step 3 |
| 5 | `custom_components/evilcrow_rf/transport.py` | ~250 | step 3 |
| 6 | `tests/test_transport.py` | ~150 | step 5 |
| 7 | `custom_components/evilcrow_rf/device_info.py` | ~80 | step 1 |
| 8 | `custom_components/evilcrow_rf/coordinator.py` | ~180 | steps 5+7 |
| 9 | `custom_components/evilcrow_rf/target_store.py` + test | ~250 | — |
| 10 | `custom_components/evilcrow_rf/fcc_lookup.py` + test | ~250 | — |
| 11 | `custom_components/evilcrow_rf/subghz.py` + test | ~450 | steps 3+8+9 |
| 12 | `custom_components/evilcrow_rf/manifest.json` + `services.yaml` | ~150 | — |
| 13 | `custom_components/evilcrow_rf/__init__.py` | ~200 | steps 8+11+12 |
| 14 | `custom_components/evilcrow_rf/notifications.py` | ~100 | — |
| 15 | `custom_components/evilcrow_rf/config_flow.py` | ~400 | steps 8+10+14 |
| 16 | `custom_components/evilcrow_rf/entities/*.py` | ~500 | steps 8+11 |
| 17 | `docs/protocol.md`, `docs/README.md`, top-level `README.md` | ~300 | — |
| 18 | `pyproject.toml`, `Makefile` | ~150 | — |

**Total: ~4,000 LOC** (vs. ~10k in the abandoned tree) — small because we cut aspirational Phase 5 stubs and rewrite only what works on the current firmware.

---

## 8. Verification gates

| Gate | How to verify |
|---|---|
| Frame codec correct | `pytest tests/test_protocol.py` — every captured frame round-trips; builders produce byte-identical output to `tools/capture_frames.py` re-emit |
| Connect to device | `make run` → add integration → entry reaches `ConfigEntryState.LOADED` |
| Capture works | `evilcrow_rf.learn_signal` on a real remote → file appears in `SelectSignalFile`; replaying fires the device |
| Reconnect works | `ssh device reboot` → coordinator reconnects automatically; entries re-LOADED |
| Reauth works | change `host` on device → entry goes `SETUP_REAUTH`, reauth restores |
| Diagnostics | `…/api/diagnostics` returns redacted JSON |
| Lint/types/test | `make ci` clean |

---

## 9. Execution sequence

1. Build `tools/capture_frames.py`, run against your device, check the `.bin` fixtures in.
2. Write `const.py` and `protocol.py` against those bytes.
3. Lock in `test_protocol.py`.
4. Build out transport → coordinator → state machine → services → entities.
5. Add config flow + notifications + reauth + diagnostics.
6. Final pass: `make ci`, then `make run` and exercise the full user journey.