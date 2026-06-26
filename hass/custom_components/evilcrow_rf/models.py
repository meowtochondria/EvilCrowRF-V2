"""Shared dataclasses for the EvilCrowRF V2 integration."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class DeviceInfo:
    """Information about an EvilCrowRF device."""

    host: str
    port: int
    device_id: str  # stable UUID (HA-assigned, persisted in device's config.txt)
    name: str  # device display name (from /api/info)
    firmware_version: str  # e.g. "3.0.1"
    fw_major: int
    fw_minor: int
    fw_patch: int
    transport: str  # "wifi"
    mac: str | None = None  # informational only; not used as identity
    capabilities: dict[str, Any] = field(
        default_factory=dict
    )  # sd_present, nrf24_present, cc1101_count, ...


@dataclass
class HassConfigSyncResult:
    """Result of a hass-config-sync exchange."""

    existing_device_id: str | None  # UUID the device already had, or None
    assigned_device_id: str  # UUID the integration will use going forward
    was_newly_assigned: bool  # True if we had to assign a fresh UUID
