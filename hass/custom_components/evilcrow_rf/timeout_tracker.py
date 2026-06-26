"""PendingRequestTracker — coroutine-safe timeout tracking for request/response pairs."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from .const import REQUEST_TIMEOUT

_LOGGER = logging.getLogger(__name__)


class TimeoutTracker:
    """Coroutine-safe map: request_id -> (asyncio.Future, deadline_monotonic)."""

    def __init__(self, default_timeout: float = REQUEST_TIMEOUT):
        self._default_timeout = default_timeout
        self._pending: dict[int, tuple[asyncio.Future[Any], float]] = {}
        self._lock = asyncio.Lock()
        self._watcher: asyncio.Task[None] | None = None

    async def track(self, request_id: int, *, timeout: float | None = None) -> asyncio.Future[Any]:
        """Register a future for the given request_id.

        The returned future will be resolved by resolve() or will raise
        asyncio.TimeoutError on timeout.

        Args:
            request_id: The request ID to track.
            timeout: Custom timeout in seconds (default: self._default_timeout).

        Returns:
            An asyncio.Future that resolves with the response value.
        """
        fut: asyncio.Future[Any] = asyncio.get_event_loop().create_future()
        deadline = time.monotonic() + (timeout or self._default_timeout)

        async with self._lock:
            self._pending[request_id] = (fut, deadline)

        # Start the watcher if not already running
        if self._watcher is None or self._watcher.done():
            self._watcher = asyncio.create_task(self._watcher_loop())

        return fut

    async def resolve(self, request_id: int, value: Any) -> None:
        """Resolve the pending future for the given request_id.

        Called by the transport when a matching response arrives.

        Args:
            request_id: The request ID to resolve.
            value: The value to resolve the future with.
        """
        async with self._lock:
            entry = self._pending.pop(request_id, None)

        if entry is not None:
            fut, _ = entry
            if not fut.done():
                fut.set_result(value)
        else:
            _LOGGER.debug(
                "No pending request for ID %d (already resolved or timed out)",
                request_id,
            )

    async def cancel_all(self) -> None:
        """Cancel all pending futures with ConnectionError.

        Called on disconnect; fails every pending future so waiting code
        can handle the disconnection cleanly.
        """
        async with self._lock:
            pending = self._pending.copy()
            self._pending.clear()

        error = ConnectionError("Device disconnected")
        for fut, _ in pending.values():
            if not fut.done():
                fut.set_exception(error)

        # Cancel the watcher loop
        if self._watcher is not None and not self._watcher.done():
            self._watcher.cancel()
            self._watcher = None

    async def _watcher_loop(self) -> None:
        """Background loop; uses time.monotonic() to detect expirations."""
        try:
            while True:
                now = time.monotonic()
                expired: list[int] = []

                async with self._lock:
                    for req_id, (_fut, deadline) in self._pending.items():
                        if now >= deadline:
                            expired.append(req_id)

                    for req_id in expired:
                        fut, _ = self._pending.pop(req_id)
                        if not fut.done():
                            fut.set_exception(
                                TimeoutError(
                                    f"Request {req_id} timed out after {self._default_timeout}s"
                                )
                            )

                if not expired:
                    # No expired entries — sleep before next check
                    await asyncio.sleep(0.5)
                else:
                    # Yield control to event loop after handling timeouts
                    await asyncio.sleep(0)

                # Exit if no pending requests and no watcher needed
                async with self._lock:
                    if not self._pending:
                        return
        except asyncio.CancelledError:
            pass
