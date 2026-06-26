"""Home Assistant service definitions for the EvilCrowRF V2 integration.

Registers 10 services that operate on individual EvilCrowRF devices.
Each service looks up its coordinator via ``hass.data[DOMAIN][ec_device_id]``
and delegates to the appropriate method on `SubGhzService`.
"""

from __future__ import annotations

import logging
from typing import Any

import voluptuous as vol
from homeassistant.core import HomeAssistant, ServiceCall, callback
from homeassistant.exceptions import HomeAssistantError

from .const import (
    ATTR_BUTTON_NAME,
    ATTR_DEVICE_ID,
    ATTR_FREQUENCY,
    ATTR_MODULATION,
    ATTR_NEW_NAME,
    ATTR_SIGNAL_FILE,
    ATTR_TARGET_DEVICE_ID,
    DOMAIN,
    SERVICE_CANCEL_CAPTURE,
    SERVICE_CONFIRM_CAPTURE,
    SERVICE_DELETE_SIGNAL,
    SERVICE_LEARN_SIGNAL,
    SERVICE_REFRESH_FILES,
    SERVICE_RENAME_SIGNAL,
    SERVICE_REPLAY_SIGNAL,
    SERVICE_SCAN_FREQUENCY,
    SERVICE_START_MONITORING,
    SERVICE_STOP_MONITORING,
)

_LOGGER = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Shared schema pieces
# ---------------------------------------------------------------------------

DEVICE_ID_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
    },
    extra=vol.ALLOW_EXTRA,
)

LEARN_SIGNAL_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Optional(ATTR_FREQUENCY, default=433920000): vol.All(
            vol.Coerce(int), vol.Range(min=1, max=10_000_000_000)
        ),
        vol.Optional(ATTR_MODULATION, default="OOK_FIX"): str,
    },
    extra=vol.PREVENT_EXTRA,
)

REPLAY_SIGNAL_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Required(ATTR_SIGNAL_FILE): str,
    },
    extra=vol.PREVENT_EXTRA,
)

CONFIRM_CAPTURE_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Required(ATTR_TARGET_DEVICE_ID): str,
        vol.Required(ATTR_BUTTON_NAME): str,
        vol.Required(ATTR_SIGNAL_FILE): str,
    },
    extra=vol.PREVENT_EXTRA,
)

CANCEL_CAPTURE_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
    },
    extra=vol.PREVENT_EXTRA,
)

RENAME_SIGNAL_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Required(ATTR_SIGNAL_FILE): str,
        vol.Required(ATTR_NEW_NAME): str,
    },
    extra=vol.PREVENT_EXTRA,
)

DELETE_SIGNAL_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Required(ATTR_SIGNAL_FILE): str,
    },
    extra=vol.PREVENT_EXTRA,
)

REFRESH_FILES_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
    },
    extra=vol.PREVENT_EXTRA,
)

SCAN_FREQUENCY_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
    },
    extra=vol.PREVENT_EXTRA,
)

START_MONITORING_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Optional(ATTR_FREQUENCY, default=433920000): vol.All(
            vol.Coerce(int), vol.Range(min=1, max=10_000_000_000)
        ),
    },
    extra=vol.PREVENT_EXTRA,
)

STOP_MONITORING_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
    },
    extra=vol.PREVENT_EXTRA,
)


# ---------------------------------------------------------------------------
# Service registration
# ---------------------------------------------------------------------------


