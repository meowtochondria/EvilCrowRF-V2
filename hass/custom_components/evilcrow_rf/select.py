"""Select platform for the EvilCrowRF V2 integration.

Provides ``CapturedSignalSelectEntity`` — a dropdown that lists .sub files
on the device's SD card, allowing the user to select which signal to replay.
"""

from __future__ import annotations

import logging
from typing import Any

from homeassistant.components.select import SelectEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import EvilCrowCoordinator

_LOGGER = logging.getLogger(__name__)


class CapturedSignalSelectEntity(CoordinatorEntity, SelectEntity):
    """Select entity that lists .sub files on the device's SD card.

    The current option is persisted in the coordinator's subghz state so that
    it survives entity reloads. Options are refreshed by calling
    :meth:`SubGhzService.refresh_files`.
    """

    _attr_has_entity_name: bool = True
    _attr_translation_key = "captured_signal"

    def __init__(
        self,
        coordinator: EvilCrowCoordinator,
        entry_id: str,
    ) -> None:
        """Initialize the captured signal select entity.

        Args:
            coordinator: The device's coordinator.
            entry_id: The config entry ID (used as the unique_id suffix).
        """
        super().__init__(coordinator)
        self._entry_id = entry_id
        device_id = coordinator.device_info.device_id
        self._attr_unique_id = f"evilcrow_{device_id}_captured_signal"

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
        return super().available  # type: ignore

    @property  # type: ignore
    def options(self) -> list[str]:
        """Return the list of .sub file paths from the device."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return []
        return list(subghz.state.last_file_list)

    @property  # type: ignore
    def current_option(self) -> str | None:
        """Return the currently selected signal file."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return None
        signal_file = subghz.state.signal_file
        if signal_file and signal_file in subghz.state.last_file_list:
            return signal_file
        return None

    async def async_select_option(self, option: str) -> None:
        """Handle selecting a signal file.

        Stores the selected file path in the subghz state's ``signal_file``
        field so that the replay button and other entities can use it.

        Args:
            option: The selected .sub file path.
        """
        subghz = self.coordinator.subghz
        if subghz is None:
            _LOGGER.warning("SubGhzService not initialized; cannot select signal.")
            return

        if option in subghz.state.last_file_list:
            subghz.state.signal_file = option
            self.async_write_ha_state()
            _LOGGER.debug(
                "Selected signal file on device %s: %s",
                self.coordinator.device_info.device_id,
                option,
            )

    @property  # type: ignore
    def extra_state_attributes(self) -> dict[str, Any]:
        """Return additional attributes about the file list."""
        subghz = self.coordinator.subghz
        if subghz is None:
            return {}
        return {
            "file_count": len(subghz.state.last_file_list),
        }


# ---------------------------------------------------------------------------
# Platform setup
# ---------------------------------------------------------------------------


async def async_setup_entry(
    hass: HomeAssistant,
    config_entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up the EvilCrowRF select platform."""
    coordinator: EvilCrowCoordinator = hass.data[DOMAIN][config_entry.entry_id]

    entities: list[SelectEntity] = [
        CapturedSignalSelectEntity(coordinator, config_entry.entry_id),
    ]

    async_add_entities(entities)
    _LOGGER.debug(
        "Added select entity for device %s",
        coordinator.device_info.device_id,
    )
