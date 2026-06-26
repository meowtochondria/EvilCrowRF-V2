"""Tests for the TimeoutTracker — coroutine-safe request/response timeout tracking.

Covers track/resolve lifecycle, timeout firing, cancel_all, concurrent
access, and edge cases.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

from custom_components.evilcrow_rf.timeout_tracker import TimeoutTracker


@pytest.mark.usefixtures("hass_fixture")
class TestTimeoutTrackerLifecycle:
    """Track/resolve lifecycle for individual requests."""

    async def test_track_and_resolve(self) -> None:
        """Track a request, resolve it, and verify the future gets the value."""
        tracker = TimeoutTracker(default_timeout=60)
        fut = await tracker.track(1)
        assert not fut.done()

        await tracker.resolve(1, {"status": "ok"})
        result = await fut
        assert result == {"status": "ok"}

    async def test_resolve_before_await(self) -> None:
        """Resolving before awaiting the future should still work."""
        tracker = TimeoutTracker(default_timeout=60)
        fut = await tracker.track(1)
        await tracker.resolve(1, "hello")
        result = await fut
        assert result == "hello"

    async def test_track_multiple_and_resolve(self) -> None:
        """Multiple tracked requests can be resolved independently."""
        tracker = TimeoutTracker(default_timeout=60)
        fut1 = await tracker.track(1)
        fut2 = await tracker.track(2)

        await tracker.resolve(1, "first")
        await tracker.resolve(2, "second")

        assert await fut1 == "first"
        assert await fut2 == "second"

    async def test_resolve_unregistered_id(self) -> None:
        """Resolving a request_id that was never tracked should not error."""
        tracker = TimeoutTracker(default_timeout=60)
        # Should not raise
        await tracker.resolve(999, "nobody")

    async def test_resolve_idempotent(self) -> None:
        """Resolving the same request_id twice is a no-op."""
        tracker = TimeoutTracker(default_timeout=60)
        fut = await tracker.track(1)
        await tracker.resolve(1, "value")
        # Second resolve should be a no-op (already resolved)
        await tracker.resolve(1, "other")
        result = await fut
        assert result == "value"

    async def test_pending_count_drops_after_resolve(self) -> None:
        """Internal pending dict is cleaned up after resolve."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.track(1)
        assert len(tracker._pending) == 1
        await tracker.resolve(1, "ok")
        assert len(tracker._pending) == 0


