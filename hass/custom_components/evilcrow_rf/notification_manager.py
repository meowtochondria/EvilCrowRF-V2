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

        # Wizard event handlers
        subghz.on("wizard_started", self._on_wizard_started)
        subghz.on("wizard_capturing", self._on_wizard_capturing)
        subghz.on("wizard_confirming", self._on_wizard_confirming)
        subghz.on("wizard_button_saved", self._on_wizard_button_saved)
        subghz.on("wizard_next_button", self._on_wizard_next_button)
        subghz.on("wizard_complete", self._on_wizard_complete)
        subghz.on("wizard_cancelled", self._on_wizard_cancelled)

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
        subghz = self._coordinator.subghz
        subghz_wiz = getattr(subghz, "wizard", None) if subghz else None
        in_wizard = subghz_wiz is not None and subghz_wiz.active

        if in_wizard:
            # Wizard mode: show a wizard-specific confirm prompt
            notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
            button_name = subghz_wiz.last_button_name if subghz_wiz else "unknown"
            target_name = subghz_wiz.target_device_name if subghz_wiz else "unknown"
            self._hass.services.async_call(
                "persistent_notification",
                "create",
                {
                    "notification_id": notify_id,
                    "title": f"EvilCrowRF — Wizard: {target_name}",
                    "message": (
                        f"## 🎯 Step: Confirm Button **{button_name}**\n\n"
                        f"Learning remote: **{target_name}**\n"
                        f"Captured file: `{signal_file}`\n\n"
                        "The signal has been **replayed** for verification.\n\n"
                        "**Did the target device respond?**\n\n"
                        "| Button | Action |\n"
                        "|---|---|\n"
                        "| ✅ **Confirm Yes** | Save this button and continue |\n"
                        "| 🔄 **Confirm No** | Retry capturing the same button |\n"
                        "| ❌ **Confirm Cancel** | Cancel the entire wizard |\n"
                        "\n---\n"
                        "> **Tip**: After confirming, you can name the button "
                        "via the 'Rename Signal' text field before pressing Yes."
                    ),
                },
                blocking=False,
            )
            return

        # Non-wizard mode: standard confirm prompt
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
        """Dismiss notifications when state resets."""
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
    # Wizard notifications
    # ------------------------------------------------------------------

    def _on_wizard_started(self, target_name: str) -> None:
        """Show the first wizard step: press Learn to capture button 1."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        device_name = self._coordinator.device_info.name
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": "EvilCrowRF — Target Remote Setup",
                "message": (
                    f"## 📡 Learning: **{target_name}**\n\n"
                    f"Device: **{device_name}**\n\n"
                    "### Step 1: Capture Button #1\n\n"
                    "1. Press the **'Learn Signal'** button below\n"
                    "2. Within 30 seconds, **press the button on your remote**\n"
                    "   that you want the device to learn\n"
                    "3. The device will capture the signal and replay it\n"
                    "   for verification\n\n"
                    "---\n"
                    "> **Tip**: Hold the remote 1–2 meters from the EvilCrowRF\n"
                    "> device for best results.\n\n"
                    "Ready? Press **Learn Signal** to start."
                ),
            },
            blocking=False,
        )

    def _on_wizard_capturing(self, button_index: int) -> None:
        """Update notification while device is listening."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        subghz = self._coordinator.subghz
        wiz = getattr(subghz, "wizard", None) if subghz else None
        target_name = wiz.target_device_name if wiz else "Remote"
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": f"EvilCrowRF — Listening for {target_name}",
                "message": (
                    f"## 📡 Listening for Button #{button_index}\n\n"
                    f"Learning: **{target_name}**\n\n"
                    "The device is now **listening** for RF signals.\n\n"
                    "**Press the button on your remote now!**\n\n"
                    "⏱️ The capture will time out after 30 seconds.\n\n"
                    "---\n"
                    "Press **Cancel Capture** to abort."
                ),
            },
            blocking=False,
        )

    def _on_wizard_confirming(self, button_name: str) -> None:
        """Show wizard confirm prompt (also handled by _on_confirming above)."""
        # This is handled by _on_confirming which checks wizard state
        pass

    def _on_wizard_button_saved(self, button_name: str) -> None:
        """Show next-step prompt after a button is saved."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        subghz = self._coordinator.subghz
        wiz = getattr(subghz, "wizard", None) if subghz else None
        target_name = wiz.target_device_name if wiz else "Remote"
        total = wiz.total_buttons_learned if wiz else 1
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": "EvilCrowRF — Button Saved",
                "message": (
                    f"## ✅ Button **{button_name}** Saved!\n\n"
                    f"Remote: **{target_name}**\n"
                    f"Total buttons learned: **{total}**\n\n"
                    "### What's next?\n\n"
                    "**To learn another button:**\n"
                    "1. Press the **'Learn Signal'** button again\n"
                    "2. Press the next button on your remote\n\n"
                    "**To finish:** Press **'Confirm Cancel'** or wait — "
                    "the wizard completes automatically after you confirm.\n\n"
                    "---\n"
                    "> **Tip**: You can rename the captured file using the\n"
                    "> 'Rename Signal' text field at any time."
                ),
            },
            blocking=False,
        )

    def _on_wizard_next_button(self, next_index: int) -> None:
        """Prompt the user to capture the next button."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        subghz = self._coordinator.subghz
        wiz = getattr(subghz, "wizard", None) if subghz else None
        target_name = wiz.target_device_name if wiz else "Remote"
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": f"EvilCrowRF — Next Button (#{next_index})",
                "message": (
                    f"## 📡 Capture Button #{next_index}\n\n"
                    f"Learning: **{target_name}**\n\n"
                    "Press **'Learn Signal'** and then press the next\n"
                    "button on your remote.\n\n"
                    "---\n"
                    "Press **Confirm Cancel** to finish the wizard."
                ),
            },
            blocking=False,
        )

    def _on_wizard_complete(self, total_learned: int) -> None:
        """Show wizard completion notification."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        subghz = self._coordinator.subghz
        wiz = getattr(subghz, "wizard", None) if subghz else None
        target_name = wiz.target_device_name if wiz else "Remote"
        self._hass.services.async_call(
            "persistent_notification",
            "create",
            {
                "notification_id": notify_id,
                "title": "EvilCrowRF — Setup Complete!",
                "message": (
                    f"## 🎉 Remote **{target_name}** is ready!\n\n"
                    f"**{total_learned}** button(s) learned and saved.\n\n"
                    "You can now use these signals in:\n"
                    "- **Automations**: trigger RF actions via events\n"
                    "- **Dashboards**: add buttons to your dashboard\n"
                    "- **Scripts**: build sequences of RF commands\n\n"
                    "---\n"
                    "To learn another remote, press **Add Target Remote** again."
                ),
            },
            blocking=False,
        )

    def _on_wizard_cancelled(self) -> None:
        """Dismiss wizard notification on cancel."""
        self.dismiss_wizard()

    def dismiss_wizard(self) -> None:
        """Dismiss the wizard step notification."""
        notify_id = f"{NOTIFY_WIZARD_STEP}_{self._device_id}"
        self._hass.services.async_call(
            "persistent_notification",
            "dismiss",
            {"notification_id": notify_id},
            blocking=False,
        )
