"""Constants for the EvilCrowRF V2 integration."""

DOMAIN = "evilcrow_rf"
DEFAULT_NAME = "EvilCrowRF V2"
DEFAULT_PORT = 80
DEFAULT_SCAN_INTERVAL = 30
WS_PATH = "/api/ws"
INFO_PATH = "/api/info"
MAX_RECONNECT_DELAY = 300  # 5 minutes
REQUEST_TIMEOUT = 15  # generic request timeout
CAPTURE_TIMEOUT = 30  # state machine timeout for capture/replay
SUPPORTED_FW_MAJOR = 3  # firmware major version this integration was built against

# Integration YAML config (lives in <config_dir>/evilcrow_rf.yaml)
YAML_CONFIG_FILENAME = "evilcrow_rf.yaml"

# Binary protocol constants
BINARY_MAGIC = 0xAA
FRAME_TYPE_DATA = 0x01
FRAME_TYPE_ACK = 0x02
FRAME_TYPE_NAK = 0x03
MAX_PAYLOAD_SIZE = 500

# Message types (command → device).
# Values match firmware command handler registrations:
#   RecorderCommands.h, TransmitterCommands.h, FileCommands.h, StateCommands.h
CMD_GET_STATE = 0x01          # StateCommands::handleGetState
CMD_SCAN = 0x02               # StateCommands::handleRequestScan
CMD_IDLE = 0x03               # StateCommands::handleRequestIdle
CMD_FILE_LIST = 0x05          # FileCommands::handleGetFilesList
CMD_SEND_SIGNAL = 0x07        # TransmitterCommands::handleTransmitFromFile
CMD_START_RECORDING = 0x08    # RecorderCommands::handleRequestRecord
CMD_FILE_LOAD = 0x09          # FileCommands::handleLoadFileData
CMD_FILE_RENAME = 0x0C        # FileCommands::handleRenameFile
CMD_SETTINGS_UPDATE = 0xC1    # StateCommands::handleSettingsUpdate
CMD_START_MONITOR = 0x1B      # Phase 5: continuous listening on a dedicated CC1101 module
CMD_STOP_MONITOR = 0x1C       # Phase 5: stop the monitoring module
CMD_HA_CONFIG_SYNC = 0xD8     # Phase 5: ask device for its HA-assigned UUID (response 0xD9)
CMD_HA_SETTINGS_WRITE_SD = 0xDA  # Phase 5: write a key=value pair to /config/ on the SD card
CMD_SMART_CONFIG = 0xDC       # Phase 5: put device into SmartConfig WiFi provisioning mode

# SubGhz config commands (0x70-0x71) — Phase 8: key-value config
CMD_SUBGHZ_SET_CONFIG = 0x70
CMD_SUBGHZ_GET_CONFIG = 0x71

# SubGhz config keys (mirrors firmware SubGhzConfigCommands.h)
KEY_THRESHOLD_RSSI      = 0x01
KEY_HOPPER_FREQS        = 0x02
KEY_HOPPER_LINGER_RSSI  = 0x03
KEY_HOPPER_LINGER_TICKS = 0x04
KEY_HOPPER_ENABLED      = 0x05
KEY_DECODER_FILTER      = 0x06
KEY_DECODER_FILTER_RAW  = 0x07

# Message types (response → app, 0x80+).
# Values match firmware BinaryMessages.h enum BinaryMessageType.
RESP_SIGNAL_DETECTED = 0x90     # MSG_SIGNAL_DETECTED
RESP_SIGNAL_RECORDED = 0x91     # MSG_SIGNAL_RECORDED
RESP_SIGNAL_SENT = 0x92         # MSG_SIGNAL_SENT
RESP_SIGNAL_ERROR = 0x93        # MSG_SIGNAL_SEND_ERROR
RESP_SIGNAL_MONITOR = 0x95      # Phase 5: signal detected during continuous monitoring
RESP_FILE_CONTENT = 0xA0        # MSG_FILE_CONTENT
RESP_FILE_LIST = 0xA1           # MSG_FILE_LIST
RESP_FILE_ACTION = 0xA3         # MSG_FILE_ACTION_RESULT
RESP_VERSION_INFO = 0xC2        # MSG_VERSION_INFO
RESP_DEVICE_NAME = 0xC7         # MSG_DEVICE_NAME
RESP_SETTINGS_SYNC = 0xC0       # MSG_SETTINGS_SYNC
RESP_HA_CONFIG_SYNC = 0xD9      # Phase 5 (no firmware handler yet)
RESP_HA_SETTINGS_WRITE_SD_ACK = 0xDB  # Phase 5 (no firmware handler yet)
RESP_SMART_CONFIG_STATUS = 0xDD # Phase 5 (no firmware handler yet)

