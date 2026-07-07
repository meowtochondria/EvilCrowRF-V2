"""Notification manager for the EvilCrowRF V2 integration.

Owns the lifecycle of all ``persistent_notification`` calls for a single
EvilCrowRF device. Subscribes to ``SubGhzService`` events and reacts
to state transitions — it does not reach into the transport, protocol,
or service layers.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from homeassistant.core import HomeAssistant

from .const import (
    NOTIFY_CONFIRM_CAPTURE,
    NOTIFY_ONBOARDING,
    NOTIFY_WIZARD_STEP,
)

if TYPE_CHECKING:
    from .coordinator import EvilCrowCoordinator

_LOGGER = logging.getLogger(__name__)


class NotificationManager:
    """Manages persistent_notifications for one EvilCrowRF device.

    Subscribes to :class:`SubGhzService` events and shows/dismisses
    notifications accordingly.
    """

    def __init__(
        self,
        hass: HomeAssistant,
        coordinator: EvilCrowCoordinator,
    ) -> None:
        """Initialize the notification manager.

        Args:
            hass: The HomeAssistant instance.
            coordinator: The device coordinator.
        """
        self._hass = hass
        self._coordinator = coordinator
        self._device_id = coordinator.device_info.device_id
        self._subscribed = False

    def subscribe(self) -> None:
        """Register callbacks on the coordinator's SubGhzService events.

        Safe to call multiple times — only subscribes once.
        """
        if self._subscribed:
            return
        subghz = self._coordinator.subghz
        if subghz is None:
            return

        subghz.on("confirming", self._on_confirming)
        subghz.on("confirmed", self._on_confirmed)
        subghz.on("idle", self._on_idle)
        subghz.on("error", self._on_error)

        self._subscribed = True
        _LOGGER.debug(
            "NotificationManager subscribed to subghz events for device %s",
            self._device_id,
        )

    # ------------------------------------------------------------------
    # Onboarding notification
    # ------------------------------------------------------------------

    def show_onboarding(self, device_name: str) -> None:
        """Show a first-time-setup notification if no targets are learned.

        Called from ``async_setup_entry`` after a successful connection.
        """
        notify_id = f"{NOTIFY_ONBOARDING}_{self._device_id}"
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": "EvilCrowRF V2 — Ready!",
                "message": (
                    f"## EvilCrowRF V2 device **{device_name}** is connected!\n\n"
                    "### Next steps:\n\n"
                    "1. Go to **Settings → Devices & Services → EvilCrowRF V2**\n"
                    '2. Click **"Add Target Remote"** on the device page\n'
                    "3. Follow the wizard to learn RF signals\n\n"
                    "---\n"
                    "> **Tip**: Place your remote within 1–2 meters of the\n"
                    "> EvilCrowRF device for best capture results.\n"
                ),
            },
            blocking=False,
        )

    def dismiss_onboarding(self) -> None:
        """Dismiss the onboarding notification."""
        notify_id = f"{NOTIFY_ONBOARDING}_{self._device_id}"
        self._hass.services.async_call(
            "persistent_notification",
            "dismiss",
            {"notification_id": notify_id},
            blocking=False,
        )

    # ------------------------------------------------------------------
    # Confirm-capture notification
    # ------------------------------------------------------------------

    def _on_confirming(self, signal_file: str) -> None:
        """Show the confirm-capture prompt."""
        state = self._coordinator.subghz.state if self._coordinator.subghz else None
        notify_id = f"{NOTIFY_CONFIRM_CAPTURE}_{self._device_id}"
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": "EvilCrowRF — Confirm Capture",
                "message": (
                    f"## Signal captured and replayed\n\n"
                    f"Device: **{self._coordinator.device_info.name}**\n"
                    f"Button: **{state.button_name if state else 'unknown'}**\n"
                    f"File: `{signal_file}`\n\n"
                    "Did the target device respond?\n\n"
                    "Use the **Confirm Yes / Confirm No / Confirm Cancel** "
                    "buttons on the device page, or call the "
                    "`evilcrow_rf.confirm_capture` service.\n\n"
                    "| Action | Parameters |\n"
                    "|---|---|\n"
                    "| ✅ Yes | `confirmed: true` |\n"
                    "| 🔄 Retry | `confirmed: false` |\n"
                    "| ❌ Cancel | `cancel: true` |\n"
                ),
            },
            blocking=False,
        )

    def _on_confirmed(self, _signal_file: str) -> None:
        """Dismiss the confirm-capture notification on confirmation."""
        self.dismiss_confirm()

    def _on_idle(self, _reason: str) -> None:
        """Dismiss the confirm-capture notification when state resets."""
        self.dismiss_confirm()
        self.dismiss_wizard()

    def _on_error(self, _message: str) -> None:
        """Dismiss the confirm-capture notification on error."""
        self.dismiss_confirm()

    def dismiss_confirm(self) -> None:
        """Dismiss the confirm-capture notification."""
        notify_id = f"{NOTIFY_CONFIRM_CAPTURE}_{self._device_id}"
        self._hass.services.async_call(
            "persistent_notification",
            "dismiss",
            {"notification_id": notify_id},
            blocking=False,
        )

    # ------------------------------------------------------------------
    # Wizard notification
    # ------------------------------------------------------------------

    def dismiss_wizard(self) -> None:
        """Dismiss the wizard step notification."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        self._hass.services.async_call(
            "persistent_notification",
            "dismiss",
            {"notification_id": notify_id},
            blocking=False,
        )
