"""Shared pytest fixtures for EvilCrowRF V2 Home Assistant tests."""

from __future__ import annotations

from collections.abc import Generator
from unittest.mock import AsyncMock, MagicMock, patch

import aiohttp
import pytest


@pytest.fixture
def mock_transport() -> MagicMock:
    """Return a mock WiFiTransport with async methods pre-wired."""
    transport = MagicMock()
    transport.host = "192.168.1.100"
    transport.port = 80
    transport.device_id = "test-device-uuid"
    transport.connect = AsyncMock(return_value=True)
    transport.disconnect = AsyncMock()
    transport.send_frame = AsyncMock(return_value=True)
    transport.fetch_device_info = AsyncMock(
        return_value={
            "name": "EvilCrowRF Test",
            "fw_version": "3.0.1",
            "fw_major": 3,
            "fw_minor": 0,
            "fw_patch": 1,
            "transport": "wifi",
            "mac": "AA:BB:CC:DD:EE:FF",
            "sd_present": True,
            "nrf24_present": True,
            "cc1101_count": 2,
        }
    )
    return transport


@pytest.fixture
def mock_aiohttp_session() -> Generator[AsyncMock, None, None]:
    """Yield a mock aiohttp.ClientSession that returns a 200 response.

    The response body is a JSON-encoded device info dict.
    """
    session = AsyncMock(spec=aiohttp.ClientSession)
    response = AsyncMock(spec=aiohttp.ClientResponse)
    response.status = 200
    response.json = AsyncMock(
        return_value={
            "name": "EvilCrowRF Test",
            "fw_version": "3.0.1",
            "fw_major": 3,
            "fw_minor": 0,
            "fw_patch": 1,
            "transport": "wifi",
            "mac": "AA:BB:CC:DD:EE:FF",
            "sd_present": True,
            "nrf24_present": True,
            "cc1101_count": 2,
        }
    )

    cm = AsyncMock()
    cm.__aenter__ = AsyncMock(return_value=response)
    cm.__aexit__ = AsyncMock(return_value=None)

    session.get = MagicMock(return_value=cm)
    session.closed = False
    session.close = AsyncMock()

    with patch("aiohttp.ClientSession", return_value=session):
        yield session


@pytest.fixture
def sample_flipper_sub_files() -> dict[str, bytes]:
    """Return a dict mapping filenames to raw .sub file bytes."""
    return {
        "simple.sub": (
            b"Filetype: Flipper SubGhz Key File\n"
            b"Version: 1\n"
            b"Frequency: 433920000\n"
            b"Preset: FuriHalSubGhzPresetOok650Async\n"
            b"Protocol: 1\n"
            b"Bit: 24\n"
            b"Key: 00 A1 B2 C3\n"
            b"TE: 400\n"
            b"Repeat: 3\n"
        ),
        "with_comments.sub": (
            b"# Flipper SubGhz capture\n"
            b"Filetype: Flipper SubGhz Key File\n"
            b"Version: 1\n"
            b"Frequency: 315000000\n"
            b"# Custom preset\n"
            b"Preset: FuriHalSubGhzPresetCustom\n"
            b"Protocol: 2\n"
            b"Bit: 12\n"
            b"Key: AB CD\n"
            b"TE: 200\n"
            b"Repeat: 1\n"
            b"# End of file\n"
        ),
        "with_latency.sub": (
            b"Filetype: Flipper SubGhz Key File\n"
            b"Version: 1\n"
            b"Frequency: 868350000\n"
            b"Preset: FuriHalSubGhzPresetOok650Async\n"
            b"Protocol: 3\n"
            b"Bit: 32\n"
            b"Key: DE AD BE EF\n"
            b"TE: 300\n"
            b"Repeat: 5\n"
            b"Latency: 1000\n"
        ),
    }


@pytest.fixture
def hass_fixture() -> Generator[MagicMock, None, None]:
    """Yield a minimal Home Assistant mock using homeassistant patterns.

    Provides a mock hass object with a mock_hass fixture-style attributes
    (config, states, data, services, http).
    """
    hass = MagicMock()
    hass.config = MagicMock()
    hass.config.config_dir = "/config"
    hass.data = {}
    hass.states = AsyncMock()
    hass.services = MagicMock()
    hass.http = MagicMock()

    # Simulate hass.async_block_till_done pattern
    hass.async_block_till_done = AsyncMock()

    yield hass
