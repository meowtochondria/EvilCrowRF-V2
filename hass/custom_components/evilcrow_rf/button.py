"""Button platform for the EvilCrowRF V2 integration.

Provides button entities for triggering device actions:
  - ``LearnButtonEntity`` — start capturing an RF signal.
  - ``CancelCaptureButtonEntity`` — cancel any in-progress capture/replay.
  - ``ReplayButtonEntity`` — replay the last captured signal.
  - ``AddTargetDeviceButton`` — add a target device (placeholder).
  - ``StartMonitoringButton`` — start/stop monitoring (Phase 5).
"""

from __future__ import annotations

import logging
from typing import override

from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import EvilCrowCoordinator

_LOGGER = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Base class
# ---------------------------------------------------------------------------


class EvilCrowButtonBase(CoordinatorEntity, ButtonEntity):
    """Base class for EvilCrowRF button entities.

    Subclasses must override ``async_press`` and set ``_attr_translation_key``.
    """

    _coordinator: EvilCrowCoordinator
    _attr_has_entity_name: bool = True
    _attr_entity_category: EntityCategory = EntityCategory.CONFIG  # type: ignore

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
        suffix: str,
    ) -> None:
        """Initialize the button.

        Args:
            coordinator: The device's coordinator.
            entry_id: The config entry ID.
            suffix: The unique_id suffix (e.g. ``"learn"``).
        """
        super().__init__(coordinator)
        device_id = coordinator.device_info.device_id
        self._entry_id = entry_id
        self._attr_unique_id = f"evilcrow_{device_id}_{suffix}"

    @property
    def coordinator(self) -> EvilCrowCoordinator:
        return self._coordinator

    @property  # type: ignore
    def available(self) -> bool:
        """Return True if the coordinator has loaded."""
        return super().available


# ---------------------------------------------------------------------------
# LearnButtonEntity — start capture
# ---------------------------------------------------------------------------


class LearnButtonEntity(EvilCrowButtonBase):
    """Button that starts capturing an RF signal.

    Pressing this button will send a CMD_START_RECORDING to the device
    using a default frequency of 433.92 MHz.
    """

    _attr_translation_key = "learn_signal"

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the learn button."""
        super().__init__(coordinator, entry_id, "learn")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        subghz = self.coordinator.subghz
        if subghz is None:
            _LOGGER.warning("SubGhzService not initialized; cannot learn signal.")
            return
        await subghz.start_capture(frequency=433920000)
        _LOGGER.debug("Learn button pressed on device %s", self.coordinator.device_info.device_id)


# ---------------------------------------------------------------------------
# CancelCaptureButtonEntity — cancel current operation
# ---------------------------------------------------------------------------


class CancelCaptureButtonEntity(EvilCrowButtonBase):
    """Button that cancels any in-progress capture or replay.

    Sends CMD_IDLE and resets the state machine to IDLE.
    """

    _attr_translation_key = "cancel_capture"

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the cancel capture button."""
        super().__init__(coordinator, entry_id, "cancel_capture")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        subghz = self.coordinator.subghz
        if subghz is None:
            _LOGGER.warning("SubGhzService not initialized; cannot cancel capture.")
            return
        await subghz.cancel_capture()
        _LOGGER.debug(
            "Cancel capture button pressed on device %s", self.coordinator.device_info.device_id
        )


# ---------------------------------------------------------------------------
# ReplayButtonEntity — replay last captured signal
# ---------------------------------------------------------------------------


class ReplayButtonEntity(EvilCrowButtonBase):
    """Button that replays the last captured signal.

    If no signal has been captured yet, the press is a no-op.
    """

    _attr_translation_key = "replay_signal"

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the replay button."""
        super().__init__(coordinator, entry_id, "replay")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        subghz = self.coordinator.subghz
        if subghz is None:
            _LOGGER.warning("SubGhzService not initialized; cannot replay signal.")
            return
        signal_file = subghz.state.signal_file
        if not signal_file:
            _LOGGER.warning(
                "No captured signal to replay on device %s", self.coordinator.device_info.device_id
            )
            return
        await subghz.replay_signal(file_path=signal_file)
        _LOGGER.debug(
            "Replay button pressed on device %s: %s",
            self.coordinator.device_info.device_id,
            signal_file,
        )


# ---------------------------------------------------------------------------
# AddTargetDeviceButton — placeholder for adding a target device
# ---------------------------------------------------------------------------


class AddTargetDeviceButton(EvilCrowButtonBase):
    """Button to add a new target RF remote device (placeholder).

    In a full implementation, this would open a config flow or dialog
    to define a new target remote. Currently it logs the press.
    """

    _attr_translation_key = "add_target_device"

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the add target device button."""
        super().__init__(coordinator, entry_id, "add_target")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        _LOGGER.info(
            "Add target device button pressed on device %s (placeholder)",
            self.coordinator.device_info.device_id,
        )


# ---------------------------------------------------------------------------
# StartMonitoringButton — toggle monitoring (Phase 5)
# ---------------------------------------------------------------------------


class StartMonitoringButton(EvilCrowButtonBase):
    """Button to start or stop continuous monitoring (Phase 5 feature).

    On Phase 5 firmware this starts/stops the dedicated monitoring CC1101
    module. On older firmware the press is a no-op.
    """

    _attr_translation_key = "start_monitoring"

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the start monitoring button."""
        super().__init__(coordinator, entry_id, "monitoring")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        monitor = self.coordinator.signal_monitor
        if monitor is None:
            _LOGGER.warning("SignalMonitor not initialized.")
            return

        if monitor.active:
            await monitor.stop()
            _LOGGER.debug("Monitoring stopped on device %s", self.coordinator.device_info.device_id)
        else:
            await monitor.start(433920000)
            _LOGGER.debug("Monitoring started on device %s", self.coordinator.device_info.device_id)


# ---------------------------------------------------------------------------
# Platform setup
# ---------------------------------------------------------------------------


async def async_setup_entry(
    hass: HomeAssistant,
    config_entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up the EvilCrowRF button platform."""
    coordinator: EvilCrowCoordinator = hass.data[DOMAIN][config_entry.entry_id]

    entities: list[ButtonEntity] = [
        LearnButtonEntity(coordinator, config_entry.entry_id),
        CancelCaptureButtonEntity(coordinator, config_entry.entry_id),
        ReplayButtonEntity(coordinator, config_entry.entry_id),
        AddTargetDeviceButton(coordinator, config_entry.entry_id),
        StartMonitoringButton(coordinator, config_entry.entry_id),
    ]

    async_add_entities(entities)
    _LOGGER.debug(
        "Added %d button entities for device %s",
        len(entities),
        coordinator.device_info.device_id,
    )
