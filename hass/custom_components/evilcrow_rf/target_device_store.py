"""Target RF remote persistence for EvilCrowRF V2 integration.

Learned signals and their button-to-file mappings are persisted in
<ha_config_dir>/evilcrow_rf_targets.json so they survive HA restarts.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import asdict, dataclass, field
from typing import Any

from homeassistant.core import HomeAssistant

from .const import TARGET_DEVICES_FILENAME

_LOGGER = logging.getLogger(__name__)

STORE_VERSION = 1


@dataclass
class TargetDevice:
    """A target RF remote being controlled."""

    target_device_id: str  # HA device registry ID
    name: str  # e.g. "Front Door"
    ec_device_id: str  # the EvilCrowRF device that learned this
    fcc_id: str | None = None
    frequency: float = 0.0  # MHz
    modulation: str = "OOK_FIX"
    buttons: dict[str, str] = field(default_factory=dict)  # button_name -> signal_file_path


class TargetDeviceStore:
    """Loads/saves target RF remote data to evilcrow_rf_targets.json.

    Writes are atomic: write to `.tmp`, then `os.replace()` to the target path.
    """

    def __init__(self, hass: HomeAssistant):
        self._hass = hass
        self._path = hass.config.path(TARGET_DEVICES_FILENAME)
        self._devices: dict[str, TargetDevice] = {}

    async def async_load(self) -> None:
        """Load target devices from JSON file."""
        try:
            data = await self._hass.async_add_executor_job(self._load_sync)
            if data is None:
                return
            if data.get("version") != STORE_VERSION:
                _LOGGER.warning(
                    "Target device store version %s != %s, ignoring",
                    data.get("version"),
                    STORE_VERSION,
                )
                return
            for device_data in data.get("devices", {}).values():
                device = TargetDevice(
                    target_device_id=device_data["target_device_id"],
                    name=device_data["name"],
                    ec_device_id=device_data["ec_device_id"],
                    fcc_id=device_data.get("fcc_id"),
                    frequency=device_data.get("frequency", 0.0),
                    modulation=device_data.get("modulation", "OOK_FIX"),
                    buttons=dict(device_data.get("buttons", {})),
                )
                self._devices[device.target_device_id] = device
        except (OSError, json.JSONDecodeError) as exc:
            _LOGGER.warning("Failed to load target device store: %s", exc)

    def _load_sync(self) -> dict[str, Any] | None:
        """Synchronous file load (runs in executor)."""
        if not os.path.exists(self._path):
            return None
        with open(self._path) as f:
            return json.load(f)

    async def async_save(self) -> None:
        """Save target devices to JSON file atomically."""
        await self._hass.async_add_executor_job(self._save_sync)

    def _save_sync(self) -> None:
        """Synchronous file save (runs in executor)."""
        data = {
            "version": STORE_VERSION,
            "devices": {device_id: asdict(device) for device_id, device in self._devices.items()},
        }
        tmp_path = self._path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, self._path)

    def get(self, target_device_id: str) -> TargetDevice | None:
        """Get a target device by ID."""
        return self._devices.get(target_device_id)

    def get_all_for_ec_device(self, ec_device_id: str) -> list[TargetDevice]:
        """Get all target devices for a given EvilCrowRF device."""
        return [d for d in self._devices.values() if d.ec_device_id == ec_device_id]

    def register(self, device: TargetDevice) -> None:
        """Register a new target device."""
        self._devices[device.target_device_id] = device

    def add_button(self, target_device_id: str, button_name: str, signal_file: str) -> None:
        """Add a button mapping to an existing target device."""
        device = self._devices.get(target_device_id)
        if device is not None:
            device.buttons[button_name] = signal_file

    def remove_button(self, target_device_id: str, button_name: str) -> None:
        """Remove a button mapping from a target device."""
        device = self._devices.get(target_device_id)
        if device is not None:
            device.buttons.pop(button_name, None)

    def remove_device(self, target_device_id: str) -> None:
        """Remove a target device entirely."""
        self._devices.pop(target_device_id, None)

    @property
    def all_devices(self) -> dict[str, TargetDevice]:
        return dict(self._devices)
