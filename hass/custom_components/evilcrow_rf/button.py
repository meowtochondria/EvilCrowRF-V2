"""Button platform for the EvilCrowRF V2 integration.

Provides button entities for triggering device actions:
  - ``LearnButtonEntity`` — start capturing an RF signal.
  - ``CancelCaptureButtonEntity`` — cancel any in-progress capture/replay.
  - ``ReplayButtonEntity`` — replay the last captured signal.
  - ``AddTargetDeviceButton`` — launches guided learning wizard.
  - ``ConfirmYesButton`` / ``ConfirmNoButton`` / ``ConfirmCancelButton``
    — confirm/retry/cancel a capture.
  - ``StartMonitoringButton`` — start/stop monitoring (Phase 5).
"""

from __future__ import annotations

import logging
from typing import override

from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import EvilCrowCoordinator
from .subghz import CaptureStateValue

_LOGGER = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Base class
# ---------------------------------------------------------------------------


class EvilCrowButtonBase(CoordinatorEntity, ButtonEntity):
    """Base class for EvilCrowRF button entities.

    Subclasses must override ``async_press`` and set ``_attr_translation_key``.
    """

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
    def device_info(self) -> DeviceInfo:
        """Return device registry info for this EvilCrowRF device."""
        info = self.coordinator.device_info
        return DeviceInfo(
            identifiers={(DOMAIN, info.device_id)},
            name=info.name or "EvilCrowRF V2",
            manufacturer="EvilCrowRF",
            model="EvilCrowRF V2",
            sw_version=info.firmware_version or None,
            configuration_url=f"http://{info.host}:{info.port}" if info.host else None,
        )

    @property  # type: ignore
    def available(self) -> bool:
        """Return True if the coordinator has loaded."""
        return super().available



# ---------------------------------------------------------------------------
# LearnButtonEntity — start capture
# ---------------------------------------------------------------------------


class LearnButtonEntity(EvilCrowButtonBase):
    """Button that starts capturing an RF signal.

    When a wizard session is active (started via 'Add Target Remote'),
    this button uses the wizard's frequency and target context.
    When no wizard is active, this does a standalone capture at 433.92 MHz.
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

        # If a wizard is active, use its context
        if subghz.wizard_is_active:
            wiz = subghz.wizard
            await subghz.wizard_advance_to_capture()
            await subghz.start_capture(
                frequency=wiz.frequency,
                target_device_id=wiz.target_device_id,
                target_device_name=wiz.target_device_name,
                button_name=wiz.last_button_name or f"button_{wiz.button_index}",
            )
            _LOGGER.debug(
                "Learn button pressed in wizard mode on device %s: target=%s, button=%s",
                self.coordinator.device_info.device_id,
                wiz.target_device_name,
                wiz.last_button_name,
            )
            return

        # No wizard: standalone capture with default frequency
        await subghz.start_capture(frequency=433920000)
        _LOGGER.debug(
            "Learn button pressed (standalone) on device %s",
            self.coordinator.device_info.device_id,
        )


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
    """Button to add a new target RF remote device.

    Pressing this button starts an interactive multi-step wizard that
    guides the user through learning an RF remote:
      1. Names the remote (auto-generated)
      2. Prompts the user to press 'Learn Signal'
      3. Captures each button
      4. Saves the button-to-signal mapping
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
        """Handle the button press — launch the interactive learning wizard."""
        subghz = self.coordinator.subghz
        if subghz is None:
            _LOGGER.warning("SubGhzService not initialized; cannot start wizard.")
            return

        device_id = self.coordinator.device_info.device_id
        _LOGGER.info(
            "Add target device button pressed on device %s — starting interactive wizard",
            device_id,
        )

        # Cancel any existing wizard
        if subghz.wizard_is_active:
            await subghz.wizard_cancel()

        # Start a new wizard with default settings
        await subghz.wizard_start(
            target_device_name="",
            frequency=433920000,
        )
        _LOGGER.info(
            "Interactive wizard started on device %s: target='%s'",
            device_id,
            subghz.wizard.target_device_name,
        )


# ---------------------------------------------------------------------------
# ConfirmYesButton / ConfirmNoButton / ConfirmCancelButton — capture feedback
# ---------------------------------------------------------------------------


class ConfirmYesButton(EvilCrowButtonBase):
    """Confirm that the replayed signal worked.

    Calls ``confirm_capture(confirmed=True)`` on the SubGhzService.
    Only functional when the state machine is in CONFIRMING state.
    """

    _attr_translation_key = "confirm_yes"
    _attr_entity_category = EntityCategory.CONFIG

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the confirm yes button."""
        super().__init__(coordinator, entry_id, "confirm_yes")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        device_id = self.coordinator.device_info.device_id
        hass = self.coordinator.hass
        await hass.services.async_call(
            DOMAIN,
            "confirm_capture",
            {
                "device_id": device_id,
                "confirmed": True,
            },
            blocking=False,
        )

    @property  # type: ignore
    def available(self) -> bool:
        """Return True only when waiting for confirmation."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return False
        return subghz.state.state == CaptureStateValue.CONFIRMING


class ConfirmNoButton(EvilCrowButtonBase):
    """Reject the replayed signal and retry capture.

    Calls ``confirm_capture(confirmed=False)`` on the SubGhzService,
    which transitions back to CAPTURING for the same button.
    """

    _attr_translation_key = "confirm_no"
    _attr_entity_category = EntityCategory.CONFIG

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the confirm no button."""
        super().__init__(coordinator, entry_id, "confirm_no")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        device_id = self.coordinator.device_info.device_id
        hass = self.coordinator.hass
        await hass.services.async_call(
            DOMAIN,
            "confirm_capture",
            {
                "device_id": device_id,
                "confirmed": False,
            },
            blocking=False,
        )

    @property  # type: ignore
    def available(self) -> bool:
        """Return True only when waiting for confirmation."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return False
        return subghz.state.state == CaptureStateValue.CONFIRMING


class ConfirmCancelButton(EvilCrowButtonBase):
    """Cancel the in-progress capture confirmation.

    Calls ``confirm_capture(cancel=True)``, which aborts the entire
    capture and returns to IDLE.
    """

    _attr_translation_key = "confirm_cancel"
    _attr_entity_category = EntityCategory.CONFIG

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the confirm cancel button."""
        super().__init__(coordinator, entry_id, "confirm_cancel")

    @override
    async def async_press(self) -> None:
        """Handle the button press."""
        device_id = self.coordinator.device_info.device_id
        hass = self.coordinator.hass
        await hass.services.async_call(
            DOMAIN,
            "confirm_capture",
            {
                "device_id": device_id,
                "confirmed": False,
                "cancel": True,
            },
            blocking=False,
        )

    @property  # type: ignore
    def available(self) -> bool:
        """Return True only when waiting for confirmation."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return False
        return subghz.state.state == CaptureStateValue.CONFIRMING


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

    # Add confirm buttons for the capture confirmation flow
    confirm_entities: list[ButtonEntity] = [
        ConfirmYesButton(coordinator, config_entry.entry_id),
        ConfirmNoButton(coordinator, config_entry.entry_id),
        ConfirmCancelButton(coordinator, config_entry.entry_id),
    ]
    async_add_entities(confirm_entities)

    _LOGGER.debug(
        "Added %d button entities for device %s",
        len(entities) + len(confirm_entities),
        coordinator.device_info.device_id,
    )
