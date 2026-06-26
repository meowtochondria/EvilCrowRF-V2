"""Config flow for EvilCrowRF V2 integration.

Provides the following steps:
  - user: Setup method selection (manual, discovery, or auto)
  - manual_device: Host/port input
  - discovery: Zeroconf discovery
  - reconfigure: Host/port update for an existing entry
  - options: Per-device monitoring settings

SmartConfig provisioning (Phase 5) is omitted in Phases 1-4.
"""

from __future__ import annotations

import logging
from typing import Any

import voluptuous as vol
from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlow,
)
from homeassistant.const import CONF_HOST, CONF_NAME, CONF_PORT
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import config_validation as cv

from .const import (
    CONF_EXPOSE_UNKNOWN,
    CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
    CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS,
    CONF_MONITOR_ENABLED,
    CONF_MONITOR_MODULE,
    CONF_MONITOR_RSSI_THRESHOLD,
    DEFAULT_NAME,
    DEFAULT_PORT,
    DOMAIN,
    STEP_DISCOVERY,
    STEP_MANUAL,
    STEP_OPTIONS,
    STEP_RECONFIGURE,
    STEP_USER,
)
from .wifi_transport import WiFiTransport

_LOGGER = logging.getLogger(__name__)

# ---- Validation helpers ----


async def validate_device_connection(hass: HomeAssistant, host: str, port: int) -> dict[str, Any]:
    """Try to connect to an EvilCrowRF device and fetch /api/info.

    Args:
        hass: HomeAssistant instance.
        host: Device hostname or IP.
        port: Device HTTP/WS port.

    Returns:
        Dict with device info fields (name, fw_version, fw_major, etc.).

    Raises:
        CannotConnectError: If the device is unreachable or returns unexpected data.
    """
    transport = WiFiTransport(host=host, port=port, device_id="config_flow")
    try:
        info = await transport.fetch_device_info()
        if info is None:
            raise CannotConnectError("Device returned no info")
        return info
    except (TimeoutError, ConnectionError, OSError) as exc:
        raise CannotConnectError(f"Connection failed: {exc}") from exc
    finally:
        await transport.disconnect()


def _build_manual_schema(host: str = "", port: int = DEFAULT_PORT) -> vol.Schema:
    """Build the schema for the manual device entry step.

    Args:
        host: Pre-filled host value (e.g. from discovery or reconfigure).
        port: Pre-filled port value.

    Returns:
        Voluptuous schema.
    """
    return vol.Schema(
        {
            vol.Required(CONF_HOST, default=host): cv.string,
            vol.Required(CONF_PORT, default=port): vol.All(cv.port, vol.Coerce(int)),
        }
    )


# ---- Custom exceptions ----


class CannotConnectError(HomeAssistantError):
    """Error to indicate we cannot connect to the device."""


class InvalidHostError(HomeAssistantError):
    """Error to indicate the host is invalid."""


# ---- Config Flow ----