@callback
def async_register_services(hass: HomeAssistant) -> None:
    """Register all EvilCrowRF services.

    Called from ``__init__.py`` during ``async_setup_entry``.
    Services are scoped to the ``evilcrow_rf`` domain.
    """

    async def _get_coordinator(device_id: str) -> Any:
        """Look up the coordinator for a given device ID.

        Args:
            device_id: The EC device ID (config entry ID).

        Returns:
            The EvilCrowCoordinator instance.

        Raises:
            HomeAssistantError: If the device is not found.
        """
        data = hass.data.get(DOMAIN, {})
        coordinator = data.get(device_id)
        if coordinator is None:
            raise HomeAssistantError(
                f"EvilCrowRF device '{device_id}' not found or not connected.",
                translation_domain=DOMAIN,
                translation_key="device_not_found",
                translation_placeholders={"device_id": device_id},
            )
        return coordinator

    async def _handle_learn_signal(call: ServiceCall) -> None:
        """Start capturing an RF signal on the given frequency."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.start_capture(
            frequency=data[ATTR_FREQUENCY],
        )

    async def _handle_confirm_capture(call: ServiceCall) -> None:
        """Confirm a captured signal and associate it with a button."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.confirm_capture(
            target_device_id=data[ATTR_TARGET_DEVICE_ID],
            button_name=data[ATTR_BUTTON_NAME],
            signal_file=data[ATTR_SIGNAL_FILE],
        )

    async def _handle_cancel_capture(call: ServiceCall) -> None:
        """Cancel any in-progress capture or replay."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.cancel_capture()

    async def _handle_replay_signal(call: ServiceCall) -> None:
        """Replay a previously captured .sub signal."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.replay_signal(
            file_path=data[ATTR_SIGNAL_FILE],
        )

    async def _handle_rename_signal(call: ServiceCall) -> None:
        """Rename a .sub file on the device's SD card."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        old_path = data[ATTR_SIGNAL_FILE]
        new_name = data[ATTR_NEW_NAME]
        # Derive new path from old path: replace filename component
        parts = old_path.rsplit("/", 1)
        new_path = f"{parts[0]}/{new_name}" if len(parts) > 1 else new_name
        await subghz.rename_signal(old_path=old_path, new_path=new_path)

    async def _handle_delete_signal(call: ServiceCall) -> None:
        """Delete a .sub file from the device's SD card.

        Note: The device firmware may not support a file delete command at this
        time. This service is defined for future use and currently logs a warning.
        """
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        signal_file = data[ATTR_SIGNAL_FILE]
        _LOGGER.warning(
            "Delete signal not yet implemented on device %s for file %s",
            data[ATTR_DEVICE_ID],
            signal_file,
        )
        # In Phase 5, this would send a file delete command.
        # For now, we just remove the entry from TargetDeviceStore.
        store = coordinator.target_store
        if store is not None:
            for target in store.get_all_for_ec_device(data[ATTR_DEVICE_ID]):
                for btn, sfile in list(target.buttons.items()):
                    if sfile == signal_file:
                        store.remove_button(target.target_device_id, btn)
                        break
            await store.async_save()

    async def _handle_refresh_files(call: ServiceCall) -> None:
        """Refresh the list of .sub files from the device."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.refresh_files()

    async def _handle_scan_frequency(call: ServiceCall) -> None:
        """Request a frequency scan on the device.

        Note: Full frequency scanning may be a Phase 5 feature.
        """
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        frames = coordinator.transport.protocol.build_scan_command()
        sent = await coordinator.transport.send_frame(frames)
        if not sent:
            raise HomeAssistantError(
                "Failed to send frequency scan command to device.",
                translation_domain=DOMAIN,
                translation_key="scan_failed",
            )

    async def _handle_start_monitoring(call: ServiceCall) -> None:
        """Start continuous monitoring on the device.

        Phase 5 feature. Falls back gracefully on older firmware.
        """
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        monitor = coordinator.signal_monitor
        if monitor is None:
            raise HomeAssistantError("SignalMonitor not initialized.")
        frequency = data.get(ATTR_FREQUENCY, 433920000)
        success = await monitor.start(frequency)
        if not success:
            _LOGGER.warning(
                "Start monitoring not supported on device %s (Phase 5 feature)",
                data[ATTR_DEVICE_ID],
            )

    async def _handle_stop_monitoring(call: ServiceCall) -> None:
        """Stop continuous monitoring on the device."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        monitor = coordinator.signal_monitor
        if monitor is None:
            raise HomeAssistantError("SignalMonitor not initialized.")
        success = await monitor.stop()
        if not success:
            _LOGGER.warning(
                "Stop monitoring not supported on device %s (Phase 5 feature)",
                data[ATTR_DEVICE_ID],
            )

    # ---- register services ----

    hass.services.async_register(
        DOMAIN,
        SERVICE_LEARN_SIGNAL,
        _handle_learn_signal,
        schema=LEARN_SIGNAL_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_CONFIRM_CAPTURE,
        _handle_confirm_capture,
        schema=CONFIRM_CAPTURE_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_CANCEL_CAPTURE,
        _handle_cancel_capture,
        schema=CANCEL_CAPTURE_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_REPLAY_SIGNAL,
        _handle_replay_signal,
        schema=REPLAY_SIGNAL_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_RENAME_SIGNAL,
        _handle_rename_signal,
        schema=RENAME_SIGNAL_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_DELETE_SIGNAL,
        _handle_delete_signal,
        schema=DELETE_SIGNAL_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_REFRESH_FILES,
        _handle_refresh_files,
        schema=REFRESH_FILES_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_SCAN_FREQUENCY,
        _handle_scan_frequency,
        schema=SCAN_FREQUENCY_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_START_MONITORING,
        _handle_start_monitoring,
        schema=START_MONITORING_SCHEMA,
    )

    hass.services.async_register(
        DOMAIN,
        SERVICE_STOP_MONITORING,
        _handle_stop_monitoring,
        schema=STOP_MONITORING_SCHEMA,
    )

    _LOGGER.debug("Registered %d EvilCrowRF services", 10)
