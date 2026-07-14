"""SubGhzService state machine for capture/replay lifecycle.

Manages the lifecycle of capturing, confirming, and replaying RF signals
on an EvilCrowRF device. State transitions are driven by WebSocket messages
from the device and service calls from Home Assistant.

State machine (from plan.md §3.1):

    IDLE --> CAPTURING: learn_signal service
    IDLE --> REPLAYING: replay_signal service (arbitrary replay)

    CAPTURING --> CAPTURING: SignalDetected (RSSI live feed)
    CAPTURING --> SIGNAL_CAPTURED: SignalRecorded
    CAPTURING --> IDLE: capture_timeout / SignalError / cancel

    SIGNAL_CAPTURED --> REPLAYING: auto-advance (replay for verification)

    REPLAYING --> CONFIRMING: SignalSent (await user yes/no)  [verification replay]
    REPLAYING --> IDLE: SignalSent                             [arbitrary replay]
    REPLAYING --> IDLE: SignalSendingError / replay_timeout / cancel

    CONFIRMING --> CONFIRMED: confirm_capture(confirmed=True)
    CONFIRMING --> CAPTURING: confirm_capture(confirmed=False, retry=True)
    CONFIRMING --> IDLE: confirm_capture(cancel=True)

    CONFIRMED --> IDLE: signal saved (optionally renamed)
    CONFIRMED --> CAPTURING: learn another button
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from homeassistant.exceptions import HomeAssistantError

from .const import DOMAIN

if TYPE_CHECKING:
    from .coordinator import EvilCrowCoordinator

_LOGGER = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Wizard step names
# ---------------------------------------------------------------------------


class WizardStep:
    """Named steps for the guided target-device learning wizard."""

    IDLE = "idle"
    STARTED = "started"          # Wizard just launched — prompts user to press Learn
    CAPTURING = "capturing"      # Device is listening for a button press
    CONFIRMING = "confirming"    # Signal replayed, awaiting user confirm/retry
    NAMING_BUTTON = "naming"     # Awaiting user to name the captured button
    NEXT_PROMPT = "next_prompt"  # Asking if user wants to learn another button
    COMPLETE = "complete"        # Wizard finished successfully


@dataclass
class WizardData:
    """State for the guided target-device learning wizard.

    Created when the user presses "Add Target Remote" and persists until
    the wizard is completed or cancelled.
    """

    active: bool = False
    step: str = WizardStep.IDLE
    target_device_id: str = ""       # auto-generated HA device registry ID
    target_device_name: str = ""     # user-friendly name (e.g. "Garage Door")
    frequency: int = 433920000       # capture frequency in Hz
    modulation: str = "OOK_FIX"
    button_index: int = 0            # which button we're learning (1-based)
    total_buttons_learned: int = 0
    last_button_name: str = ""       # name of the most recently captured button
    error_message: str = ""


# ---------------------------------------------------------------------------
# Capture state
# ---------------------------------------------------------------------------


class CaptureStateValue:
    """Valid state values for the capture state machine."""

    IDLE = "idle"
    CAPTURING = "capturing"
    SIGNAL_CAPTURED = "captured"
    CONFIRMING = "confirming"
    CONFIRMED = "confirmed"
    REPLAYING = "replaying"
    ERROR = "error"


@dataclass
class CaptureState:
    """Current state of the capture/replay state machine.

    Attributes:
        state: One of CaptureStateValue constants.
        signal_file: Path of the captured .sub file on the device's SD card.
        raw_response: The raw parsed response dict from the device.
        timestamp: Monotonic timestamp of the last state transition.
        generation: Monotonic counter incremented on each new operation.
        error_message: Human-readable error message when state is ERROR.
        last_file_list: Most recent file list result from refresh_files().
        target_device_id: The HA device registry ID of the target RF remote.
        target_device_name: Friendly name of the target remote (e.g. "Garage Door").
        button_name: Name of the button being learned (e.g. "power").
        fcc_id: FCC ID used for frequency lookup (if any).
        frequency_mhz: Operating frequency in MHz for the capture.
        modulation: Modulation type (e.g. "OOK_FIX").
        is_verification_replay: True if the replay is for capture verification
            (auto-advance). When True, SignalSent transitions to CONFIRMING
            instead of IDLE.
    """

    state: str = CaptureStateValue.IDLE
    signal_file: str = ""
    raw_response: dict[str, Any] = field(default_factory=dict)
    timestamp: float = 0.0
    generation: int = 0
    error_message: str = ""
    last_file_list: list[str] = field(default_factory=list)
    target_device_id: str = ""
    target_device_name: str = ""
    button_name: str = ""
    fcc_id: str = ""
    frequency_mhz: float = 0.0
    modulation: str = "OOK_FIX"
    is_verification_replay: bool = False


# ---------------------------------------------------------------------------
# SubGhzService — captures, replays, renames, and deletes .sub files
# ---------------------------------------------------------------------------


class SubGhzService:
    """State machine for the RF capture/replay lifecycle on one device.

    One instance per EvilCrowRF device (per coordinator). The service is
    driven by:
      - Incoming WebSocket responses (handled by :meth:`handle_response`)
      - HA service calls (handled by :meth:`start_capture`, :meth:`replay_signal`,
        :meth:`rename_signal`, :meth:`refresh_files`, :meth:`cancel_capture`,
        :meth:`confirm_capture`)

    A **generation counter** is incremented on every new operation so that
    stale or out-of-order device responses are safely ignored.

    Callers can subscribe to state transitions via :meth:`on`::

        def on_captured(signal_file: str): ...
        subghz.on("signal_captured", on_captured)

    Supported events:
        ``capturing``, ``signal_captured``, ``confirming``, ``confirmed``,
        ``replaying``, ``idle``, ``error``, ``files_refreshed``
    """

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        protocol: Any | None = None,
    ) -> None:
        """Initialize the SubGhzService.

        Args:
            coordinator: The coordinator for the EvilCrowRF device.
            protocol: An EvilCrowBinaryProtocol instance. If not provided,
                falls back to ``coordinator._protocol``.
        """
        self._coordinator = coordinator
        self._protocol = protocol or coordinator._protocol
        self._state = CaptureState()
        self._lock = asyncio.Lock()
        self._response_event = asyncio.Event()
        self._event_callbacks: dict[str, list[Any]] = {}

    def on(self, event: str, callback: Any) -> None:
        """Register a callback for a state-transition event.

        Args:
            event: One of ``capturing``, ``signal_captured``, ``confirming``,
                ``confirmed``, ``replaying``, ``idle``, ``error``,
                ``files_refreshed``.
            callback: Async or sync callable. If async, it is scheduled
                via ``hass.async_create_task``.
        """
        self._event_callbacks.setdefault(event, []).append(callback)

    def _emit(self, event: str, *args: Any) -> None:
        """Fire an event to all registered callbacks.

        Args:
            event: The event name.
            args: Passed to each callback.
        """
        for cb in self._event_callbacks.get(event, []):
            try:
                cb(*args)
            except Exception:  # noqa: BLE001
                _LOGGER.exception("SubGhz event callback for %s failed", event)

    # ------------------------------------------------------------------
    # Public properties
    # ------------------------------------------------------------------

    @property
    def state(self) -> CaptureState:
        """Return the current capture state (thread-safe snapshot)."""
        return self._state

    # ------------------------------------------------------------------
    # Public commands
    # ------------------------------------------------------------------

    async def start_capture(
        self,
        frequency: int,
        module: int = 0,
        preset: str = "",
        *,
        target_device_id: str = "",
        target_device_name: str = "",
        button_name: str = "",
        fcc_id: str = "",
    ) -> CaptureState:
        """Begin capturing an RF signal for a target device button.

        Sends a CMD_START_RECORDING frame to the device. Returns the
        current state snapshot immediately; the device will respond
        asynchronously via :meth:`handle_response`. On SignalRecorded,
        the state machine auto-advances to replay the captured signal
        for verification.

        Args:
            frequency: Frequency in Hz.
            module: CC1101 module index (0 or 1).
            preset: Flipper SubGhz preset value.
            target_device_id: HA device registry ID of the target RF remote.
            target_device_name: Friendly name (e.g. "Garage Door").
            button_name: Name of the button being learned (e.g. "power").
            fcc_id: FCC ID used for frequency lookup (informational).

        Returns:
            The updated CaptureState (CAPTURING on success, ERROR on failure).

        Raises:
            HomeAssistantError: If frequency is out of valid range or the
                device is already in a non-idle state.
        """
        if frequency <= 0 or frequency > 10_000_000_000:
            raise HomeAssistantError(
                f"Invalid frequency {frequency} Hz. Must be between 1 and 10,000,000,000 Hz.",
                translation_domain=DOMAIN,
                translation_key="invalid_frequency",
                translation_placeholders={"frequency": str(frequency)},
            )
        if module not in (0, 1):
            raise HomeAssistantError(
                f"Invalid module {module}. Must be 0 or 1.",
                translation_domain=DOMAIN,
                translation_key="invalid_module",
                translation_placeholders={"module": str(module)},
            )

        async with self._lock:
            if self._state.state not in (
                CaptureStateValue.IDLE,
                CaptureStateValue.CONFIRMED,
                CaptureStateValue.ERROR,
            ):
                raise HomeAssistantError(
                    f"Cannot start capture while in state '{self._state.state}'. "
                    f"Cancel the current operation first.",
                    translation_domain=DOMAIN,
                    translation_key="capture_busy",
                    translation_placeholders={"state": self._state.state},
                )

            self._increment_generation()
            self._state.state = CaptureStateValue.CAPTURING
            self._state.error_message = ""
            self._state.signal_file = ""
            self._state.raw_response = {}
            # Store capture context
            self._state.target_device_id = target_device_id
            self._state.target_device_name = target_device_name
            self._state.button_name = button_name
            self._state.fcc_id = fcc_id
            self._state.frequency_mhz = frequency / 1_000_000
            self._state.is_verification_replay = False

            frames = self._protocol.build_request_record_command(
                frequency=frequency,
                module=module,
                preset=preset,
            )

            sent = await self._coordinator.transport.send_frame(frames)
            if not sent:
                self._state.state = CaptureStateValue.ERROR
                self._state.error_message = "Failed to send capture command to device."
                return self._state

        _LOGGER.debug(
            "Capture started on device %s: freq=%d Hz, module=%d, preset=%d, target=%s, button=%s",
            self._coordinator.device_info.device_id,
            frequency,
            module,
            preset,
            target_device_id,
            button_name,
        )
        self._coordinator.async_update_listeners()
        self._emit("capturing", frequency)
        return self._state

    async def cancel_capture(self) -> CaptureState:
        """Cancel any in-progress capture or replay operation.

        Sends CMD_IDLE to stop radio activity and resets the state to IDLE.
        Also cancels any active wizard session.

        Returns:
            The updated CaptureState.
        """
        async with self._lock:
            prev_state = self._state.state
            self._increment_generation()
            self._state.state = CaptureStateValue.IDLE
            self._state.signal_file = ""
            self._state.error_message = ""
            self._state.raw_response = {}

            frames = self._protocol.build_idle_command()
            await self._coordinator.transport.send_frame(frames)

        # Cancel wizard if active
        self.__init_wizard()
        if self._wizard.active:
            self._wizard.active = False
            self._wizard.step = WizardStep.IDLE
            _LOGGER.debug(
                "Wizard cancelled via cancel_capture on device %s",
                self._coordinator.device_info.device_id,
            )

        _LOGGER.debug(
            "Capture cancelled on device %s (was %s)",
            self._coordinator.device_info.device_id,
            prev_state,
        )
        self._coordinator.async_update_listeners()
        self._emit("idle", "cancelled")
        return self._state

    async def replay_signal(self, file_path: str, verify: bool = False) -> CaptureState:
        """Replay a previously captured .sub signal.

        When *verify* is True (capture-verification replay), the state
        machine expects a ``SignalSent`` response to transition to
        CONFIRMING instead of IDLE. This is set automatically by
        :meth:`handle_response` after a capture completes.

        Args:
            file_path: Full path to the .sub file on the device's SD card.
            verify: If True, marks this replay as a verification replay
                so SignalSent goes to CONFIRMING, not IDLE.

        Returns:
            The updated CaptureState (REPLAYING on success, ERROR on failure).

        Raises:
            HomeAssistantError: If file_path is empty or the device is not
                in an idle state.
        """
        if not file_path or not file_path.strip():
            raise HomeAssistantError(
                "Signal file path must not be empty.",
                translation_domain=DOMAIN,
                translation_key="empty_file_path",
            )

        async with self._lock:
            if self._state.state not in (
                CaptureStateValue.IDLE,
                CaptureStateValue.CONFIRMED,
                CaptureStateValue.SIGNAL_CAPTURED,
            ):
                raise HomeAssistantError(
                    f"Cannot replay signal while in state '{self._state.state}'. "
                    f"Cancel the current operation first.",
                    translation_domain=DOMAIN,
                    translation_key="replay_busy",
                    translation_placeholders={"state": self._state.state},
                )

            self._increment_generation()
            self._state.state = CaptureStateValue.REPLAYING
            self._state.signal_file = file_path
            self._state.error_message = ""
            self._state.is_verification_replay = verify

            frames = self._protocol.build_send_signal_command(file_path)
            sent = await self._coordinator.transport.send_frame(frames)
            if not sent:
                self._state.state = CaptureStateValue.ERROR
                self._state.error_message = "Failed to send replay command to device."
                return self._state

        _LOGGER.debug(
            "Replaying signal on device %s: %s (verify=%s)",
            self._coordinator.device_info.device_id,
            file_path,
            verify,
        )
        self._coordinator.async_update_listeners()
        self._emit("replaying", file_path)
        return self._state

    async def rename_signal(self, old_path: str, new_path: str) -> CaptureState:
        """Rename a .sub file on the device's SD card.

        Args:
            old_path: Current full path of the .sub file.
            new_path: Desired full path of the .sub file.

        Returns:
            The updated CaptureState.

        Raises:
            HomeAssistantError: If either path is empty.
        """
        if not old_path or not old_path.strip():
            raise HomeAssistantError(
                "Old file path must not be empty.",
                translation_domain=DOMAIN,
                translation_key="empty_file_path",
            )
        if not new_path or not new_path.strip():
            raise HomeAssistantError(
                "New file path must not be empty.",
                translation_domain=DOMAIN,
                translation_key="empty_file_path",
            )

        async with self._lock:
            self._increment_generation()
            frames = self._protocol.build_file_rename_command(old_path, new_path)
            sent = await self._coordinator.transport.send_frame(frames)
            if not sent:
                self._state.state = CaptureStateValue.ERROR
                self._state.error_message = "Failed to send rename command to device."
                return self._state

        _LOGGER.debug(
            "Renaming signal on device %s: %s -> %s",
            self._coordinator.device_info.device_id,
            old_path,
            new_path,
        )
        return self._state

    async def refresh_files(self) -> list[str]:
        """Request an updated list of .sub files from the device's SD card.

        Sends CMD_FILE_LIST and stores the result in
        ``self._state.last_file_list``.

        Returns:
            The list of .sub file paths on the device.
        """
        async with self._lock:
            self._increment_generation()
            frames = self._protocol.build_file_list_command()
            sent = await self._coordinator.transport.send_frame(frames)
            if not sent:
                _LOGGER.warning(
                    "Failed to send file list request to device %s",
                    self._coordinator.device_info.device_id,
                )
                return list(self._state.last_file_list)

        _LOGGER.debug(
            "Refreshing file list on device %s",
            self._coordinator.device_info.device_id,
        )
        return list(self._state.last_file_list)

    async def confirm_capture(
        self,
        confirmed: bool,
        *,
        cancel: bool = False,
        next_button: str | None = None,
    ) -> CaptureState:
        """Confirm, retry, or cancel the last capture.

        Called after the user has verified the replayed signal:

        - ``confirmed=True``: persist the button-to-signal mapping in
          TargetDeviceStore, transition to CONFIRMED, then return to
          IDLE. If *next_button* is provided, keep state in CONFIRMED
          so the caller can call :meth:`start_capture` again for the
          next button.
        - ``confirmed=False, cancel=False``: transition back to
          CAPTURING to retry the same button.
        - ``cancel=True``: same as :meth:`cancel_capture`.

        Args:
            confirmed: Whether the target device responded to the replay.
            cancel: If True, abort capture and return to IDLE.
            next_button: If confirmed and more buttons to learn, the
                name of the next button to capture.

        Returns:
            The updated CaptureState.

        Raises:
            HomeAssistantError: If the state machine is not in
                CONFIRMING state.
        """
        if cancel:
            return await self.cancel_capture()

        async with self._lock:
            if self._state.state != CaptureStateValue.CONFIRMING:
                raise HomeAssistantError(
                    f"Cannot confirm capture while in state '{self._state.state}'. "
                    f"Expected CONFIRMING state.",
                    translation_domain=DOMAIN,
                    translation_key="confirm_not_capturing",
                    translation_placeholders={"state": self._state.state},
                )

            if not confirmed:
                # Retry: go back to CAPTURING for the same button
                self._increment_generation()
                self._state.state = CaptureStateValue.CAPTURING
                self._state.error_message = ""
                self._state.signal_file = ""
                self._state.is_verification_replay = False

                # Re-arm the recording command
                freq_hz = (
                    int(self._state.frequency_mhz * 1_000_000)
                    if (self._state.frequency_mhz)
                    else 433920000
                )
                frames = self._protocol.build_request_record_command(
                    frequency=freq_hz,
                    module=0,
                )
                sent = await self._coordinator.transport.send_frame(frames)
                if not sent:
                    self._state.state = CaptureStateValue.ERROR
                    self._state.error_message = "Failed to re-send capture command for retry."

                _LOGGER.debug(
                    "Capture retry on device %s: button=%s",
                    self._coordinator.device_info.device_id,
                    self._state.button_name,
                )
                self._coordinator.async_update_listeners()
                self._emit("capturing", "retry")
                return self._state

            # ---- confirmed=True ----
            target_device_id = self._state.target_device_id
            button_name = self._state.button_name
            signal_file = self._state.signal_file

            if not target_device_id:
                raise HomeAssistantError(
                    "No target device set. Use start_capture with a target_device_id first.",
                    translation_domain=DOMAIN,
                    translation_key="empty_target_device_id",
                )
            if not button_name:
                raise HomeAssistantError(
                    "No button name set.",
                    translation_domain=DOMAIN,
                    translation_key="empty_button_name",
                )
            if not signal_file:
                raise HomeAssistantError(
                    "No signal file captured.",
                    translation_domain=DOMAIN,
                    translation_key="empty_file_path",
                )

            # Check if wizard is active — wizard_on_confirmed handles persistence
            self.__init_wizard()
            wizard_active = self._wizard.active

            if not wizard_active:
                # Non-wizard mode: persist the button mapping directly
                store = self._coordinator.target_store
                if store is not None:
                    store.add_button(target_device_id, button_name, signal_file)
                    await store.async_save()

            if next_button:
                # Keep CONFIRMED so the caller can call start_capture for the next button
                self._state.state = CaptureStateValue.CONFIRMED
                self._state.button_name = next_button
                self._state.signal_file = ""
                self._state.is_verification_replay = False
            else:
                # Done with all buttons
                self._state.state = CaptureStateValue.IDLE

            self._increment_generation()

        _LOGGER.debug(
            "Capture confirmed on device %s: target=%s, button=%s, file=%s, next_button=%s",
            self._coordinator.device_info.device_id,
            target_device_id,
            button_name,
            signal_file,
            next_button,
        )
        self._coordinator.async_update_listeners()
        self._emit("confirmed", self._state.signal_file)
        # Notify wizard state machine — wizard_on_confirmed persists the mapping
        if wizard_active:
            hass = self._coordinator.hass
            if hass is not None:
                hass.async_create_task(self.wizard_on_confirmed())
            else:
                self._wizard.step = WizardStep.NEXT_PROMPT
        return self._state

    # ------------------------------------------------------------------
    # Incoming response handling
    # ------------------------------------------------------------------

    async def handle_response(self, parsed: dict[str, Any]) -> None:
        """Process an incoming response from the device.

        This is called by the coordinator's message dispatcher whenever a
        WebSocket frame arrives. The method checks the generation counter to
        reject stale responses.

        Args:
            parsed: The parsed response dict from
                :meth:`EvilCrowBinaryProtocol.parse_response`.
        """
        response_type = parsed.get("type", "")
        data = parsed.get("data", {})

        async with self._lock:
            current_gen = self._state.generation

        _LOGGER.debug(
            "SubGhzService handling response: type=%s, data=%s, gen=%d",
            response_type,
            data,
            current_gen,
        )

        if response_type == "SignalDetected":
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                self._state.state = CaptureStateValue.CAPTURING
                self._state.raw_response = data
            self._coordinator.async_update_listeners()

        elif response_type == "SignalRecorded":
            filename = data.get("filename", "")
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                self._state.state = CaptureStateValue.SIGNAL_CAPTURED
                self._state.signal_file = filename
                self._state.raw_response = data
            _LOGGER.info(
                "Signal captured on device %s: %s",
                self._coordinator.device_info.device_id,
                filename,
            )
            self._coordinator.async_update_listeners()
            self._emit("signal_captured", filename)
            # Stop recording on the device — firmware auto-restarts after each save,
            # so we must explicitly send IDLE to prevent spam.
            await self._send_idle()
            # Notify wizard state machine
            self.__init_wizard()
            if self._wizard.active:
                self._wizard.step = WizardStep.NAMING_BUTTON
                self._coordinator.async_update_listeners()
            # Auto-advance: replay the captured signal for verification
            if self._state.state == CaptureStateValue.SIGNAL_CAPTURED:
                hass = self._coordinator.hass
                if hass is not None:
                    hass.async_create_task(self.replay_signal(filename, verify=True))

        elif response_type == "SignalSent":
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                # Verification replay → go to CONFIRMING
                # Arbitrary replay → go to IDLE
                if self._state.is_verification_replay:
                    self._state.state = CaptureStateValue.CONFIRMING
                else:
                    self._state.state = CaptureStateValue.IDLE
                self._state.raw_response = data
            _LOGGER.info(
                "Signal sent on device %s (verification=%s)",
                self._coordinator.device_info.device_id,
                self._state.is_verification_replay,
            )
            self._coordinator.async_update_listeners()
            if self._state.state == CaptureStateValue.CONFIRMING:
                self._emit("confirming", self._state.signal_file)
                # Notify wizard state machine
                self.__init_wizard()
                if self._wizard.active:
                    self._wizard.step = WizardStep.CONFIRMING
                    self._coordinator.async_update_listeners()
                    self._emit("wizard_confirming", self._wizard.last_button_name)
            else:
                self._emit("idle", "signal_sent")

        elif response_type in ("SignalError", "SignalSendingError"):
            message = data.get("message", "Unknown error")
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                self._state.state = CaptureStateValue.ERROR
                self._state.error_message = message
                self._state.raw_response = data
            _LOGGER.warning(
                "Signal error on device %s: %s",
                self._coordinator.device_info.device_id,
                message,
            )
            self._coordinator.async_update_listeners()
            self._emit("error", message)

        elif response_type == "FileList":
            files = data.get("files", [])
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                self._state.last_file_list = files
            _LOGGER.debug(
                "File list updated on device %s: %d files",
                self._coordinator.device_info.device_id,
                len(files),
            )
            self._coordinator.async_update_listeners()
            self._emit("files_refreshed", len(files))

        elif response_type == "FileAction":
            action = data.get("action", "")
            message = data.get("message", "")
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                self._state.raw_response = data
            _LOGGER.debug(
                "File action on device %s: %s -> %s",
                self._coordinator.device_info.device_id,
                action,
                message,
            )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _increment_generation(self) -> None:
        """Increment the generation counter, wrapping to avoid overflow."""
        self._state.generation = (self._state.generation + 1) & 0xFFFFFFFF
        self._state.timestamp = time.monotonic()

    async def _send_idle(self) -> None:
        """Send CMD_IDLE to stop any active recording/replay on the device.

        Does not change the HA state machine — only tells the device to
        stop its radio activity.  The firmware auto-restarts recording
        after each saved .sub file, so we must explicitly idle the module
        after receiving a SignalRecorded to prevent signal spam.
        """
        frames = self._protocol.build_idle_command()
        await self._coordinator.transport.send_frame(frames)
        _LOGGER.debug(
            "Sent IDLE to device %s", self._coordinator.device_info.device_id
        )

    @property
    def is_busy(self) -> bool:
        """Return True if the state machine is in a non-idle state."""
        return self._state.state not in (
            CaptureStateValue.IDLE,
            CaptureStateValue.CONFIRMED,
            CaptureStateValue.ERROR,
        )

    # ------------------------------------------------------------------
    # Guided wizard (Add Target Remote -> interactive multi-step flow)
    # ------------------------------------------------------------------

    def __init_wizard(self) -> None:
        """Initialize wizard dataclass if not already present."""
        if not hasattr(self, "_wizard"):
            self._wizard = WizardData()

    @property
    def wizard(self) -> WizardData:
        """Return the current wizard session data."""
        self.__init_wizard()
        return self._wizard

    async def wizard_start(
        self,
        target_device_name: str = "",
        frequency: int = 433920000,
        modulation: str = "OOK_FIX",
    ) -> None:
        """Start a guided target-device learning wizard session.

        Creates a new wizard session, auto-generates a target_device_id,
        and sets the step to STARTED. Call this when the user presses
        "Add Target Remote".

        Args:
            target_device_name: Friendly name for the remote (e.g. "Garage Door").
            frequency: Operating frequency in Hz (default 433920000).
            modulation: Modulation type (default "OOK_FIX").
        """
        self.__init_wizard()
        self._wizard.active = True
        self._wizard.step = WizardStep.STARTED
        self._wizard.target_device_id = (
            f"ec_target_{int(time.time())}_{id(self)}"
        )
        self._wizard.target_device_name = (
            target_device_name or f"Remote #{self._wizard.target_device_id[-6:]}"
        )
        self._wizard.frequency = frequency
        self._wizard.modulation = modulation
        self._wizard.button_index = 0
        self._wizard.total_buttons_learned = 0
        self._wizard.last_button_name = ""
        self._wizard.error_message = ""

        _LOGGER.info(
            "Wizard started on device %s: target='%s', id='%s'",
            self._coordinator.device_info.device_id,
            self._wizard.target_device_name,
            self._wizard.target_device_id,
        )
        self._coordinator.async_update_listeners()
        self._emit("wizard_started", self._wizard.target_device_name)

    async def wizard_cancel(self) -> None:
        """Cancel an active wizard session and return to IDLE."""
        self.__init_wizard()
        if not self._wizard.active:
            return
        self._wizard.active = False
        self._wizard.step = WizardStep.IDLE
        _LOGGER.info(
            "Wizard cancelled on device %s",
            self._coordinator.device_info.device_id,
        )
        self._coordinator.async_update_listeners()
        self._emit("wizard_cancelled")

    async def wizard_advance_to_capture(self) -> None:
        """Advance wizard to capture step and start listening.

        Called when the user presses Learn Signal during an active wizard.
        Increments the button index and sets the wizard step to CAPTURING.
        """
        if not self._wizard.active:
            return
        self._wizard.button_index += 1
        self._wizard.step = WizardStep.CAPTURING
        self._wizard.last_button_name = f"button_{self._wizard.button_index}"
        _LOGGER.debug(
            "Wizard advancing to capture: button #%d on device %s",
            self._wizard.button_index,
            self._coordinator.device_info.device_id,
        )
        self._coordinator.async_update_listeners()
        self._emit("wizard_capturing", self._wizard.button_index)

    async def wizard_on_signal_captured(self) -> None:
        """Called when a signal is captured during wizard mode.

        Moves wizard to naming step so the user can name the button
        after the verification replay completes.
        """
        if not self._wizard.active:
            return
        self._wizard.step = WizardStep.NAMING_BUTTON
        self._coordinator.async_update_listeners()

    async def wizard_on_confirming(self) -> None:
        """Called when capture enters CONFIRMING state during wizard mode."""
        if not self._wizard.active:
            return
        self._wizard.step = WizardStep.CONFIRMING
        self._coordinator.async_update_listeners()
        self._emit("wizard_confirming", self._wizard.last_button_name)

    async def wizard_set_button_name(self, name: str) -> None:
        """Set the name for the most recently captured button.

        Args:
            name: The button name (e.g. "power", "open").
        """
        if not self._wizard.active:
            return
        name = name.strip() or f"button_{self._wizard.button_index}"
        self._wizard.last_button_name = name
        self._coordinator.async_update_listeners()

    async def wizard_on_confirmed(self) -> None:
        """Called after the user confirms a capture in wizard mode.

        Persists the button mapping to TargetDeviceStore and prompts
        for the next button.
        """
        if not self._wizard.active:
            return
        self._wizard.total_buttons_learned += 1

        # Persist button mapping
        store = self._coordinator.target_store
        if store is not None:
            # Register target device if not yet known
            from .target_device_store import TargetDevice

            existing = store.get(self._wizard.target_device_id)
            if existing is None:
                device = TargetDevice(
                    target_device_id=self._wizard.target_device_id,
                    name=self._wizard.target_device_name,
                    ec_device_id=self._coordinator.device_info.device_id,
                    frequency=self._wizard.frequency / 1_000_000,
                    modulation=self._wizard.modulation,
                    buttons={},
                )
                store.register(device)

                # Register in HA device registry so it appears on the
                # integration page under the EC device
                from .__init__ import _register_target_device_in_registry

                _register_target_device_in_registry(
                    hass=self._coordinator.hass,
                    config_entry_id=self._coordinator.config_entry.entry_id,
                    target_device_id=self._wizard.target_device_id,
                    target_device_name=self._wizard.target_device_name,
                    ec_device_id=self._coordinator.device_info.device_id,
                )

            # Add the button mapping
            store.add_button(
                self._wizard.target_device_id,
                self._wizard.last_button_name,
                self._state.signal_file,
            )

            try:
                await store.async_save()
            except Exception:  # noqa: BLE001
                _LOGGER.exception("Failed to save target device store")
                self._wizard.error_message = "Failed to save button mapping."

        _LOGGER.info(
            "Wizard: button '%s' saved for target '%s' on device %s (file: %s)",
            self._wizard.last_button_name,
            self._wizard.target_device_name,
            self._coordinator.device_info.device_id,
            self._state.signal_file,
        )
        self._wizard.step = WizardStep.NEXT_PROMPT
        self._coordinator.async_update_listeners()
        self._emit("wizard_button_saved", self._wizard.last_button_name)

    async def wizard_next_button(self) -> None:
        """Advance the wizard to capture the next button.

        Resets the capture state and increments the button index,
        ready for the next :meth:`start_capture` call.
        """
        if not self._wizard.active:
            return
        self._wizard.step = WizardStep.STARTED
        self._coordinator.async_update_listeners()
        self._emit("wizard_next_button", self._wizard.button_index + 1)

    async def wizard_complete(self) -> None:
        """Mark the wizard as complete.

        Finalizes the session: sets step to COMPLETE, emits event.
        """
        if not self._wizard.active:
            return
        self._wizard.step = WizardStep.COMPLETE
        self._wizard.active = False
        _LOGGER.info(
            "Wizard completed on device %s: target='%s', %d buttons learned",
            self._coordinator.device_info.device_id,
            self._wizard.target_device_name,
            self._wizard.total_buttons_learned,
        )
        self._coordinator.async_update_listeners()
        self._emit("wizard_complete", self._wizard.total_buttons_learned)

    @property
    def wizard_is_active(self) -> bool:
        """Return True if a wizard session is currently active."""
        self.__init_wizard()
        return self._wizard.active