class EvilCrowRfConfigFlowHandler(ConfigFlow, domain=DOMAIN):  # type: ignore[call-arg]
    """Handle the config flow for EvilCrowRF V2."""

    VERSION = 1

    def __init__(self) -> None:
        """Initialize the config flow handler."""
        super().__init__()
        self._discovered_host: str = ""
        self._discovered_port: int = DEFAULT_PORT
        self._discovery_name: str = DEFAULT_NAME
        self._device_info: dict[str, Any] = {}

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        """Handle the initial step — setup method selection.

        Presents three options:
          - Manual: Enter host and port directly.
          - Discovery: Show discovered EvilCrowRF devices on the network.
          - Auto: Attempt automatic discovery first, fall back to manual.
        """
        if user_input is not None:
            method = user_input.get("setup_method", "manual")
            if method == "manual":
                return await self.async_step_manual_device()
            if method == "discovery":
                return await self.async_step_discovery()
            if method == "auto":
                # Try discovery first; if no devices found, go to manual
                result = await self.async_step_discovery(user_input=None)
                if result.get("type") == "form" and result.get("step_id") == STEP_DISCOVERY:
                    # No devices discovered — fall through to manual
                    return await self.async_step_manual_device()
                return result

        return self.async_show_form(
            step_id=STEP_USER,
            data_schema=vol.Schema(
                {
                    vol.Required("setup_method", default="manual"): vol.In(
                        {
                            "manual": "Enter device IP/host manually",
                            "discovery": "Select from discovered devices",
                            "auto": "Auto-detect (try discovery, then manual)",
                        }
                    ),
                }
            ),
        )

    async def async_step_manual_device(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Handle manual device configuration — host and port input.

        Validates the connection by fetching /api/info. On success, creates
        the config entry. On failure, shows an error and re-displays the form.
        """
        errors: dict[str, str] = {}

        if user_input is not None:
            host = user_input[CONF_HOST].strip()
            port = user_input[CONF_PORT]

            if not host:
                errors[CONF_HOST] = "invalid_host"
            else:
                # Check for duplicate entries
                self._async_abort_entries_match({CONF_HOST: host, CONF_PORT: port})

                try:
                    info = await validate_device_connection(self.hass, host, port)
                except CannotConnectError as exc:
                    _LOGGER.warning("Cannot connect to %s:%d: %s", host, port, exc)
                    errors["base"] = "cannot_connect"
                except Exception:
                    _LOGGER.exception("Unexpected error connecting to %s:%d", host, port)
                    errors["base"] = "unknown"
                else:
                    name = info.get("name", f"{DEFAULT_NAME} ({host})")
                    self._device_info = info

                    return self.async_create_entry(
                        title=name,
                        data={
                            CONF_HOST: host,
                            CONF_PORT: port,
                            CONF_NAME: name,
                        },
                    )

        schema = _build_manual_schema(
            host=self._discovered_host or "",
            port=self._discovered_port or DEFAULT_PORT,
        )
        return self.async_show_form(
            step_id=STEP_MANUAL,
            data_schema=schema,
            errors=errors,
        )

    async def async_step_discovery(  # type: ignore[override]
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Handle zeroconf discovery step.

        Uses Home Assistant's built-in zeroconf discovery. Discovered
        EvilCrowRF devices are presented as a list for the user to choose from.

        This is invoked either:
          - From the user step when "discovery" is selected.
          - Automatically by HA when a _evilcrow._tcp.local. service is found.
        """
        if user_input is not None:
            # User selected a specific discovered device
            idx = user_input.get("device_index", 0)
            discovered = self._get_discovered_devices()
            if idx < len(discovered):
                device = discovered[idx]
                host = device["host"]
                port = device["port"]
                name = device.get("name", DEFAULT_NAME)

                self._async_abort_entries_match({CONF_HOST: host, CONF_PORT: port})

                try:
                    info = await validate_device_connection(self.hass, host, port)
                except CannotConnectError:
                    return self.async_show_form(
                        step_id=STEP_DISCOVERY,
                        data_schema=vol.Schema(
                            {vol.Required("device_index"): vol.In(self._build_discovery_options())}
                        ),
                        errors={"base": "cannot_connect"},
                    )

                name = info.get("name", name)
                return self.async_create_entry(
                    title=name,
                    data={
                        CONF_HOST: host,
                        CONF_PORT: port,
                        CONF_NAME: name,
                    },
                )

        discovered = self._get_discovered_devices()
        if not discovered:
            # No devices discovered
            return self.async_show_form(
                step_id=STEP_DISCOVERY,
                data_schema=vol.Schema({}),
                errors={"base": "no_devices_found"},
                description_placeholders={"num_devices": "0"},
            )

        return self.async_show_form(
            step_id=STEP_DISCOVERY,
            data_schema=vol.Schema(
                {vol.Required("device_index"): vol.In(self._build_discovery_options())}
            ),
            description_placeholders={
                "num_devices": str(len(discovered)),
            },
        )

    async def async_step_reconfigure(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Handle reconfiguration of an existing config entry.

        Allows the user to update the host and port for an already-configured
        EvilCrowRF device.
        """
        entry = self._get_reconfigure_entry()
        errors: dict[str, str] = {}

        current_host = entry.data.get(CONF_HOST, "")
        current_port = entry.data.get(CONF_PORT, DEFAULT_PORT)

        if user_input is not None:
            host = user_input[CONF_HOST].strip()
            port = user_input[CONF_PORT]

            if not host:
                errors[CONF_HOST] = "invalid_host"
            else:
                try:
                    info = await validate_device_connection(self.hass, host, port)
                except CannotConnectError as exc:
                    _LOGGER.warning(
                        "Cannot connect during reconfigure %s:%d: %s",
                        host,
                        port,
                        exc,
                    )
                    errors["base"] = "cannot_connect"
                except Exception:
                    _LOGGER.exception("Unexpected error during reconfigure %s:%d", host, port)
                    errors["base"] = "unknown"
                else:
                    name = info.get("name", entry.title)
                    return self.async_update_reload_and_abort(
                        entry,
                        data={
                            CONF_HOST: host,
                            CONF_PORT: port,
                            CONF_NAME: name,
                        },
                        reason="reconfigure_successful",
                    )

        schema = _build_manual_schema(
            host=current_host,
            port=current_port,
        )
        return self.async_show_form(
            step_id=STEP_RECONFIGURE,
            data_schema=schema,
            errors=errors,
        )

    @staticmethod
    @callback
    def async_get_options_flow(
        config_entry: ConfigEntry,
    ) -> OptionsFlow:
        """Create the options flow for this config entry."""
        return EvilCrowRfOptionsFlowHandler(config_entry)

    # ---- Zeroconf integration ----

    async def async_step_zeroconf(self, discovery_info: Any) -> ConfigFlowResult:
        """Handle zeroconf discovery from Home Assistant's built-in service.

        Triggered when an _evilcrow._tcp.local. service is published on the
        network. Automatically creates a config entry if the device is
        reachable and not already configured.
        """
        if discovery_info is None:
            return self.async_abort(reason="no_discovery_info")

        host = discovery_info.host
        port = discovery_info.port or DEFAULT_PORT
        name = discovery_info.name.replace("._evilcrow._tcp.local.", "").replace(
            f".{discovery_info.type}", ""
        )
        # Extract a clean display name from the service name
        display_name = name.strip() or f"{DEFAULT_NAME} ({host})"

        # Check for duplicates
        await self.async_set_unique_id(f"evilcrow_rf_{host}_{port}")
        self._abort_if_unique_id_configured(updates={CONF_HOST: host, CONF_PORT: port})

        # Update context for later steps
        self._discovered_host = host
        self._discovered_port = port
        self._discovery_name = display_name
        self.context["title_placeholders"] = {
            "name": display_name,
        }

        # Try to validate immediately
        try:
            info = await validate_device_connection(self.hass, host, port)
        except CannotConnectError:
            # Device not reachable yet — let the user finish setup manually
            return await self.async_step_manual_device()

        name = info.get("name", display_name)
        return self.async_create_entry(
            title=name,
            data={
                CONF_HOST: host,
                CONF_PORT: port,
                CONF_NAME: name,
            },
        )

    # ---- Internal helpers ----

    def _get_discovered_devices(self) -> list[dict[str, Any]]:
        """Return a list of currently discovered EvilCrowRF devices.

        Returns:
            List of dicts with keys: host, port, name.
        """
        discovered: list[dict[str, Any]] = []
        # In Phases 1-4, we don't maintain a persistent discovery cache.
        # Devices are typically found via zeroconf (async_step_zeroconf) or
        # entered manually. This method is used when the user explicitly
        # selects "discovery" from the setup method menu.
        if self._discovered_host:
            discovered.append(
                {
                    "host": self._discovered_host,
                    "port": self._discovered_port or DEFAULT_PORT,
                    "name": self._discovery_name,
                }
            )
        return discovered

    def _build_discovery_options(self) -> dict[int, str]:
        """Build a mapping of index -> display label for discovered devices.

        Returns:
            Dict mapping index to human-readable device label.
        """
        devices = self._get_discovered_devices()
        return {i: f"{d['name']} ({d['host']}:{d['port']})" for i, d in enumerate(devices)}


# ---- Options Flow ----


class EvilCrowRfOptionsFlowHandler(OptionsFlow):
    """Handle options flow for EvilCrowRF V2.

    Allows per-device configuration of:
      - Monitoring enable/disable
      - Monitor module selection
      - RSSI threshold
      - Unknown signal exposure settings
    """

    def __init__(self, config_entry: ConfigEntry) -> None:
        """Initialize options flow.

        Args:
            config_entry: The config entry being configured.
        """
        super().__init__()
        self._config_entry = config_entry

    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        """Handle the options step — monitoring configuration.

        Presents form fields for monitoring and signal exposure settings.
        """
        if user_input is not None:
            # Validate and save options
            min_occ = user_input.get(CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES, 3)
            window_sec = user_input.get(CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS, 60)

            return self.async_create_entry(
                title="",
                data={
                    CONF_MONITOR_ENABLED: user_input.get(CONF_MONITOR_ENABLED, False),
                    CONF_MONITOR_MODULE: user_input.get(CONF_MONITOR_MODULE, 1),
                    CONF_MONITOR_RSSI_THRESHOLD: user_input.get(CONF_MONITOR_RSSI_THRESHOLD, -80),
                    CONF_EXPOSE_UNKNOWN: user_input.get(CONF_EXPOSE_UNKNOWN, False),
                    CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES: min_occ,
                    CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS: window_sec,
                },
            )

        current_options = self._config_entry.options or {}

        schema = vol.Schema(
            {
                vol.Optional(
                    CONF_MONITOR_ENABLED,
                    default=current_options.get(CONF_MONITOR_ENABLED, False),
                ): cv.boolean,
                vol.Optional(
                    CONF_MONITOR_MODULE,
                    default=current_options.get(CONF_MONITOR_MODULE, 1),
                ): vol.All(vol.Coerce(int), vol.In([0, 1])),
                vol.Optional(
                    CONF_MONITOR_RSSI_THRESHOLD,
                    default=current_options.get(CONF_MONITOR_RSSI_THRESHOLD, -80),
                ): vol.All(
                    vol.Coerce(int),
                    vol.Range(min=-127, max=0),
                ),
                vol.Optional(
                    CONF_EXPOSE_UNKNOWN,
                    default=current_options.get(CONF_EXPOSE_UNKNOWN, False),
                ): cv.boolean,
                vol.Optional(
                    CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
                    default=current_options.get(CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES, 3),
                ): vol.All(
                    vol.Coerce(int),
                    vol.Range(min=1, max=100),
                ),
                vol.Optional(
                    CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS,
                    default=current_options.get(CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS, 60),
                ): vol.All(
                    vol.Coerce(int),
                    vol.Range(min=5, max=3600),
                ),
            }
        )

        return self.async_show_form(
            step_id=STEP_OPTIONS,
            data_schema=schema,
        )
