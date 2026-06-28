# EvilCrowRF V2 — Home Assistant Integration

Control and automate your EvilCrowRF V2 device directly from Home Assistant.
Capture, replay, and manage Sub-GHz RF signals through a clean HA interface.

## Features

- **Learn RF signals** — capture signals from any 315/433/868 MHz remote
- **Replay captured signals** — trigger garage doors, gates, lights, and more
- **Rename and organize** — rename `.sub` files with Flipper-compatible names
- **Scan for frequencies** — detect the strongest RF frequency in your area
- **FCC ID lookup** — automatically determine frequency from an FCC ID
- **Multi-device support** — control multiple EvilCrowRF devices (Phase 5)

## Requirements

- Home Assistant 2024.x or later
- An EvilCrowRF V2 device on the same network
- Python 3.13+
- [uv](https://docs.astral.sh/uv/) (for development)

## Quick Install (End User)

### Option 1: Manual Copy

1. **SSH into your Home Assistant server** or access the config filesystem.

2. **Copy the integration directory** into your HA config's `custom_components`:

   ```bash
   # If your HA config directory is /config
   cp -r custom_components/evilcrow_rf /config/custom_components/
   ```

3. **Restart Home Assistant**:

   ```
   Settings → System → Restart
   ```

4. **Add the integration**:

   ```
   Settings → Devices & Services → Add Integration → Search "EvilCrowRF V2"
   ```

   Enter the IP address (or FQDN) of your EvilCrowRF device. Default port is `80`.

### Option 2: Symlink (development / Docker volumes)

If you keep your HA config in a known location (e.g., `~/homeassistant`):

```bash
mkdir -p ~/homeassistant/custom_components
ln -s /path/to/hass/custom_components/evilcrow_rf ~/homeassistant/custom_components/
```

Then restart HA and add the integration.

## Development Setup

### Prerequisites

- Python 3.13+
- [uv](https://docs.astral.sh/uv/) (fast Python package manager)

### Quick Start

```bash
# 1. Clone the repo and enter the hass directory
cd hass

# 2. Create the virtual environment and install all dependencies
make dev-env

# 3. Symlink into your HA config directory
make install

# 4. Run tests
make test

# 5. Start HA in development mode
make run
```

### Common Makefile Targets

| Target | Description |
|---|---|
| `make dev-env` | Create `.venv` with all dependencies (uv sync) |
| `make install` | Symlink into `~/.homeassistant/custom_components` |
| `make uninstall` | Remove the symlink |
| `make reinstall` | Uninstall then install |
| `make test` | Run pytest with coverage |
| `make lint` | Run ruff linter |
| `make fmt` | Run ruff formatter |
| `make check` | Lint + format check + type check |
| `make typecheck` | Run basedpyright type checking |
| `make run` | Start HA in dev mode (filtered logs) |
| `make run-full` | Start HA in dev mode (unfiltered) |
| `make logs` | Tail HA logs filtered to the integration |
| `make clean` | Remove `.venv` and caches |

Override the HA config directory:

```bash
make HA_CONFIG_DIR=/config install
make HA_CONFIG_DIR=/config run
```

## Configuration

### `evilcrow_rf.yaml`

Lives in your HA config directory. Auto-created with defaults on first run.

```yaml
# FCC ID lookup endpoint (use {fcc_id} as placeholder)
fcc_api_endpoint: "https://fccid.io/{fcc_id}"

# Sample FCC ID used to validate the endpoint on reload
fcc_test_fcc_id: "2AAR8RESEARCH"

# Timeouts
request_timeout_seconds: 15
capture_timeout_seconds: 30

# Unknown signal exposure (Phase 5)
expose_unknown_min_occurrences: 3
expose_unknown_window_seconds: 60
```

### Per-Device Options

Configured through the HA UI:

```
Settings → Devices & Services → EvilCrowRF V2 → Configure
```

- **Monitoring**: Enable/disable continuous signal monitoring (Phase 5)
- **RSSI threshold**: Minimum signal strength to report
- **Unknown signal exposure**: Surface unrecognized signals as entities

## Usage

### Learning a Signal

1. Add an EvilCrowRF device via `Settings → Devices & Services`.
2. Click **"Add Target Remote"** on the device page.
3. Follow the wizard:
   - Name the remote (e.g., "Garage Door")
   - Enter the FCC ID (optional) or frequency directly
   - Select modulation (default: OOK_FIX)
   - Click **"Start Learning"** and press the remote button
   - Confirm the captured signal works

### Replaying a Signal

- **Service call**: `evilcrow_rf.replay_signal`
- **Button entity**: Press the "Play" button on the device page
- **Select entity**: Pick a `.sub` file from the dropdown, then press "Play"

### Renaming a Signal

Use the text entity on the device page to enter a new filename
(e.g., `Front_Door_Bell.sub`). The file is renamed on the device's SD card
and becomes visible from the mobile app.

### Scanning for Frequencies

Use the `evilcrow_rf.scan_frequency` service. The device listens on all
supported bands and reports the frequency with the strongest signal. Useful
for generic 433/315 MHz remotes without FCC IDs.

## Project Structure

```
hass/
├── custom_components/
│   └── evilcrow_rf/        # Integration source code
│       ├── __init__.py          # Component entry point
│       ├── manifest.json        # HA manifest
│       ├── config_flow.py       # Setup wizard
│       ├── const.py             # Constants
│       ├── coordinator.py       # Device state coordinator
│       ├── binary_protocol.py   # Binary frame protocol
│       ├── wifi_transport.py    # WebSocket transport
│       ├── subghz.py            # Capture/replay state machine
│       ├── services.py          # HA service definitions
│       ├── sensor.py            # Sensor entities
│       ├── button.py            # Button entities
│       ├── select.py            # Signal file selector
│       ├── text.py              # Signal rename input
│       ├── target_device_store.py  # RF remote persistence
│       ├── flipper_sub.py       # .sub file parser
│       ├── fcc_lookup.py        # FCC ID frequency lookup
│       ├── timeout_tracker.py   # Request timeout tracking
│       ├── device.py            # Device registry
│       ├── signal_monitor.py    # Continuous monitoring (Phase 5)
│       ├── smartconfig.py       # WiFi provisioning (Phase 5)
│       ├── models.py            # Shared dataclasses
│       └── yaml_config.py       # YAML config loader
├── tests/                      # Pytest test suite
├── docs/
│   └── plan.md                 # Full implementation plan
├── Makefile                     # Developer targets
├── pyproject.toml               # UV project config
└── pyrightconfig.json           # Type checker config
```

## Phase Status

| Phase | Component | Status |
|---|---|---|
| **1** | Foundation (transport, protocol, coordinator) | ✅ Complete |
| **2** | Config flow, FCC lookup, YAML config | ✅ Complete |
| **3** | Capture/replay, services, entities, wizard | ✅ Complete |
| **4** | Makefile, tests, developer experience | ✅ Complete |
| **5** | Firmware-dependent features (monitoring, SmartConfig, UUID sync) | 🔜 Planned |
| **6** | Polish, diagnostics, edge cases | 🔜 Planned |

## License

See the repository root for license information.
