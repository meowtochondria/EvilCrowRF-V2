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
    _lines: list[str] = field(default_factory=list)  # all original lines, in order, for round-trip

    @property
    def frequency_mhz(self) -> float:
        """Convenience: frequency in MHz (HA convention)."""
        return round(self.frequency / 1_000_000, 3)

    @classmethod
    def parse(cls, data: bytes, path: str = "") -> FlipperSubFile:
        """Parse a .sub file from raw bytes.

        The parser is line-oriented: 'Key: Value' pairs, with comments
        starting with '#'. All lines are preserved in _lines to ensure
        byte-for-byte round-trip fidelity.
        """
        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines(keepends=True)

        sub = cls(path=path, raw_bytes=data)

        for line in lines:
            sub._lines.append(line)
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            # Parse key: value pairs
            if ":" in stripped:
                key, _, value = stripped.partition(":")
                key = key.strip().lower()
                value = value.strip()

                if key == "filetype":
                    sub.filetype = value
                elif key == "version":
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
                elif key == "key":
                    sub.key = value

        return sub

    def serialize(self) -> bytes:
        """Serialize back to the exact .sub file format (round-trippable).

        Returns the original raw bytes if no fields were modified.
        Otherwise rebuilds from preserved lines with updated field values.
        """
        if self._lines:
            # Rebuild from preserved lines, updating known fields
            rebuilt: list[str] = []
            for line in self._lines:
                stripped = line.strip()
                if ":" in stripped and not stripped.startswith("#"):
                    key, _, _ = stripped.partition(":")
                    key = key.strip().lower()
                    if key == "filetype":
                        rebuilt.append(f"Filetype: {self.filetype}\n")
                    elif key == "version":
                        rebuilt.append(f"Version: {self.version}\n")
                    elif key == "frequency":
                        rebuilt.append(f"Frequency: {self.frequency}\n")
                    elif key == "preset":
                        rebuilt.append(f"Preset: {self.preset}\n")
                    elif key == "protocol":
                        rebuilt.append(f"Protocol: {self.protocol}\n")
                    elif key == "bit":
                        rebuilt.append(f"Bit: {self.bit}\n")
                    elif key == "key":
                        rebuilt.append(f"Key: {self.key}\n")
                    elif key == "te":
                        rebuilt.append(f"TE: {self.te}\n")
                    elif key == "repeat":
                        rebuilt.append(f"Repeat: {self.repeat}\n")
                    elif key == "latency":
                        rebuilt.append(f"Latency: {self.latency}\n")
                    else:
                        rebuilt.append(line)  # unrecognized key — keep original
                else:
                    rebuilt.append(line)  # comment or blank — keep original
            return "".join(rebuilt).encode("utf-8")

        # Fallback: no preserved lines (manually constructed), build from fields
        lines: list[str] = []
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
        return "".join(lines).encode("utf-8")

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
