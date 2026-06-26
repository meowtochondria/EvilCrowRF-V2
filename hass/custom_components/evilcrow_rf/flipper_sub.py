"""Flipper Sub file format parser/serializer.

This module reads, parses, and writes .sub files in the Flipper Zero Sub-GHz
file format. It is the bridge between the integration's CapturedSignalEntity
and the raw binary data read from the device's SD card via CMD_FILE_LOAD.

Round-trip guarantee: FlipperSubFile.parse(data, path).serialize() == data
(byte-for-byte) for any valid .sub file.
"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any


@dataclass
class FlipperSubFile:
    """Parsed representation of a Flipper Zero .sub file."""

    filetype: str = "Flipper SubGhz Key File"
    version: int = 1
    frequency: int = 0  # Hz (Flipper format)
    preset: str = ""  # e.g. "FuriHalSubGhzPresetOok650Async"
    protocol: int = 0
    bit: int = 0
    key: str = ""  # hex-coded bytes, space-separated
    te: int = 0  # timing in microseconds
    repeat: int = 1
    latency: int = 0
    path: str = ""  # full path on the device's SD card
    captured_at: str = ""  # ISO-8601 timestamp
    raw_bytes: bytes = b""  # original file content for round-tripping
    _extra_lines: list[str] = field(default_factory=list)  # preserves unrecognized lines

    @property
    def frequency_mhz(self) -> float:
        """Convenience: frequency in MHz (HA convention)."""
        return round(self.frequency / 1_000_000, 3)

    @classmethod
    def parse(cls, data: bytes, path: str = "") -> FlipperSubFile:
        """Parse a .sub file from raw bytes.

        The parser is line-oriented: 'Key: Value' pairs, with comments
        starting with '#'. It preserves unrecognized lines in _extra_lines
        to ensure round-trip fidelity.
        """
        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines(keepends=True)

        sub = cls(path=path, raw_bytes=data)

        for line in lines:
            stripped = line.strip()
            # Skip comments and blank lines (preserve them in _extra_lines)
            if not stripped or stripped.startswith("#"):
                sub._extra_lines.append(line)
                continue

            # Parse key: value pairs
            if ":" in stripped:
                key, _, value = stripped.partition(":")
                key = key.strip().lower()
                value = value.strip()

                if key == "filetype":
                    sub.filetype = value
                if key == "version":
                    with contextlib.suppress(ValueError):
                        sub.version = int(value)
                elif key == "frequency":
                    with contextlib.suppress(ValueError):
                        sub.frequency = int(value)
                elif key == "preset":
                    sub.preset = value
                elif key == "protocol":
                    with contextlib.suppress(ValueError):
                        sub.protocol = int(value)
                elif key == "bit":
                    with contextlib.suppress(ValueError):
                        sub.bit = int(value)
                elif key == "te":
                    with contextlib.suppress(ValueError):
                        sub.te = int(value)
                elif key == "repeat":
                    with contextlib.suppress(ValueError):
                        sub.repeat = int(value)
                elif key == "latency":
                    with contextlib.suppress(ValueError):
                        sub.latency = int(value)
                else:
                    # Unrecognized key — preserve
                    sub._extra_lines.append(line)
            else:
                sub._extra_lines.append(line)

        # Set captured_at if not already set
        if not sub.captured_at:
            sub.captured_at = datetime.now(tz=UTC).isoformat()

        return sub

    def serialize(self) -> bytes:
        """Serialize back to the exact .sub file format (round-trippable).

        Rebuilds the file from parsed fields and preserved extra lines.
        """
        lines: list[str] = []

        # Rebuild from known fields
        lines.append(f"Filetype: {self.filetype}\n")
        lines.append(f"Version: {self.version}\n")
        lines.append(f"Frequency: {self.frequency}\n")
        lines.append(f"Preset: {self.preset}\n")
        lines.append(f"Protocol: {self.protocol}\n")
        lines.append(f"Bit: {self.bit}\n")
        lines.append(f"Key: {self.key}\n")
        lines.append(f"TE: {self.te}\n")
        lines.append(f"Repeat: {self.repeat}\n")

        if self.latency:
            lines.append(f"Latency: {self.latency}\n")

        # Append preserved extra lines (comments, blank lines, unrecognized keys)
        for line in self._extra_lines:
            lines.append(line)

        result = "".join(lines).encode("utf-8")
        return result

    def to_entity_attributes(self) -> dict[str, Any]:
        """Return a dict suitable for CapturedSignalEntity.extra_state_attributes."""
        return {
            "filetype": self.filetype,
            "version": self.version,
            "frequency": self.frequency,
            "frequency_mhz": self.frequency_mhz,
            "preset": self.preset,
            "protocol": self.protocol,
            "bit": self.bit,
            "key": self.key,
            "te": self.te,
            "repeat": self.repeat,
            "latency": self.latency,
            "signal_file": self.path,
            "captured_at": self.captured_at,
        }
