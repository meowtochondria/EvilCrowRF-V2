"""SubGhzService state machine for capture/replay lifecycle.

Manages the lifecycle of capturing, confirming, and replaying RF signals
on an EvilCrowRF device. State transitions are driven by WebSocket messages
from the device and service calls from Home Assistant.
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
    """

    state: str = CaptureStateValue.IDLE
    signal_file: str = ""
    raw_response: dict[str, Any] = field(default_factory=dict)
    timestamp: float = 0.0
    generation: int = 0
    error_message: str = ""
    last_file_list: list[str] = field(default_factory=list)


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
        preset: int = 0,
    ) -> CaptureState:
        """Begin capturing an RF signal.

        Sends a CMD_START_RECORDING frame to the device. Returns the
        current state snapshot immediately; the device will respond
        asynchronously via :meth:`handle_response`.

        Args:
            frequency: Frequency in Hz.
            module: CC1101 module index (0 or 1).
            preset: Flipper SubGhz preset value.

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
            "Capture started on device %s: freq=%d Hz, module=%d, preset=%d",
            self._coordinator.device_info.device_id,
            frequency,
            module,
            preset,
        )
        self._coordinator.async_update_listeners()
        return self._state

    async def cancel_capture(self) -> CaptureState:
        """Cancel any in-progress capture or replay operation.

        Sends CMD_IDLE to stop radio activity and resets the state to IDLE.

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

        _LOGGER.debug(
            "Capture cancelled on device %s (was %s)",
            self._coordinator.device_info.device_id,
            prev_state,
        )
        self._coordinator.async_update_listeners()
        return self._state

    async def replay_signal(self, file_path: str) -> CaptureState:
        """Replay a previously captured .sub signal.

        Args:
            file_path: Full path to the .sub file on the device's SD card.

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

            frames = self._protocol.build_send_signal_command(file_path)
            sent = await self._coordinator.transport.send_frame(frames)
            if not sent:
                self._state.state = CaptureStateValue.ERROR
                self._state.error_message = "Failed to send replay command to device."
                return self._state

        _LOGGER.debug(
            "Replaying signal on device %s: %s",
            self._coordinator.device_info.device_id,
            file_path,
        )
        self._coordinator.async_update_listeners()
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
        target_device_id: str,
        button_name: str,
        signal_file: str,
    ) -> CaptureState:
        """Confirm a captured signal and associate it with a target device.

        Transitions the state machine to CONFIRMED and persists the
        button-to-signal mapping in the TargetDeviceStore.

        Args:
            target_device_id: The HA device registry ID of the target remote.
            button_name: The name of the button on the remote (e.g. "button_a").
            signal_file: The .sub file path on the device's SD card.

        Returns:
            The updated CaptureState (CONFIRMED on success, ERROR on failure).

        Raises:
            HomeAssistantError: If inputs are invalid or no signal is currently
                captured.
        """
        if not target_device_id or not target_device_id.strip():
            raise HomeAssistantError(
                "Target device ID must not be empty.",
                translation_domain=DOMAIN,
                translation_key="empty_target_device_id",
            )
        if not button_name or not button_name.strip():
            raise HomeAssistantError(
                "Button name must not be empty.",
                translation_domain=DOMAIN,
                translation_key="empty_button_name",
            )
        if not signal_file or not signal_file.strip():
            raise HomeAssistantError(
                "Signal file path must not be empty.",
                translation_domain=DOMAIN,
                translation_key="empty_file_path",
            )

        async with self._lock:
            if self._state.state not in (
                CaptureStateValue.SIGNAL_CAPTURED,
                CaptureStateValue.CAPTURING,
            ):
                raise HomeAssistantError(
                    f"Cannot confirm capture while in state '{self._state.state}'. "
                    f"A capture must be in progress.",
                    translation_domain=DOMAIN,
                    translation_key="confirm_not_capturing",
                    translation_placeholders={"state": self._state.state},
                )

            self._state.state = CaptureStateValue.CONFIRMING
            self._state.signal_file = signal_file

        # Persist the button mapping
        store = self._coordinator.target_store
        if store is not None:
            store.add_button(target_device_id, button_name, signal_file)
            await store.async_save()

        async with self._lock:
            self._state.state = CaptureStateValue.CONFIRMED
            self._increment_generation()

        _LOGGER.debug(
            "Capture confirmed on device %s: target=%s, button=%s, file=%s",
            self._coordinator.device_info.device_id,
            target_device_id,
            button_name,
            signal_file,
        )
        self._coordinator.async_update_listeners()
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

        elif response_type == "SignalSent":
            async with self._lock:
                if self._state.generation != current_gen:
                    return  # Stale
                self._state.state = CaptureStateValue.IDLE
                self._state.raw_response = data
            _LOGGER.info(
                "Signal sent on device %s",
                self._coordinator.device_info.device_id,
            )
            self._coordinator.async_update_listeners()

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

    @property
    def is_busy(self) -> bool:
        """Return True if the state machine is in a non-idle state."""
        return self._state.state not in (
            CaptureStateValue.IDLE,
            CaptureStateValue.CONFIRMED,
            CaptureStateValue.ERROR,
        )
