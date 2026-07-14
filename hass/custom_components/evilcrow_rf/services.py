"""Home Assistant service definitions for the EvilCrowRF V2 integration.

Registers 11 services that operate on individual EvilCrowRF devices.
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
    ATTR_CANCEL,
    ATTR_CONFIRMED,
    ATTR_DEVICE_ID,
    ATTR_FCC_ID,
    ATTR_FREQUENCY,
    ATTR_MODULATION,
    ATTR_NEW_NAME,
    ATTR_NEXT_BUTTON,
    ATTR_SIGNAL_FILE,
    ATTR_TARGET_DEVICE_ID,
    ATTR_TARGET_DEVICE_NAME,
    DOMAIN,
    NOTIFY_WIZARD_STEP,
    SERVICE_CANCEL_CAPTURE,
    SERVICE_CONFIRM_CAPTURE,
    SERVICE_DELETE_SIGNAL,
    SERVICE_LEARN_SIGNAL,
    SERVICE_REFRESH_FILES,
    SERVICE_RENAME_SIGNAL,
    SERVICE_REPLAY_SIGNAL,
    SERVICE_SCAN_FREQUENCY,
    SERVICE_START_MONITORING,
    SERVICE_START_WIZARD,
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
        vol.Required(ATTR_TARGET_DEVICE_ID): str,
        vol.Required(ATTR_BUTTON_NAME): str,
        vol.Optional(ATTR_FCC_ID): str,
        vol.Exclusive(ATTR_FREQUENCY, "frequency_source"): vol.All(
            vol.Coerce(int), vol.Range(min=1, max=10_000_000_000)
        ),
        vol.Optional(ATTR_MODULATION, default="OOK_FIX"): str,
        vol.Optional(ATTR_TARGET_DEVICE_NAME, default=""): str,
    },
    extra=vol.PREVENT_EXTRA,
)

CONFIRM_CAPTURE_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Required(ATTR_CONFIRMED, default=True): bool,
        vol.Optional(ATTR_CANCEL, default=False): bool,
        vol.Optional(ATTR_NEXT_BUTTON): str,
    },
    extra=vol.PREVENT_EXTRA,
)

CANCEL_CAPTURE_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
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

START_WIZARD_SCHEMA = vol.Schema(
    {
        vol.Required(ATTR_DEVICE_ID): str,
        vol.Optional(ATTR_TARGET_DEVICE_NAME, default=""): str,
        vol.Optional(ATTR_FCC_ID): str,
        vol.Optional(ATTR_FREQUENCY): vol.All(
            vol.Coerce(int), vol.Range(min=1, max=10_000_000_000)
        ),
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

    # ------------------------------------------------------------------
    # learn_signal — Full capture workflow: FCC lookup → capture →
    #   auto-replay → confirm
    # ------------------------------------------------------------------

    async def _handle_learn_signal(call: ServiceCall) -> None:
        """Start capturing a button on a target RF remote.

        Full workflow:
          1. If *fcc_id* is given and no *frequency*, look up frequency
             from the configured FCC API endpoint.
          2. Send ``CMD_START_RECORDING`` to the device.
          3. On ``SignalRecorded``, the state machine auto-advances to
             replay the captured signal (verification).
          4. On ``SignalSent``, the state machine transitions to
             CONFIRMING — the user calls ``confirm_capture`` to
             accept/reject the capture.

        Raises:
            HomeAssistantError: If no frequency could be determined.
        """
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")

        target_device_id: str = data[ATTR_TARGET_DEVICE_ID]
        button_name: str = data[ATTR_BUTTON_NAME]
        target_device_name: str = data.get(ATTR_TARGET_DEVICE_NAME, "")
        fcc_id: str = data.get(ATTR_FCC_ID, "")
        modulation: str = data.get(ATTR_MODULATION, "OOK_FIX")

        # Determine frequency
        frequency: int | None = data.get(ATTR_FREQUENCY)
        if frequency is None and fcc_id:
            # FCC lookup
            fcc = coordinator.fcc_lookup
            if fcc is None:
                from .fcc_lookup import FccLookupService

                fcc = FccLookupService()
                coordinator.fcc_lookup = fcc

            try:
                result = await fcc.lookup(fcc_id)
                if result.frequencies_hz:
                    freq_hz = result.frequencies_hz[0]
                    frequency = freq_hz
                    _LOGGER.info(
                        "FCC lookup for %s returned %.1f MHz",
                        fcc_id,
                        freq_hz / 1_000_000,
                    )
                else:
                    raise HomeAssistantError(
                        f"Could not determine frequency from FCC ID '{fcc_id}'. "
                        "Please enter the frequency manually (e.g. 433920000 Hz).",
                        translation_domain=DOMAIN,
                        translation_key="fcc_lookup_failed",
                        translation_placeholders={"fcc_id": fcc_id},
                    )
            except HomeAssistantError:
                raise
            except Exception as exc:
                raise HomeAssistantError(
                    f"FCC lookup failed for '{fcc_id}': {exc}",
                    translation_domain=DOMAIN,
                    translation_key="fcc_lookup_error",
                    translation_placeholders={"fcc_id": fcc_id},
                ) from exc

        if frequency is None:
            raise HomeAssistantError(
                "No frequency provided and no FCC ID given. Provide a frequency (Hz) or an FCC ID.",
                translation_domain=DOMAIN,
                translation_key="no_frequency",
            )

        # Validate the target device exists in TargetDeviceStore
        store = coordinator.target_store
        if store is not None:
            target = store.get(target_device_id)
            if target is None:
                # Auto-register the target device if not already known
                from .target_device_store import TargetDevice

                device = TargetDevice(
                    target_device_id=target_device_id,
                    name=target_device_name or button_name,
                    ec_device_id=data[ATTR_DEVICE_ID],
                    fcc_id=fcc_id or None,
                    frequency=frequency / 1_000_000,
                    modulation=modulation,
                    buttons={},
                )
                store.register(device)
                await store.async_save()

                # Register in HA device registry so it appears on the
                # integration page under the EC device
                from .__init__ import _register_target_device_in_registry

                _register_target_device_in_registry(
                    hass=hass,
                    config_entry_id=data[ATTR_DEVICE_ID],
                    target_device_id=target_device_id,
                    target_device_name=target_device_name or button_name,
                    ec_device_id=data[ATTR_DEVICE_ID],
                )

        await subghz.start_capture(
            frequency=frequency,
            target_device_id=target_device_id,
            target_device_name=target_device_name,
            button_name=button_name,
            fcc_id=fcc_id,
        )

    # ------------------------------------------------------------------
    # confirm_capture — Accept/retry/cancel the last capture
    # ------------------------------------------------------------------

    async def _handle_confirm_capture(call: ServiceCall) -> None:
        """Confirm, retry, or cancel the last capture.

        Called after the user has verified the replayed signal.

        - ``confirmed=True``: persist the button-to-signal mapping.
        - ``confirmed=False, cancel=False``: retry capturing the same button.
        - ``cancel=True``: abort the entire capture.
        """
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.confirm_capture(
            confirmed=data[ATTR_CONFIRMED],
            cancel=data.get(ATTR_CANCEL, False),
            next_button=data.get(ATTR_NEXT_BUTTON),
        )

    # ------------------------------------------------------------------
    # cancel_capture — Abort any in-progress capture/replay
    # ------------------------------------------------------------------

    async def _handle_cancel_capture(call: ServiceCall) -> None:
        """Cancel any in-progress capture or replay."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.cancel_capture()

    # ------------------------------------------------------------------
    # replay_signal — Replay a .sub file (arbitrary, not verification)
    # ------------------------------------------------------------------

    async def _handle_replay_signal(call: ServiceCall) -> None:
        """Replay a previously captured .sub signal."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.replay_signal(
            file_path=data[ATTR_SIGNAL_FILE],
            verify=False,
        )

    # ------------------------------------------------------------------
    # rename_signal — Rename a .sub file on the SD card
    # ------------------------------------------------------------------

    async def _handle_rename_signal(call: ServiceCall) -> None:
        """Rename a .sub file on the device's SD card."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        old_path = data[ATTR_SIGNAL_FILE]
        new_name = data[ATTR_NEW_NAME]
        parts = old_path.rsplit("/", 1)
        new_path = f"{parts[0]}/{new_name}" if len(parts) > 1 else new_name
        await subghz.rename_signal(old_path=old_path, new_path=new_path)

    # ------------------------------------------------------------------
    # delete_signal — Remove a signal from the store
    # ------------------------------------------------------------------

    async def _handle_delete_signal(call: ServiceCall) -> None:
        """Delete a .sub file entry from the target device store.

        Note: Firmware file delete command may not be available (Phase 5).
        Currently removes the entry from TargetDeviceStore only.
        """
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        signal_file = data[ATTR_SIGNAL_FILE]
        store = coordinator.target_store
        if store is not None:
            for target in store.get_all_for_ec_device(data[ATTR_DEVICE_ID]):
                for btn, sfile in list(target.buttons.items()):
                    if sfile == signal_file:
                        store.remove_button(target.target_device_id, btn)
                        break
            await store.async_save()

    # ------------------------------------------------------------------
    # refresh_files — Re-fetch the SD card file list
    # ------------------------------------------------------------------

    async def _handle_refresh_files(call: ServiceCall) -> None:
        """Refresh the list of .sub files from the device."""
        data = call.data
        coordinator = await _get_coordinator(data[ATTR_DEVICE_ID])
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError("SubGhzService not initialized.")
        await subghz.refresh_files()

    # ------------------------------------------------------------------
    # scan_frequency — Scan for the strongest RF frequency
    # ------------------------------------------------------------------

    async def _handle_scan_frequency(call: ServiceCall) -> None:
        """Request a frequency scan on the device."""
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

    # ------------------------------------------------------------------
    # start_monitoring / stop_monitoring — Phase 5
    # ------------------------------------------------------------------

    async def _handle_start_monitoring(call: ServiceCall) -> None:
        """Start continuous monitoring (Phase 5 feature)."""
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
        """Stop continuous monitoring."""
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

    # ------------------------------------------------------------------
    # start_wizard — Launch the guided learning wizard
    # ------------------------------------------------------------------

    async def _handle_start_wizard(call: ServiceCall) -> None:
        """Launch the guided target-device learning wizard.

        Starts an interactive wizard session on the SubGhzService and
        shows a persistent_notification guiding the user through the
        capture workflow:

        1. Name the target remote.
        2. Enter FCC ID or frequency.
        3. Start capture and press the remote button.
        4. Confirm the replayed signal.

        The user progresses through the wizard by pressing the
        'Learn Signal' button and the Confirm Yes/No/Cancel buttons.
        """
        data = call.data
        device_id: str = data[ATTR_DEVICE_ID]
        coordinator = await _get_coordinator(device_id)
        subghz = coordinator.subghz
        if subghz is None:
            raise HomeAssistantError(
                "SubGhzService not initialized.",
                translation_domain=DOMAIN,
                translation_key="subghz_not_initialized",
            )

        target_name: str = data.get(ATTR_TARGET_DEVICE_NAME, "")
        freq: int | None = data.get(ATTR_FREQUENCY)

        # Start the wizard session on the SubGhzService
        if subghz.wizard_is_active:
            await subghz.wizard_cancel()
        await subghz.wizard_start(
            target_device_name=target_name or "",
            frequency=freq or 433920000,
        )

        device_name = coordinator.device_info.name
        fcc_id: str = data.get(ATTR_FCC_ID, "")

        # Build the notification message
        lines = [
            "## EvilCrowRF V2 \u2014 Learn a New Remote",
            "",
            f"Device: **{device_name}** ({device_id})",
            "",
            "### Step-by-step instructions",
            "",
            "1. **Call `evilcrow_rf.learn_signal`** with:",
            f"   - `device_id`: `{device_id}`",
            f"   - `target_device_id`: `{target_name or '<your-remote-name>'}`",
            "   - `button_name`: e.g. `power`",
        ]

        if fcc_id:
            lines.append(f"   - `fcc_id`: `{fcc_id}`")
        if freq:
            lines.append(f"   - `frequency`: `{freq}` (Hz)")
        if not fcc_id and not freq:
            lines.append("   - `fcc_id`: optional, or")
            lines.append("   - `frequency`: e.g. `433920000` (Hz)")

        lines.extend(
            [
                "",
                "2. When prompted, **press the remote button** near the device.",
                "",
                "3. The device will replay the captured signal for verification.",
                "",
                "4. **Call `evilcrow_rf.confirm_capture`** with:",
                f"   - `device_id`: `{device_id}`",
                "   - `confirmed`: `true` (if the device responded)",
                "   - or `confirmed`: `false` to retry",
                "   - or `cancel`: `true` to abort",
                "",
                "5. Repeat for each button you want to learn.",
                "",
                "---",
                "",
                "> **Tip**: Use Developer Tools → Services in Home Assistant ",
                "> to call these services. You can also create automations",
                "> that call them.",
            ]
        )

        notify_id = f"{NOTIFY_WIZARD_STEP}_{device_id}"
        hass.async_create_task(
            hass.services.async_call(
                "persistent_notification",
                "create",
                {
                    "notification_id": notify_id,
                    "title": "EvilCrowRF — Learn a New Remote",
                    "message": "\n".join(lines),
                },
                blocking=False,
            )
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

    hass.services.async_register(
        DOMAIN,
        SERVICE_START_WIZARD,
        _handle_start_wizard,
        schema=START_WIZARD_SCHEMA,
    )

    from .const import NUM_SERVICES

    _LOGGER.debug("Registered %d EvilCrowRF services", NUM_SERVICES)
