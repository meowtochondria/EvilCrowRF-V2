"""Device identity management for EvilCrowRF V2 integration.

Phases 1–4 identify devices by host:port (the existing config-entry data model).
The DeviceInfo dataclass and DeviceRegistryStore below are still defined in Phase 1,
but the UUID round-trip (hass-config-sync) is deferred to Phase 5 because it requires
new firmware commands.

Until Phase 5 ships, devices keep their HA-assigned entry_id as a stable identity,
which is sufficient for single-device use.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

from homeassistant.core import HomeAssistant

from .models import DeviceInfo

_LOGGER = logging.getLogger(__name__)

DEVICE_REGISTRY_FILENAME = "evilcrow_rf_device_registry.json"


class DeviceRegistryStore:
    """Persists device registry data in HA's storage (stores.json-like)."""

    def __init__(self, hass: HomeAssistant):
        self._hass = hass
        self._path: str = hass.config.path(DEVICE_REGISTRY_FILENAME)
        self._data: dict[str, dict[str, Any]] = {}  # device_id -> info

    async def async_load(self) -> None:
        """Load device registry from JSON file."""
        try:
            data = await self._hass.async_add_executor_job(self._load_sync)
            if data is not None:
                self._data = data.get("devices", {})
        except (OSError, json.JSONDecodeError) as exc:
            _LOGGER.debug("No existing device registry: %s", exc)

    def _load_sync(self) -> dict[str, Any] | None:
        """Synchronous file load (runs in executor)."""
        if not os.path.exists(self._path):
            return None
        with open(self._path) as f:
            return json.load(f)

    async def async_save(self) -> None:
        """Save device registry to JSON file."""
        await self._hass.async_add_executor_job(self._save_sync)

    def _save_sync(self) -> None:
        """Synchronous file save (runs in executor)."""
        data = {"devices": self._data}
        tmp_path = self._path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, self._path)

    def get(self, device_id: str) -> DeviceInfo | None:
        """Get device info by device_id."""
        info = self._data.get(device_id)
        if info is None:
            return None
        return DeviceInfo(
            host=info.get("host", ""),
            port=info.get("port", 80),
            device_id=info.get("device_id", device_id),
            name=info.get("name", ""),
            firmware_version=info.get("firmware_version", ""),
            fw_major=info.get("fw_major", 0),
            fw_minor=info.get("fw_minor", 0),
            fw_patch=info.get("fw_patch", 0),
            transport=info.get("transport", "wifi"),
            mac=info.get("mac"),
            capabilities=info.get("capabilities", {}),
        )

    def register(self, info: DeviceInfo) -> None:
        """Register a device."""
        self._data[info.device_id] = {
            "host": info.host,
            "port": info.port,
            "device_id": info.device_id,
            "name": info.name,
            "firmware_version": info.firmware_version,
            "fw_major": info.fw_major,
            "fw_minor": info.fw_minor,
            "fw_patch": info.fw_patch,
            "transport": info.transport,
            "mac": info.mac,
            "capabilities": info.capabilities,
        }

    def find_by_host(self, host: str, port: int) -> DeviceInfo | None:
        """Locate a device by its host/port — used for factory-reset reconciliation."""
        for info_dict in self._data.values():
            if info_dict.get("host") == host and info_dict.get("port") == port:
                return DeviceInfo(
                    host=info_dict["host"],
                    port=info_dict["port"],
                    device_id=info_dict["device_id"],
                    name=info_dict.get("name", ""),
                    firmware_version=info_dict.get("firmware_version", ""),
                    fw_major=info_dict.get("fw_major", 0),
                    fw_minor=info_dict.get("fw_minor", 0),
                    fw_patch=info_dict.get("fw_patch", 0),
                    transport=info_dict.get("transport", "wifi"),
                    mac=info_dict.get("mac"),
                    capabilities=info_dict.get("capabilities", {}),
                )
        return None

    def all_devices(self) -> list[DeviceInfo]:
        """Return all registered devices."""
        result: list[DeviceInfo] = []
        for did in self._data:
            info = self.get(did)
            if info is not None:
                result.append(info)
        return result
