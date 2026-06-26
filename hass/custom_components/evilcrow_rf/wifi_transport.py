"""WebSocket transport for EvilCrowRF V2 integration."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import random
import time
from collections.abc import Awaitable, Callable
from typing import Any

import aiohttp

from .binary_protocol import BinaryFrame, EvilCrowBinaryProtocol
from .const import (
    INFO_PATH,
    MAX_RECONNECT_DELAY,
    REQUEST_TIMEOUT,
    WS_PATH,
)

_LOGGER = logging.getLogger(__name__)


class WiFiTransport:
    """Manages the WebSocket connection to a single EvilCrowRF device.

    WiFi WebSocket frames arrive *intact* — chunking is a BLE-only concern.
    However, the firmware still tags every frame with chunk_id/chunk_num/total_chunks
    for legacy reasons, so the transport must accept either layout and pass each
    frame to the reader unchanged.
    """

    def __init__(
        self,
        host: str,
        port: int,
        device_id: str,
        *,
        on_message: Callable[[dict[str, Any]], Awaitable[None]] | None = None,
        on_disconnect: Callable[[], Awaitable[None]] | None = None,
    ):
        self._host = host
        self._port = port
        self._device_id = device_id  # persistent UUID (set by hass-config-sync)
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._session: aiohttp.ClientSession | None = None
        self._on_message = on_message
        self._on_disconnect = on_disconnect
        self._info: dict[str, Any] | None = None  # cached /api/info response
        self._connect_started_at: float | None = None  # time.monotonic()
        self._close_lock = asyncio.Lock()
        self._reconnect_task: asyncio.Task[None] | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._disconnect_requested = False
        self._protocol = EvilCrowBinaryProtocol()

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        return self._port

    @property
    def device_id(self) -> str:
        return self._device_id

    @property
    def info(self) -> dict[str, Any] | None:
        return self._info

    async def connect(self) -> bool:
        """Open HTTP session, GET /api/info, open WebSocket to ws://host:port/api/ws."""
        self._disconnect_requested = False
        self._session = aiohttp.ClientSession()
        self._connect_started_at = time.monotonic()

        try:
            # Fetch /api/info first
            info = await self.fetch_device_info()
            if info is None:
                _LOGGER.warning("Failed to fetch /api/info from %s:%d", self._host, self._port)
                await self._cleanup_session()
                return False
            self._info = info

            # Open WebSocket
            ws_url = f"ws://{self._host}:{self._port}{WS_PATH}"
            _LOGGER.debug("Connecting WebSocket to %s", ws_url)
            assert self._session is not None
            self._ws = await self._session.ws_connect(  # type: ignore
                ws_url,
                timeout=aiohttp.ClientWSTimeout(ws_close=REQUEST_TIMEOUT),  # type: ignore[call-arg]
                heartbeat=30.0,
            )
            _LOGGER.info(
                "Connected to EvilCrowRF at %s:%d (device: %s)",
                self._host,
                self._port,
                self._device_id,
            )

            # Start reader task
            self._reader_task = asyncio.create_task(self._reader_loop())
            return True

        except (aiohttp.ClientError, TimeoutError, OSError) as exc:
            _LOGGER.warning("Connection to %s:%d failed: %s", self._host, self._port, exc)
            await self._cleanup_session()
            return False

    async def _cleanup_session(self) -> None:
        """Close the HTTP session if open."""
        if self._session and not self._session.closed:
            with contextlib.suppress(Exception):
                await self._session.close()
        self._session = None

    async def disconnect(self) -> None:
        """Close WebSocket and HTTP session; idempotent."""
        self._disconnect_requested = True

        # Cancel reconnect if running
        if self._reconnect_task is not None:
            self._reconnect_task.cancel()
            self._reconnect_task = None

        # Cancel reader if running
        if self._reader_task is not None:
            self._reader_task.cancel()
            self._reader_task = None

        async with self._close_lock:
            ws = self._ws
            self._ws = None
            if ws is not None and not ws.closed:
                with contextlib.suppress(Exception):
                    await ws.close()

            await self._cleanup_session()
            self._info = None
            _LOGGER.debug("Disconnected from %s:%d", self._host, self._port)

    async def send_frame(self, frames: list[bytes], *, timeout: float = REQUEST_TIMEOUT) -> bool:
        """Send binary frames over WebSocket with a per-call timeout.

        Args:
            frames: List of encoded binary frames to send.
            timeout: Maximum time to wait for each frame send.

        Returns:
            True if all frames were sent successfully, False on error.
        """
        if self._ws is None or self._ws.closed:
            _LOGGER.debug("Cannot send: WebSocket not connected")
            return False

        for frame in frames:
            try:
                await asyncio.wait_for(self._ws.send_bytes(frame), timeout=timeout)
            except (TimeoutError, ConnectionError, OSError) as exc:
                _LOGGER.warning(
                    "Failed to send frame to %s:%d: %s",
                    self._host,
                    self._port,
                    exc,
                )
                return False
        return True

    async def fetch_device_info(self) -> dict[str, Any] | None:
        """GET http://host:port/api/info. Returns parsed JSON or None.

        Expected schema (validated; missing fields log a warning but do not fail):
          {
            "name": str,
            "fw_version": str,        # e.g. "3.0.1"
            "fw_major": int,
            "fw_minor": int,
            "fw_patch": int,
            "transport": "wifi",
            "mac": str,               # NOT used as identity; informational only
            "sd_present": bool,
            "nrf24_present": bool,
            "cc1101_count": int,
          }
        """
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession()

        url = f"http://{self._host}:{self._port}{INFO_PATH}"
        try:
            assert self._session is not None
            async with self._session.get(
                url, timeout=aiohttp.ClientTimeout(total=REQUEST_TIMEOUT)
            ) as resp:
                if resp.status != 200:
                    _LOGGER.warning("/api/info returned HTTP %d from %s", resp.status, url)
                    return None
                data = await resp.json()
        except (aiohttp.ClientError, TimeoutError, OSError) as exc:
            _LOGGER.warning("Failed to fetch /api/info from %s: %s", url, exc)
            return None

        # Validate expected fields (log warnings but don't fail)
        expected_fields = [
            "name",
            "fw_version",
            "fw_major",
            "fw_minor",
            "fw_patch",
        ]
        for field in expected_fields:
            if field not in data:
                _LOGGER.warning("/api/info from %s is missing field '%s'", url, field)

        return data

    async def _reader_loop(self) -> None:
        """Background loop: read WebSocket binary frames, hand off to on_message."""
        ws = self._ws
        if ws is None:
            return

        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.BINARY:
                    try:
                        frame = BinaryFrame.decode(msg.data)
                        parsed = EvilCrowBinaryProtocol.parse_response(frame)
                        if self._on_message:
                            await self._on_message(parsed)
                    except ValueError as exc:
                        _LOGGER.warning("Failed to decode frame: %s", exc)
                elif msg.type == aiohttp.WSMsgType.CLOSED:
                    _LOGGER.debug("WebSocket closed by peer")
                    break
                elif msg.type == aiohttp.WSMsgType.ERROR:
                    _LOGGER.error("WebSocket error: %s", ws.exception())
                    break
        except asyncio.CancelledError:
            pass
        except (ConnectionError, OSError) as exc:
            _LOGGER.debug("WebSocket reader error: %s", exc)
        finally:
            # Notify disconnect handler
            if not self._disconnect_requested:
                _LOGGER.info(
                    "Connection lost to %s:%d, starting reconnect",
                    self._host,
                    self._port,
                )
                if self._on_disconnect:
                    await self._on_disconnect()
                # Reconnect
                self._reconnect_task = asyncio.create_task(self._reconnect_loop())

    async def _reconnect_loop(self) -> None:
        """Reconnect with exponential backoff."""
        attempt = 0
        while not self._disconnect_requested:
            attempt += 1
            delay = min(MAX_RECONNECT_DELAY, 2**attempt) + random.uniform(0, 1)
            _LOGGER.debug(
                "Reconnect attempt %d for %s:%d in %.1fs",
                attempt,
                self._host,
                self._port,
                delay,
            )
            try:
                await asyncio.sleep(delay)
            except asyncio.CancelledError:
                return

            if self._disconnect_requested:
                return

            # Re-fetch /api/info and reconnect
            success = await self.connect()
            if success:
                _LOGGER.info(
                    "Reconnected to %s:%d after %d attempts",
                    self._host,
                    self._port,
                    attempt,
                )
                return

        _LOGGER.warning(
            "Gave up reconnecting to %s:%d after %d attempts",
            self._host,
            self._port,
            attempt,
        )
