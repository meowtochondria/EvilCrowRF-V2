"""EvilCrowRF V2 Home Assistant integration.

Component entry point. Handles setup/teardown of coordinators, service
registration, and forwards entity setup to platform modules.
"""

from __future__ import annotations

import logging
import time
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_HOST, CONF_PORT
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryNotReady

from .const import (
    CONF_MONITOR_ENABLED,
    CONF_MONITOR_MODULE,
    CONF_MONITOR_RSSI_THRESHOLD,
    CONFIG_ENTRY_VERSION,
    DOMAIN,
)
from .coordinator import EvilCrowCoordinator
from .models import DeviceInfo
from .services import async_register_services
from .subghz import SubGhzService
from .target_device_store import TargetDeviceStore

_LOGGER = logging.getLogger(__name__)

PLATFORMS: list[str] = [
    "sensor",
    "button",
    "select",
    "text",
]

_services_registered: bool = False  # ensures one-shot global registration


# ---------------------------------------------------------------------------
# Component setup / teardown
# ---------------------------------------------------------------------------


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up an EvilCrowRF device from a config entry.

    Creates:
      - ``TargetDeviceStore`` (loads from JSON)
      - ``EvilCrowCoordinator`` (owns transport, protocol, state)
      - ``SubGhzService`` (capture/replay state machine)
      - The coordinator's ``on_message`` dispatcher
      - Forwards to all platform modules (sensor, button, select, text)

    Args:
        hass: The HomeAssistant instance.
        entry: The config entry for this device.

    Returns:
        True on success.

    Raises:
        ConfigEntryNotReady: If connection to the device fails.
    """
    _LOGGER.debug("Setting up EvilCrowRF config entry %s", entry.entry_id)

    # ---- 1. TargetDeviceStore (loaded once per HA start) ----
    target_store = TargetDeviceStore(hass)
    await target_store.async_load()

    # ---- 2. Build DeviceInfo from config entry data ----
    host = entry.data.get(CONF_HOST, "")
    port = entry.data.get(CONF_PORT, 80)
    device_id = entry.entry_id  # Phases 1-4: entry_id = device identity

    device_info = DeviceInfo(
        host=host,
        port=port,
        device_id=device_id,
        name=entry.title or f"EvilCrowRF {host}",
        firmware_version="",
        fw_major=0,
        fw_minor=0,
        fw_patch=0,
        transport="wifi",
        mac=None,
        capabilities={},
    )

    # ---- 3. Create coordinator ----
    coordinator = EvilCrowCoordinator(
        hass=hass,
        config_entry=entry,
        device_info=device_info,
    )
    coordinator.target_store = target_store

    # ---- 4. Create SubGhzService ----
    subghz = SubGhzService(coordinator)
    coordinator.subghz = subghz

    # ---- 5. Wire transport on_message dispatcher ----
    async def _on_message(parsed: dict[str, Any]) -> None:
        """Dispatch incoming WebSocket frames to local services.

        Args:
            parsed: The parsed response dict from
                :meth:`EvilCrowBinaryProtocol.parse_response`.
        """
        response_type = parsed.get("type", "")

        # Dispatch to SubGhzService for capture/replay/file-list responses
        if subghz is not None:
            await subghz.handle_response(parsed)

        # Dispatch to SignalMonitor for monitoring frames
        monitor = coordinator.signal_monitor
        if monitor is not None and response_type == "SignalMonitor":
            from .signal_monitor import DetectedSignal

            data = parsed.get("data", {})
            signal = DetectedSignal(
                frequency=data.get("frequency", 0),
                rssi=data.get("rssi", 0),
                raw_key=data.get("key", ""),
                protocol=data.get("protocol", 0),
                bit=data.get("bit", 0),
                detected_at=time.monotonic(),
            )
            await monitor.handle_signal(signal)

    coordinator.transport._on_message = _on_message

    # ---- 6. Connect to the device ----
    try:
        connected = await coordinator.async_connect()
        if not connected:
            raise ConfigEntryNotReady(f"Failed to connect to EvilCrowRF device at {host}:{port}")
    except ConfigEntryNotReady:
        raise
    except Exception as exc:
        raise ConfigEntryNotReady(
            f"Unexpected error connecting to EvilCrowRF device at {host}:{port}: {exc}"
        ) from exc

    # ---- 7. Store coordinator in hass.data ----
    hass.data.setdefault(DOMAIN, {})
    hass.data[DOMAIN][entry.entry_id] = coordinator

    # ---- 8. Register services (once globally) ----
    global _services_registered
    if not _services_registered:
        async_register_services(hass)
        _services_registered = True

    # ---- 9. Forward to platforms ----
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    # ---- 10. Add update listener for config entry options ----
    entry.async_on_unload(entry.add_update_listener(_async_update_listener))

    _LOGGER.info(
        "EvilCrowRF device %s (%s:%d) set up successfully",
        device_id,
        host,
        port,
    )
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Tear down an EvilCrowRF device config entry.

    Disconnects the coordinator, unloads platforms, and removes the
    coordinator from hass.data.

    Args:
        hass: The HomeAssistant instance.
        entry: The config entry for this device.

    Returns:
        True if all platforms were unloaded successfully.
    """
    _LOGGER.debug("Unloading EvilCrowRF config entry %s", entry.entry_id)

    coordinator: EvilCrowCoordinator | None = hass.data.get(DOMAIN, {}).get(entry.entry_id)

    # Unload platforms
    unload_ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)

    # Disconnect coordinator
    if coordinator is not None:
        await coordinator.async_disconnect()

    # Clean up hass.data
    hass.data.get(DOMAIN, {}).pop(entry.entry_id, None)

    _LOGGER.info(
        "EvilCrowRF device %s unloaded (platforms ok: %s)",
        entry.entry_id,
        unload_ok,
    )
    return unload_ok


