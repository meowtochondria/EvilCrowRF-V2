"""Sensor platform for the EvilCrowRF V2 integration.

Provides:
  - ``EvilCrowDeviceSensor`` — connection status, firmware version, diagnostics.
  - ``CaptureStateSensor`` — tracks the capture state machine state.
"""

from __future__ import annotations

import logging
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import EvilCrowCoordinator
from .subghz import CaptureStateValue

_LOGGER = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# EvilCrowDeviceSensor — connection status and firmware info
# ---------------------------------------------------------------------------


class EvilCrowDeviceSensor(CoordinatorEntity, SensorEntity):
    """Reports connection status, firmware version, and device diagnostics.

    This sensor combines several device-health attributes into a single
    primary sensor whose state is the connection status, with extra state
    attributes for firmware version, device name, capabilities, etc.
    """

    _coordinator: EvilCrowCoordinator
    _attr_has_entity_name = True
    _attr_device_class: SensorDeviceClass | None = SensorDeviceClass.ENUM  # type: ignore
    _attr_state_class: SensorStateClass | str | None = SensorStateClass.MEASUREMENT
    _attr_entity_category = EntityCategory.DIAGNOSTIC

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the device sensor."""
        super().__init__(coordinator)
        self._entry_id = entry_id
        device_id = coordinator.device_info.device_id
        self._attr_unique_id = f"evilcrow_{device_id}_device"
        self._attr_translation_key = "device_status"

        self._attr_options = [
            "connected",
            "disconnected",
            "error",
        ]

    @property
    def coordinator(self) -> EvilCrowCoordinator:
        """Return the coordinator with narrowed type."""
        return self._coordinator

    @property  # type: ignore
    def native_value(self) -> str:
        """Return the connection status of the device."""
        transport = self.coordinator.transport
        if transport is None:
            return "disconnected"
        # Check if the WebSocket is connected by looking at the transport state.
        # WiFiTransport has a _ws attribute; None or closed = disconnected.
        ws = getattr(transport, "_ws", None)
        if ws is not None and not ws.closed:
            return "connected"
        return "disconnected"

    @property  # type: ignore
    def extra_state_attributes(self) -> dict[str, Any]:
        """Return device diagnostics attributes."""
        info = self.coordinator.device_info
        attrs: dict[str, Any] = {
            "firmware_version": info.firmware_version,
            "fw_major": info.fw_major,
            "fw_minor": info.fw_minor,
            "fw_patch": info.fw_patch,
            "device_name": info.name,
            "device_id": info.device_id,
            "transport": info.transport,
            "mac": info.mac or "unknown",
        }
        if info.capabilities:
            attrs["capabilities"] = info.capabilities
        return attrs

    @property  # type: ignore
    def available(self) -> bool:
        """Return True if the device is connected."""
        return self.native_value == "connected"


# ---------------------------------------------------------------------------
# CaptureStateSensor — tracks the capture/replay state machine
# ---------------------------------------------------------------------------


class CaptureStateSensor(CoordinatorEntity, SensorEntity):
    """Tracks the capture/replay state machine state.

    Reports:
      - ``state``: one of ``idle``, ``capturing``, ``captured``, ``confirming``,
        ``confirmed``, ``error``.
      - ``signal_file``: the path of the captured .sub file.
      - ``error_message``: human-readable error when state is ``error``.
    """

    _coordinator: EvilCrowCoordinator
    _attr_has_entity_name = True
    _attr_device_class: SensorDeviceClass | None = SensorDeviceClass.ENUM  # type: ignore[override]
    _attr_state_class: SensorStateClass | str | None = SensorStateClass.MEASUREMENT
    _attr_entity_category = EntityCategory.DIAGNOSTIC

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the capture state sensor.

        Args:
            coordinator: The device's coordinator.
            entry_id: The config entry ID (used as the unique_id suffix).
        """
        super().__init__(coordinator)
        self._entry_id = entry_id
        device_id = coordinator.device_info.device_id
        self._attr_unique_id = f"evilcrow_{device_id}_capture_state"
        self._attr_translation_key = "capture_state"

        self._attr_options = [
            CaptureStateValue.IDLE,
            CaptureStateValue.CAPTURING,
            CaptureStateValue.SIGNAL_CAPTURED,
            CaptureStateValue.CONFIRMING,
            CaptureStateValue.CONFIRMED,
            CaptureStateValue.REPLAYING,
            CaptureStateValue.ERROR,
        ]

    @property
    def coordinator(self) -> EvilCrowCoordinator:
        """Return the coordinator with narrowed type."""
        return self._coordinator

    @property  # type: ignore
    def native_value(self) -> str:
        """Return the current capture state value."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return CaptureStateValue.IDLE
        return subghz.state.state

    @property  # type: ignore
    def extra_state_attributes(self) -> dict[str, Any]:
        """Return capture-related attributes."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return {}
        capture_state = subghz.state
        attrs: dict[str, Any] = {
            "signal_file": capture_state.signal_file,
            "generation": capture_state.generation,
            "error_message": capture_state.error_message,
            "last_file_list_count": len(capture_state.last_file_list),
            "target_device_id": capture_state.target_device_id,
            "target_device_name": capture_state.target_device_name,
            "button_name": capture_state.button_name,
            "frequency_mhz": capture_state.frequency_mhz,
            "fcc_id": capture_state.fcc_id,
            "modulation": capture_state.modulation,
        }
        if capture_state.raw_response:
            attrs["last_response"] = capture_state.raw_response
        return attrs

    @property  # type: ignore
    def available(self) -> bool:
        """Return True if the coordinator has a subghz service."""
        return self.coordinator.subghz is not None


# ---------------------------------------------------------------------------
# Platform setup
# ---------------------------------------------------------------------------


async def async_setup_entry(
    hass: HomeAssistant,
    config_entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up the EvilCrowRF sensor platform."""
    coordinator: EvilCrowCoordinator = hass.data[DOMAIN][config_entry.entry_id]

    entities: list[SensorEntity] = [
        EvilCrowDeviceSensor(coordinator, config_entry.entry_id),
        CaptureStateSensor(coordinator, config_entry.entry_id),
    ]

    async_add_entities(entities)
    _LOGGER.debug(
        "Added %d sensor entities for device %s",
        len(entities),
        coordinator.device_info.device_id,
    )
