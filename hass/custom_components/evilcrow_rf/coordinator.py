"""Device coordinator for EvilCrowRF V2 integration.

Follows HA's DataUpdateCoordinator pattern. One coordinator per device.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import timedelta
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .binary_protocol import EvilCrowBinaryProtocol
from .const import (
    CAPTURE_TIMEOUT,
    DEFAULT_SCAN_INTERVAL,
    DOMAIN,
    SUPPORTED_FW_MAJOR,
)
from .models import DeviceInfo
from .target_device_store import TargetDeviceStore
from .timeout_tracker import TimeoutTracker
from .wifi_transport import WiFiTransport

_LOGGER = logging.getLogger(__name__)


class EvilCrowCoordinator(DataUpdateCoordinator[dict[str, Any]]):
    """Coordinator for a single EvilCrowRF device.

    Responsibilities:
      - own the WiFiTransport + EvilCrowBinaryProtocol + TimeoutTracker
      - own the SubGhzService + SignalMonitor
      - run hass-config-sync on connect (assigns/persists device UUID)
      - run version negotiation on connect (warns on major mismatch)
      - dispatch incoming frames to the right local service via on_message
    """

    def __init__(
        self,
        hass: HomeAssistant,
        config_entry: ConfigEntry,
        device_info: DeviceInfo,
    ):
        self.hass = hass
        self.config_entry = config_entry
        self._device_info = device_info
        self._protocol = EvilCrowBinaryProtocol()
        self._transport = WiFiTransport(
            host=device_info.host,
            port=device_info.port,
            device_id=device_info.device_id,
        )
        self._tracker = TimeoutTracker(default_timeout=CAPTURE_TIMEOUT)
        self._subghz: Any | None = None  # SubGhzService — set after init
        self._signal_monitor: Any | None = None  # SignalMonitor — set after init
        self._reader_task: asyncio.Task[None] | None = None
        self._version_warning_dismissed: bool = False
        self._cancel_event = asyncio.Event()
        self._target_store: TargetDeviceStore | None = None
        self.notifier: Any | None = None  # NotificationManager — set after init

        super().__init__(
            hass,
            _LOGGER,
            name=f"{DOMAIN}_{device_info.device_id}",
            update_interval=timedelta(seconds=DEFAULT_SCAN_INTERVAL),
        )

    async def _async_update_data(self) -> dict[str, Any]:
        """Periodic poll — fetches /api/info, confirms liveness, and auto-refreshes
        the SD card file list."""
        try:
            info = await self._transport.fetch_device_info()
            if info is not None:
                # Update cached device info
                if self._device_info:
                    self._device_info.firmware_version = info.get(
                        "fw_version", self._device_info.firmware_version
                    )
                    self._device_info.fw_major = info.get("fw_major", self._device_info.fw_major)
                    self._device_info.fw_minor = info.get("fw_minor", self._device_info.fw_minor)
                    self._device_info.fw_patch = info.get("fw_patch", self._device_info.fw_patch)
                    self._device_info.name = info.get("name", self._device_info.name)
                    self._device_info.capabilities = {
                        "sd_present": info.get("sd_present"),
                        "nrf24_present": info.get("nrf24_present"),
                        "cc1101_count": info.get("cc1101_count"),
                    }
                # Refresh file list if SD card is present
                if info.get("sd_present") and self._subghz is not None:
                    try:
                        await self._subghz.refresh_files()
                    except Exception:  # noqa: BLE001
                        _LOGGER.debug("File list refresh during poll skipped")
            return self._device_info.__dict__ if self._device_info else {}
        except Exception as exc:
            raise UpdateFailed(f"Update failed: {exc}") from exc

    async def async_connect(self) -> bool:
        """Open transport, run hass-config-sync, negotiate version, start reader."""
        _LOGGER.debug("Connecting to EvilCrowRF device %s", self._device_info.device_id)
        connected = await self._transport.connect()
        if not connected:
            _LOGGER.warning("Failed to connect to device %s", self._device_info.device_id)
            return False

        # Phase 1-4: No hass-config-sync yet; device_id is the entry_id.
        # Version negotiation is optional in Phases 1-4.
        try:
            await self._negotiate_version()
        except Exception:  # noqa: BLE001
            _LOGGER.debug("Version negotiation skipped (device may not support CMD_GET_STATE)")

        _LOGGER.info("Connected to EvilCrowRF device %s", self._device_info.device_id)
        return True

    async def _negotiate_version(self) -> None:
        """Send CMD_GET_STATE and check version info.

        Logs a warning on major version mismatch.
        """
        try:
            frames = self._protocol.build_idle_command()
            await self._transport.send_frame(frames, timeout=5)
        except Exception:  # noqa: BLE001
            _LOGGER.debug("Version negotiation CMD_GET_STATE not supported on this firmware")
            return

        # Check if we have version info from /api/info
        info = self._transport.info
        if info:
            fw_major = info.get("fw_major", 0)
            if fw_major and fw_major != SUPPORTED_FW_MAJOR:
                _LOGGER.warning(
                    "Firmware version mismatch: device reports major=%d, "
                    "integration was built for major=%d. "
                    "Some features may not work correctly.",
                    fw_major,
                    SUPPORTED_FW_MAJOR,
                )

    async def async_disconnect(self) -> None:
        """Cancel reader + tracker, close transport. Idempotent."""
        await self._tracker.cancel_all()
        await self._transport.disconnect()

    @property
    def device_info(self) -> DeviceInfo:
        return self._device_info

    @property
    def transport(self) -> WiFiTransport:
        return self._transport

    @property
    def subghz(self) -> Any | None:
        return self._subghz

    @subghz.setter
    def subghz(self, value: Any) -> None:
        self._subghz = value

    @property
    def signal_monitor(self) -> Any | None:
        return self._signal_monitor

    @signal_monitor.setter
    def signal_monitor(self, value: Any) -> None:
        self._signal_monitor = value

    @property
    def target_store(self) -> TargetDeviceStore | None:
        return self._target_store

    @target_store.setter
    def target_store(self, value: TargetDeviceStore) -> None:
        self._target_store = value

    @property
    def fcc_lookup(self) -> Any | None:
        """Return the FCC lookup helper, if set."""
        return getattr(self, "_fcc_lookup", None)

    @fcc_lookup.setter
    def fcc_lookup(self, value: Any) -> None:
        self._fcc_lookup = value
