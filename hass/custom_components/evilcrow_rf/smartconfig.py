"""ESP-TOUCH SmartConfig WiFi provisioning for EvilCrowRF V2.

Phase 5 — firmware-dependent. Requires CMD_SMART_CONFIG (0xDC) on the device.
Phases 1-4 skip this module entirely.
"""

from __future__ import annotations

import asyncio
import logging
import socket
import struct
import time

_LOGGER = logging.getLogger(__name__)

SMARTCONFIG_PORT = 7000
SMARTCONFIG_MAGIC = 0x01


async def broadcast_smartconfig(
    ssid: str,
    password: str,
    channel: int | None = None,
    *,
    broadcast_addr: str = "255.255.255.255",
) -> bool:
    """Broadcast WiFi credentials via ESP-TOUCH SmartConfig.

    Creates a UDP socket, constructs the SmartConfig packet, and sends it
    repeatedly for up to 30 seconds (ESP-TOUCH requires multiple packets for
    reliability).

    The blocking socket.sendto() calls are run in a thread-pool executor so
    the HA event loop is never blocked.

    Returns True if at least one packet was sent successfully.
    """
    payload = _build_smartconfig_packet(ssid, password, channel)
    loop = asyncio.get_event_loop()

    def _send_loop() -> bool:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(0.1)
        sent = False
        try:
            for _ in range(300):  # 30s at 100ms intervals
                try:
                    sock.sendto(payload, (broadcast_addr, SMARTCONFIG_PORT))
                    sent = True
                except OSError:
                    pass
                time.sleep(0.1)
        finally:
            sock.close()
        return sent

    return await loop.run_in_executor(None, _send_loop)


def _build_smartconfig_packet(ssid: str, password: str, channel: int | None) -> bytes:
    """Construct the ESP-TOUCH packet following Espressif's wire format.

    Format: [magic:1B][total_len:1B][cmd:1B][ssid_len:1B][ssid:N]
            [pwd_len:1B][pwd:N][token_len:1B][token:N][checksum:1B]
    """
    import hashlib

    # Use a stable hash for the token (hash() is not deterministic across runs on 3.12+)
    token = struct.pack(
        "!I",
        int(hashlib.sha256((ssid + password).encode()).hexdigest()[:8], 16)
        & 0xFFFFFFFF,
    )

    body = struct.pack("B", len(ssid)) + ssid.encode("utf-8")
    body += struct.pack("B", len(password)) + password.encode("utf-8")
    body += struct.pack("B", len(token)) + token
    total_len = len(body) + 2  # magic + cmd + body
    checksum = (SMARTCONFIG_MAGIC + total_len + 1 + sum(body)) & 0xFF
    return (
        struct.pack("BBB", SMARTCONFIG_MAGIC, total_len, 1)
        + body
        + struct.pack("B", checksum)
    )