# ---------------------------------------------------------------------------
# Config entry migration
# ---------------------------------------------------------------------------


async def async_migrate_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Migrate a config entry to a newer version.

    Currently handles:
      - Version 1 (initial): no migration needed.

    Args:
        hass: The HomeAssistant instance.
        entry: The config entry to migrate.

    Returns:
        True if migration succeeded.
    """
    _LOGGER.debug(
        "Migrating config entry %s from version %d to version %d",
        entry.entry_id,
        entry.version,
        CONFIG_ENTRY_VERSION,
    )

    if entry.version > CONFIG_ENTRY_VERSION:
        # This should not happen; the config entry schema is not forward-compatible
        _LOGGER.error(
            "Config entry %s has version %d, but the integration only supports "
            "version %d. Downgrade not supported.",
            entry.entry_id,
            entry.version,
            CONFIG_ENTRY_VERSION,
        )
        return False

    if entry.version == 1:
        # Version 1 is current — no migration steps needed.
        pass

    _LOGGER.info(
        "Config entry %s migrated to version %d",
        entry.entry_id,
        CONFIG_ENTRY_VERSION,
    )
    return True


# ---------------------------------------------------------------------------
# Update listener
# ---------------------------------------------------------------------------


async def _async_update_listener(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Handle config entry options update.

    Called when the user changes options via the HA UI (Options flow).
    Propagates changes to the coordinator and signal monitor.

    Args:
        hass: The HomeAssistant instance.
        entry: The updated config entry.
    """
    coordinator: EvilCrowCoordinator | None = hass.data.get(DOMAIN, {}).get(entry.entry_id)
    if coordinator is None:
        _LOGGER.warning("Coordinator not found for entry %s", entry.entry_id)
        return

    _LOGGER.debug("Options updated for device %s: %s", entry.entry_id, entry.options)

    # Propagate monitor config changes
    monitor = coordinator.signal_monitor
    if monitor is not None:
        from .signal_monitor import MonitorConfig

        monitor.config = MonitorConfig(
            enabled=entry.options.get(CONF_MONITOR_ENABLED, False),
            module=entry.options.get(CONF_MONITOR_MODULE, 1),
            rssi_threshold=entry.options.get(CONF_MONITOR_RSSI_THRESHOLD, -80),
        )

    # Reload the config entry to pick up any platform changes
    await hass.config_entries.async_reload(entry.entry_id)