@pytest.mark.usefixtures("hass_fixture")
class TestTimeoutTrackerTimeout:
    """Timeout firing and edge cases around deadline expiry."""

    async def test_timeout_fires(self) -> None:
        """A request that is never resolved should time out."""
        tracker = TimeoutTracker(default_timeout=0.05)  # 50 ms
        fut = await tracker.track(1)

        with pytest.raises(asyncio.TimeoutError):
            await fut

    async def test_timeout_error_message(self) -> None:
        """The TimeoutError message includes the request ID."""
        tracker = TimeoutTracker(default_timeout=0.05)
        fut = await tracker.track(42)

        with pytest.raises(asyncio.TimeoutError, match="Request 42 timed out"):
            await fut

    async def test_custom_timeout_per_request(self) -> None:
        """A custom timeout per-track call overrides the default."""
        tracker = TimeoutTracker(default_timeout=60)
        fut = await tracker.track(1, timeout=0.05)  # override: 50 ms

        with pytest.raises(asyncio.TimeoutError):
            await fut

    async def test_timeout_does_not_affect_other_requests(self) -> None:
        """A timeout on one request does not cancel other pending requests."""
        tracker = TimeoutTracker(default_timeout=60)
        fut_short = await tracker.track(1, timeout=0.02)
        fut_long = await tracker.track(2, timeout=60)

        # Let the short one time out
        with pytest.raises(asyncio.TimeoutError):
            await fut_short

        # The long one should still be resolvable
        assert not fut_long.done()
        await tracker.resolve(2, "still alive")
        result = await fut_long
        assert result == "still alive"

    async def test_expired_entries_cleaned_up(self) -> None:
        """Timed-out entries are removed from the pending dict."""
        tracker = TimeoutTracker(default_timeout=0.02)
        await tracker.track(1)
        await asyncio.sleep(0.05)
        # Pending should be empty after timeout fires
        assert len(tracker._pending) == 0

    async def test_watcher_exits_when_no_pending(self) -> None:
        """The watcher loop exits when there are no pending requests."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.track(1)
        await tracker.resolve(1, "done")
        # Give watcher a moment to notice and exit
        await asyncio.sleep(0.05)
        assert tracker._watcher is None or tracker._watcher.done()


@pytest.mark.usefixtures("hass_fixture")
class TestTimeoutTrackerCancelAll:
    """cancel_all behaviour — used on device disconnect."""

    async def test_cancel_all_fails_pending(self) -> None:
        """cancel_all raises ConnectionError on all pending futures."""
        tracker = TimeoutTracker(default_timeout=60)
        fut1 = await tracker.track(1)
        fut2 = await tracker.track(2)

        await tracker.cancel_all()

        with pytest.raises(ConnectionError, match="Device disconnected"):
            await fut1

        with pytest.raises(ConnectionError, match="Device disconnected"):
            await fut2

    async def test_cancel_all_clears_pending(self) -> None:
        """After cancel_all, the pending dict is empty."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.track(1)
        await tracker.track(2)
        await tracker.cancel_all()
        assert len(tracker._pending) == 0

    async def test_cancel_all_cancels_watcher(self) -> None:
        """cancel_all stops the watcher loop."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.track(1)
        assert tracker._watcher is not None and not tracker._watcher.done()

        await tracker.cancel_all()
        # Watcher should be cancelled
        assert tracker._watcher is None or tracker._watcher.done()

    async def test_cancel_all_twice_is_safe(self) -> None:
        """Calling cancel_all multiple times is idempotent."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.track(1)
        await tracker.cancel_all()
        # Second call should not raise
        await tracker.cancel_all()

    async def test_cancel_all_with_no_pending(self) -> None:
        """cancel_all with no tracked requests is a no-op."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.cancel_all()
        # Should not raise


@pytest.mark.usefixtures("hass_fixture")
class TestTimeoutTrackerConcurrency:
    """Concurrent access to the tracker from multiple tasks."""

    async def test_concurrent_track_and_resolve(self) -> None:
        """Multiple coroutines can track and resolve concurrently."""
        tracker = TimeoutTracker(default_timeout=60)
        results: dict[int, Any] = {}

        async def producer(req_id: int, value: str) -> None:
            await asyncio.sleep(0.01)
            await tracker.resolve(req_id, value)

        async def consumer(req_id: int) -> None:
            fut = await tracker.track(req_id)
            result = await fut
            results[req_id] = result

        tasks = [
            asyncio.create_task(consumer(1)),
            asyncio.create_task(consumer(2)),
            asyncio.create_task(consumer(3)),
            asyncio.create_task(producer(1, "a")),
            asyncio.create_task(producer(2, "b")),
            asyncio.create_task(producer(3, "c")),
        ]
        await asyncio.gather(*tasks)
        assert results == {1: "a", 2: "b", 3: "c"}

    async def test_concurrent_track_same_id(self) -> None:
        """Tracking the same request_id twice overwrites the first (latest wins)."""
        tracker = TimeoutTracker(default_timeout=60)
        fut1 = await tracker.track(1)
        fut2 = await tracker.track(1)

        # Resolving ID 1 should resolve the *second* future (latest registered)
        await tracker.resolve(1, "winner")

        # fut1 was replaced — it should never be resolved (or it may be orphaned)
        # The tracker only keeps the latest future for a given ID
        result = await fut2
        assert result == "winner"

        # fut1 should be orphaned; let's ensure at least it's not left dangling
        assert fut1.done() is False or fut1.cancelled()

    async def test_watcher_restarts_after_cancel(self) -> None:
        """If the watcher was cancelled (e.g. by cancel_all), tracking restarts it."""
        tracker = TimeoutTracker(default_timeout=60)
        await tracker.track(1)
        await tracker.cancel_all()
        # Watcher is now cancelled; tracking a new request should restart it
        assert tracker._watcher is None or tracker._watcher.done()

        fut = await tracker.track(2, timeout=0.05)
        # Watcher should have been restarted
        assert tracker._watcher is not None and not tracker._watcher.done()

        with pytest.raises(asyncio.TimeoutError):
            await fut


@pytest.mark.usefixtures("hass_fixture")
class TestTimeoutTrackerEdgeCases:
    """Edge cases: default values, watcher lifecycle, etc."""

    async def test_default_timeout_applied(self) -> None:
        """Default timeout from constructor is used when no override given."""
        tracker = TimeoutTracker(default_timeout=0.03)
        fut = await tracker.track(1)

        with pytest.raises(asyncio.TimeoutError):
            await fut

    async def test_very_long_timeout(self) -> None:
        """A long timeout does not fire when resolve happens quickly."""
        tracker = TimeoutTracker(default_timeout=300)
        fut = await tracker.track(1)
        await tracker.resolve(1, "quick")
        result = await fut
        assert result == "quick"

    async def test_watcher_not_started_until_first_track(self) -> None:
        """The watcher loop is None before any track call."""
        tracker = TimeoutTracker(default_timeout=60)
        assert tracker._watcher is None

    async def test_track_after_watcher_exit_restarts_watcher(self) -> None:
        """If the watcher has exited (no pending), a new track restarts it."""
        tracker = TimeoutTracker(default_timeout=60)
        _ = await tracker.track(1)
        await tracker.resolve(1, "done")
        # Let watcher exit
        await asyncio.sleep(0.05)
        before = tracker._watcher
        assert before is None or before.done()

        # New track should restart
        fut2 = await tracker.track(2)
        after = tracker._watcher
        assert after is not None and not after.done()

        await tracker.resolve(2, "restarted")
        assert await fut2 == "restarted"
