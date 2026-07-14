"""Text platform for the EvilCrowRF V2 integration.

Provides ``RenameSignalTextEntity`` — a text input entity that allows the user
to enter a new name for the currently selected .sub file. The entity calls
:meth:`SubGhzService.rename_signal` when the text is committed.
"""

from __future__ import annotations

import logging

from homeassistant.components.text import TextEntity, TextMode
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import EvilCrowCoordinator

_LOGGER = logging.getLogger(__name__)


class RenameSignalTextEntity(CoordinatorEntity, TextEntity):
    """Text input for renaming the currently selected .sub file.

    The user types a new filename (without path) and commits it. The entity
    calls :meth:`SubGhzService.rename_signal` to rename the file on the
    device's SD card.

    The field is read-only until a signal file is selected via the
    ``CapturedSignalSelectEntity``.
    """

    _attr_has_entity_name = True
    _attr_translation_key = "rename_signal"
    _attr_entity_category = EntityCategory.CONFIG
    _attr_mode = TextMode.TEXT
    _attr_native_min = 1
    _attr_native_max = 128

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the rename signal text entity.

        Args:
            coordinator: The device's coordinator.
            entry_id: The config entry ID (used as the unique_id suffix).
        """
        super().__init__(coordinator)
        self._entry_id = entry_id
        device_id = coordinator.device_info.device_id
        self._attr_unique_id = f"evilcrow_{device_id}_rename_signal"
        self._attr_native_value = ""

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
    def native_value(self) -> str | None:
        """Return the current text value (the new filename)."""
        subghz = self.coordinator.subghz
        if subghz is None or not subghz.state.signal_file:
            return ""
        # Derive a default new name from the current signal file
        current = subghz.state.signal_file.rsplit("/", 1)[-1]
        return self._attr_native_value or current

    async def async_set_value(self, value: str) -> None:
        """Handle text input commit.

        Extracts the old path from the current selected signal file,
        derives the new path by replacing the filename component, and
        sends a rename command to the device.

        Args:
            value: The new filename (e.g. ``"front_door.sub"``).
        """
        value = value.strip()
        if not value:
            return

        subghz = self.coordinator.subghz
        if subghz is None:
            _LOGGER.warning("SubGhzService not initialized; cannot rename signal.")
            return

        old_path = subghz.state.signal_file
        if not old_path:
            _LOGGER.warning("No signal file selected; cannot rename.")
            return

        # Derive the new path: replace the filename component
        parts = old_path.rsplit("/", 1)
        new_path = f"{parts[0]}/{value}" if len(parts) > 1 else value

        self._attr_native_value = value
        self.async_write_ha_state()

        await subghz.rename_signal(old_path=old_path, new_path=new_path)

        _LOGGER.debug(
            "Signal renamed on device %s: %s -> %s",
            self.coordinator.device_info.device_id,
            old_path,
            new_path,
        )

    @property  # type: ignore
    def available(self) -> bool:
        """Return True if a signal file is selected for renaming."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return False
        return bool(subghz.state.signal_file)


# ---------------------------------------------------------------------------
# Platform setup
# ---------------------------------------------------------------------------


async def async_setup_entry(
    hass: HomeAssistant,
    config_entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up the EvilCrowRF text platform."""
    coordinator: EvilCrowCoordinator = hass.data[DOMAIN][config_entry.entry_id]

    entities: list[TextEntity] = [
        RenameSignalTextEntity(coordinator, config_entry.entry_id),
    ]

    async_add_entities(entities)
    _LOGGER.debug(
        "Added text entity for device %s",
        coordinator.device_info.device_id,
    )