# Config flow steps
STEP_USER = "user"
STEP_MANUAL = "manual_device"
STEP_SMARTCONFIG = "smartconfig"
STEP_DISCOVERY = "discovery"
STEP_REGISTER = "register_device"
STEP_DEVICE = "device"
STEP_CAPTURE_SETUP = "capture_setup"
STEP_RECONFIGURE = "reconfigure"
STEP_OPTIONS = "options"
STEP_FCC_TEST = "fcc_test"

# Services
SERVICE_LEARN_SIGNAL = "learn_signal"
SERVICE_REPLAY_SIGNAL = "replay_signal"
SERVICE_CANCEL_CAPTURE = "cancel_capture"
SERVICE_CONFIRM_CAPTURE = "confirm_capture"
SERVICE_RENAME_SIGNAL = "rename_signal"
SERVICE_DELETE_SIGNAL = "delete_signal"
SERVICE_REFRESH_FILES = "refresh_files"
SERVICE_SCAN_FREQUENCY = "scan_frequency"
SERVICE_START_MONITORING = "start_monitoring"
SERVICE_STOP_MONITORING = "stop_monitoring"
SERVICE_START_WIZARD = "start_wizard"

# Number of registered services
NUM_SERVICES = 11

# Config entry versioning
CONFIG_ENTRY_VERSION = 1

# Target RF remote persistence (survives HA restarts)
TARGET_DEVICES_FILENAME = "evilcrow_rf_targets.json"

# Attributes
ATTR_DEVICE_ID = "device_id"
ATTR_FCC_ID = "fcc_id"
ATTR_FREQUENCY = "frequency"
ATTR_MODULATION = "modulation"
ATTR_BUTTON_NAME = "button_name"
ATTR_SIGNAL_FILE = "signal_file"
ATTR_NEW_NAME = "new_name"
ATTR_CONFIRMED = "confirmed"
ATTR_CANCEL = "cancel"
ATTR_NEXT_BUTTON = "next_button"
ATTR_TARGET_DEVICE_ID = "target_device_id"
ATTR_TARGET_DEVICE_NAME = "target_device_name"
ATTR_SCAN = "scan"
ATTR_STRONGEST_FREQUENCY = "strongest_frequency"
ATTR_EXPOSE_UNKNOWN = "expose_unknown"
ATTR_MONITOR_MODULE = "monitor_module"

# FCC ID lookup (default + integration YAML schema keys)
DEFAULT_FCC_API_ENDPOINT = "https://fccid.io/{fcc_id}"
CONF_FCC_API_ENDPOINT = "fcc_api_endpoint"
CONF_FCC_TEST_ID = "fcc_test_id"

# Config entry options (per-device, settable via Options flow)
CONF_MONITOR_ENABLED = "monitor_enabled"
CONF_MONITOR_MODULE = "monitor_module"
CONF_MONITOR_RSSI_THRESHOLD = "monitor_rssi_threshold"
CONF_EXPOSE_UNKNOWN = "expose_unknown"
CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES = "expose_unknown_min_occurrences"
CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS = "expose_unknown_window_seconds"

# Persistent notifications (used for timeout, version-mismatch, etc.)
NOTIFY_VERSION_WARNING = "evilcrow_rf_version_warning"
NOTIFY_CAPTURE_TIMEOUT = "evilcrow_rf_capture_timeout"
NOTIFY_SIGNAL_MONITOR = "evilcrow_rf_signal_monitor"
NOTIFY_ONBOARDING = "evilcrow_rf_onboarding"
NOTIFY_CONFIRM_CAPTURE = "evilcrow_rf_confirm_capture"
NOTIFY_WIZARD_STEP = "evilcrow_rf_wizard_step"
