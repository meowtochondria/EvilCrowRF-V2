"""YAML config loader for EvilCrowRF V2.

Loads, validates, and provides defaults for the standalone evilcrow_rf.yaml
configuration file. This is NOT a Home Assistant platform config — it is a
standalone YAML file stored in the HA config directory.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Any, cast

import voluptuous as vol
from homeassistant.core import HomeAssistant
from homeassistant.util.yaml import load_yaml

from .const import (
    CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
    CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS,
    CONF_FCC_API_ENDPOINT,
    CONF_FCC_TEST_ID,
    DEFAULT_FCC_API_ENDPOINT,
    YAML_CONFIG_FILENAME,
)

_LOGGER = logging.getLogger(__name__)

# Default values for all configurable settings.
_DEFAULT_REQUEST_TIMEOUT_SECONDS = 15
_DEFAULT_CAPTURE_TIMEOUT_SECONDS = 30
_DEFAULT_EXPOSE_UNKNOWN_MIN_OCCURRENCES = 3
_DEFAULT_EXPOSE_UNKNOWN_WINDOW_SECONDS = 60

# Voluptuous schema for the YAML config.
YAML_CONFIG_SCHEMA = vol.Schema(
    {
        vol.Optional(
            CONF_FCC_API_ENDPOINT,
            default=DEFAULT_FCC_API_ENDPOINT,
        ): vol.All(str, vol.Length(min=1)),
        vol.Optional(CONF_FCC_TEST_ID, default=""): vol.All(str, vol.Length(min=0, max=50)),
        vol.Optional("request_timeout_seconds", default=_DEFAULT_REQUEST_TIMEOUT_SECONDS): vol.All(
            int, vol.Range(min=1, max=120)
        ),
        vol.Optional("capture_timeout_seconds", default=_DEFAULT_CAPTURE_TIMEOUT_SECONDS): vol.All(
            int, vol.Range(min=1, max=300)
        ),
        vol.Optional(
            CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
            default=_DEFAULT_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
        ): vol.All(int, vol.Range(min=1, max=100)),
        vol.Optional(
            CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS,
            default=_DEFAULT_EXPOSE_UNKNOWN_WINDOW_SECONDS,
        ): vol.All(int, vol.Range(min=5, max=3600)),
    },
    extra=vol.PREVENT_EXTRA,
)


@dataclass
class EvilCrowYamlConfig:
    """Parsed and validated evilcrow_rf.yaml configuration."""

    fcc_api_endpoint: str = DEFAULT_FCC_API_ENDPOINT
    fcc_test_id: str = ""
    request_timeout_seconds: int = _DEFAULT_REQUEST_TIMEOUT_SECONDS
    capture_timeout_seconds: int = _DEFAULT_CAPTURE_TIMEOUT_SECONDS
    expose_unknown_min_occurrences: int = _DEFAULT_EXPOSE_UNKNOWN_MIN_OCCURRENCES
    expose_unknown_window_seconds: int = _DEFAULT_EXPOSE_UNKNOWN_WINDOW_SECONDS

    def to_dict(self) -> dict[str, Any]:
        """Convert config to a plain dict for downstream use."""
        return {
            CONF_FCC_API_ENDPOINT: self.fcc_api_endpoint,
            CONF_FCC_TEST_ID: self.fcc_test_id,
            "request_timeout_seconds": self.request_timeout_seconds,
            "capture_timeout_seconds": self.capture_timeout_seconds,
            CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES: self.expose_unknown_min_occurrences,
            CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS: self.expose_unknown_window_seconds,
        }


class YamlConfigLoader:
    """Loads, validates, and manages the evilcrow_rf.yaml config file.

    The config file lives in the Home Assistant config directory. If the file
    does not exist, it will be auto-created with default values on first load.
    """

    def __init__(self, hass: HomeAssistant) -> None:
        """Initialize the loader.

        Args:
            hass: The HomeAssistant instance (used to resolve config path).
        """
        self._hass = hass
        self._path = hass.config.path(YAML_CONFIG_FILENAME)
        self._cached: EvilCrowYamlConfig | None = None

    @property
    def path(self) -> str:
        """Return the full filesystem path to the YAML config file."""
        return self._path

    async def async_load(self) -> EvilCrowYamlConfig:
        """Load and validate the YAML config.

        If the file is missing, auto-creates it with defaults and returns
        those defaults. If validation fails, logs a warning and returns
        defaults.

        Returns:
            An EvilCrowYamlConfig instance with validated values.
        """
        raw: dict[str, Any] = {}

        # Check if file exists
        exists = await self._hass.async_add_executor_job(os.path.isfile, self._path)

        if not exists:
            _LOGGER.info(
                "YAML config %s not found — creating with defaults",
                YAML_CONFIG_FILENAME,
            )
            raw = {}
            await self._async_write_defaults()
        else:
            # Load from executor to avoid blocking the event loop
            try:
                raw = await self._hass.async_add_executor_job(self._load_sync)
            except Exception as exc:
                _LOGGER.warning(
                    "Failed to load YAML config %s: %s. Using defaults.",
                    self._path,
                    exc,
                )
                raw = {}

        # Validate and coerce
        try:
            validated: dict[str, Any] = cast(dict[str, Any], YAML_CONFIG_SCHEMA(raw))
        except vol.Invalid as exc:
            _LOGGER.warning(
                "YAML config validation failed for %s: %s. Using defaults.",
                self._path,
                exc,
            )
            validated = cast(dict[str, Any], YAML_CONFIG_SCHEMA({}))

        config = EvilCrowYamlConfig(
            fcc_api_endpoint=validated[CONF_FCC_API_ENDPOINT],
            fcc_test_id=validated.get(CONF_FCC_TEST_ID, ""),
            request_timeout_seconds=validated.get(
                "request_timeout_seconds", _DEFAULT_REQUEST_TIMEOUT_SECONDS
            ),
            capture_timeout_seconds=validated.get(
                "capture_timeout_seconds", _DEFAULT_CAPTURE_TIMEOUT_SECONDS
            ),
            expose_unknown_min_occurrences=validated.get(
                CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
                _DEFAULT_EXPOSE_UNKNOWN_MIN_OCCURRENCES,
            ),
            expose_unknown_window_seconds=validated.get(
                CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS,
                _DEFAULT_EXPOSE_UNKNOWN_WINDOW_SECONDS,
            ),
        )

        self._cached = config
        return config

    def _load_sync(self) -> dict[str, Any]:
        """Synchronously load the YAML file (runs in executor).

        Returns:
            Parsed YAML content as a dict, or empty dict on failure.

        Raises:
            FileNotFoundError: If the file does not exist.
        """
        if not os.path.isfile(self._path):
            return {}
        try:
            data = load_yaml(self._path)
            if not isinstance(data, dict):
                _LOGGER.warning("YAML config %s is not a dict — ignoring", self._path)
                return {}
            return data
        except Exception as exc:
            _LOGGER.warning("Failed to parse YAML config %s: %s", self._path, exc)
            return {}

    async def _async_write_defaults(self) -> None:
        """Write the default YAML config file via an executor job.

        Runs the file write in the executor to avoid blocking the event loop.
        """
        config = EvilCrowYamlConfig()
        content = self._render_yaml(config)
        await self._hass.async_add_executor_job(self._write_sync, content)

    def _render_yaml(self, config: EvilCrowYamlConfig) -> str:
        """Render the config as a YAML string.

        Args:
            config: The configuration to render.

        Returns:
            A YAML-formatted string.
        """
        lines = [
            "# EvilCrowRF V2 Integration Configuration",
            "#",
            "# This file is auto-created with defaults if it does not exist.",
            "# Modify values here to customize integration behavior.",
            "",
            "# FCC ID lookup API endpoint URL template.",
            "# Use {fcc_id} as a placeholder for the FCC ID.",
            f'{CONF_FCC_API_ENDPOINT}: "{config.fcc_api_endpoint}"',
            "",
            "# FCC ID used for testing the lookup service (optional).",
            f'# {CONF_FCC_TEST_ID}: ""',
            "",
            "# Request timeout in seconds for HTTP calls (1-120).",
            "request_timeout_seconds: 15",
            "",
            "# Capture timeout in seconds for signal capture/replay (1-300).",
            "capture_timeout_seconds: 30",
            "",
            "# Minimum occurrences before exposing an unknown signal as an entity.",
            f"# {CONF_EXPOSE_UNKNOWN_MIN_OCCURRENCES}: 3",
            "",
            "# Time window (seconds) for counting unknown signal occurrences.",
            f"# {CONF_EXPOSE_UNKNOWN_WINDOW_SECONDS}: 60",
            "",
        ]
        return "\n".join(lines)

    def _write_sync(self, content: str) -> None:
        """Synchronously write the YAML config file (runs in executor).

        Args:
            content: YAML content string.
        """
        try:
            with open(self._path, "w") as f:
                f.write(content)
            _LOGGER.debug("Wrote default YAML config to %s", self._path)
        except OSError as exc:
            _LOGGER.warning(
                "Failed to write default YAML config to %s: %s",
                self._path,
                exc,
            )

    def get_cached(self) -> EvilCrowYamlConfig | None:
        """Return the cached config, or None if not loaded yet.

        Returns:
            The loaded config from the last call to async_load(), or None.
        """
        return self._cached

    async def async_validate(self, raw: dict[str, Any]) -> dict[str, Any]:
        """Validate raw YAML data without loading from file.

        Args:
            raw: Raw configuration dict.

        Returns:
            Validated dict with all defaults filled in.

        Raises:
            vol.Invalid: If validation fails.
        """
        return cast(dict[str, Any], YAML_CONFIG_SCHEMA(raw))
