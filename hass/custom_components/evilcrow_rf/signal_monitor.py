"""Persistent RF signal monitoring for EvilCrowRF V2.

Phase 5 — firmware-dependent. Requires CMD_START_MONITOR (0x1B), CMD_STOP_MONITOR (0x1C),
and RESP_SIGNAL_MONITOR (0x95) on the device.
Phases 1-4 define the class structure but all monitoring operations are no-ops.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any

from homeassistant.core import HomeAssistant

_LOGGER = logging.getLogger(__name__)


@dataclass
class MonitorConfig:
    """Per-device monitoring configuration, persisted in config entry options."""

    enabled: bool = False
    module: int = 1  # which CC1101 module (0 or 1; default 1 = second module)
    rssi_threshold: int = -80  # dBm; signals below this are ignored
    expose_unknown: bool = False  # if True, create transient entities for unmatched signals
    expose_unknown_min_occurrences: int = 3  # minimum detections before surfacing unknown
    expose_unknown_window_seconds: int = 60  # time window (seconds) for counting occurrences


@dataclass
class DetectedSignal:
    """A signal detected by the monitoring module."""

    frequency: int  # Hz
    rssi: int  # dBm
    raw_key: str  # hex-encoded decoded key (e.g. "00 00 08 D0")
    protocol: int  # decoder protocol ID
    bit: int  # bit length
    detected_at: float  # time.monotonic()


class SignalMonitor:
    """Manages the persistent listening lifecycle for ONE EvilCrowRF device.

    Phase 5 implementation. In Phases 1-4, all operations are no-ops.
    """

    def __init__(
        self,
        transport: Any,
        protocol: Any,
        target_store: Any | None = None,
        hass: HomeAssistant | None = None,
    ):
        self._transport = transport
        self._protocol = protocol
        self._target_store = target_store
        self._hass = hass
        self._config = MonitorConfig()
        self._active: bool = False
        self._known_signals: dict[str, str] = {}  # raw_key -> target_device_id:button_name
        self._pending_unknown: list[DetectedSignal] = []
        self._update_lock = asyncio.Lock()

    async def start(self, frequency: float, *, config: MonitorConfig | None = None) -> bool:
        """Start persistent monitoring on the given frequency (MHz).

        Phase 5: Sends CMD_START_MONITOR (0x1B) with module, frequency (Hz),
        and RSSI threshold.

        Phases 1-4: no-op, returns False.
        """
        _LOGGER.debug(
            "SignalMonitor.start(%s) called — Phase 5 feature, not yet implemented",
            frequency,
        )
        return False

    async def stop(self) -> bool:
        """Stop monitoring.

        Phase 5: Sends CMD_STOP_MONITOR (0x1C).

        Phases 1-4: no-op, returns False.
        """
        _LOGGER.debug("SignalMonitor.stop() called — Phase 5 feature, not yet implemented")
        return False

    async def handle_signal(self, signal: DetectedSignal) -> None:
        """Route an incoming RESP_SIGNAL_MONITOR frame.

        Phase 5: Matches signal keys against known signals, updates entity state.

        Phases 1-4: no-op.
        """
        _LOGGER.debug("SignalMonitor.handle_signal() called — Phase 5 feature, not yet implemented")

    def rebuild_known_map(self) -> None:
        """Re-read TargetDeviceStore and rebuild the raw_key -> entity map.

        Called after a new signal is learned or a signal is renamed/deleted.
        """
        _LOGGER.debug(
            "SignalMonitor.rebuild_known_map() called — Phase 5 feature, not yet implemented"
        )

    @property
    def active(self) -> bool:
        return self._active

    @property
    def config(self) -> MonitorConfig:
        return self._config

    @config.setter
    def config(self, value: MonitorConfig) -> None:
        self._config = value
