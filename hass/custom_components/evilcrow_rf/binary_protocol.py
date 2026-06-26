"""Binary protocol implementation for EvilCrowRF V2.

Reimplements the FirmwareBinaryProtocol from the mobile app in Python.
Pure data, no I/O — frame building and response parsing only.
"""

from __future__ import annotations

import logging
import struct
from dataclasses import dataclass
from typing import Any

from .const import (
    BINARY_MAGIC,
    CMD_FILE_LIST,
    CMD_FILE_LOAD,
    CMD_FILE_RENAME,
    CMD_HA_CONFIG_SYNC,
    CMD_IDLE,
    CMD_SCAN,
    CMD_SEND_SIGNAL,
    CMD_SETTINGS_UPDATE,
    CMD_SMART_CONFIG,
    CMD_START_MONITOR,
    CMD_START_RECORDING,
    CMD_STOP_MONITOR,
    CMD_STOP_RECORDING,
    FRAME_TYPE_DATA,
    MAX_PAYLOAD_SIZE,
    RESP_DEVICE_NAME,
    RESP_FILE_ACTION,
    RESP_FILE_CONTENT,
    RESP_FILE_LIST,
    RESP_HA_CONFIG_SYNC,
    RESP_HA_SETTINGS_WRITE_SD_ACK,
    RESP_SETTINGS_SYNC,
    RESP_SIGNAL_DETECTED,
    RESP_SIGNAL_ERROR,
    RESP_SIGNAL_MONITOR,
    RESP_SIGNAL_RECORDED,
    RESP_SIGNAL_SENDING_ERROR,
    RESP_SIGNAL_SENT,
    RESP_SMART_CONFIG_STATUS,
    RESP_VERSION_INFO,
)

_LOGGER = logging.getLogger(__name__)


@dataclass
class BinaryFrame:
    """A single binary protocol frame."""

    magic: int = BINARY_MAGIC
    frame_type: int = FRAME_TYPE_DATA
    chunk_id: int = 0  # also used as request sequence number (1..255)
    chunk_num: int = 1
    total_chunks: int = 1
    data: bytes = b""

    def encode(self) -> bytes:
        """Encode frame to bytes with XOR checksum."""
        header = struct.pack(
            "BBBBB",
            self.magic,
            self.frame_type,
            self.chunk_id,
            self.chunk_num,
            self.total_chunks,
        )
        data_len = len(self.data)
        len_field = struct.pack("<H", data_len)
        payload = header + len_field + self.data
        checksum = 0
        for b in payload:
            checksum ^= b
        return payload + struct.pack("B", checksum)

    @staticmethod
    def decode(data: bytes) -> BinaryFrame:
        """Parse a binary frame, validate checksum, return frame."""
        if len(data) < 8:
            raise ValueError(f"Frame too short: {len(data)} bytes (minimum 8 required)")

        magic, frame_type, chunk_id, chunk_num, total_chunks = struct.unpack_from("BBBBB", data, 0)
        (data_len,) = struct.unpack_from("<H", data, 5)

        if len(data) < 8 + data_len:
            raise ValueError(
                f"Frame payload incomplete: expected {data_len} bytes, got {len(data) - 8}"
            )

        payload = data[: 7 + data_len]
        expected_checksum = data[7 + data_len]

        actual_checksum = 0
        for b in payload:
            actual_checksum ^= b

        if actual_checksum != expected_checksum:
            raise ValueError(
                f"Checksum mismatch: calculated 0x{actual_checksum:02X}, "
                f"expected 0x{expected_checksum:02X}"
            )

        frame_data = data[7 : 7 + data_len]

        return BinaryFrame(
            magic=magic,
            frame_type=frame_type,
            chunk_id=chunk_id,
            chunk_num=chunk_num,
            total_chunks=total_chunks,
            data=frame_data,
        )


class EvilCrowBinaryProtocol:
    """Command builder and response parser. Pure data, no I/O."""

    def __init__(self) -> None:
        self._next_request_id: int = 0  # monotonic, wraps 1..255

    def _next_id(self) -> int:
        self._next_request_id = (self._next_request_id % 255) + 1
        return self._next_request_id

    def _build_single_frame(self, cmd_byte: int, payload: bytes = b"") -> list[bytes]:
        """Build a single-frame command with the given command byte and payload."""
        request_id = self._next_id()
        inner = struct.pack("B", cmd_byte) + payload
        frame = BinaryFrame(
            chunk_id=request_id,
            chunk_num=1,
            total_chunks=1,
            data=inner,
        )
        return [frame.encode()]

    def _build_chunked_frames(
        self, cmd_byte: int, payload: bytes, max_chunk_size: int = MAX_PAYLOAD_SIZE
    ) -> list[bytes]:
        """Build a chunked command when payload exceeds max_chunk_size.

        The first chunk carries the command byte; subsequent chunks carry
        only continuation data.
        """
        request_id = self._next_id()
        # Reserve 1 byte for the command byte in the first chunk
        first_chunk_max = max_chunk_size - 1
        chunks: list[bytes] = []
        offset = 0
        total_size = len(payload) + 1  # +1 for cmd byte
        total_chunks = (total_size + max_chunk_size - 1) // max_chunk_size

        # First chunk: command byte + data
        chunk_payload = struct.pack("B", cmd_byte)
        first_size = min(first_chunk_max, len(payload))
        chunk_payload += payload[:first_size]
        offset = first_size
        chunks.append(
            BinaryFrame(
                chunk_id=request_id,
                chunk_num=1,
                total_chunks=total_chunks,
                data=chunk_payload,
            ).encode()
        )

        # Remaining chunks: continuation data only
        for chunk_num in range(2, total_chunks + 1):
            chunk_size = min(max_chunk_size, len(payload) - offset)
            chunk_data = payload[offset : offset + chunk_size]
            offset += chunk_size
            chunks.append(
                BinaryFrame(
                    chunk_id=request_id,
                    chunk_num=chunk_num,
                    total_chunks=total_chunks,
                    data=chunk_data,
                ).encode()
            )

        return chunks

    # ---- command builders ----

    def build_request_record_command(
        self,
        frequency: int,
        module: int,
        preset: int = 0,
    ) -> list[bytes]:
        """Build Start Recording command frames (chunked if needed).

        Payload format: [cmd:1B][frequency:uint32 LE][module:uint8][preset:uint8]
        """
        payload = struct.pack("<IBB", frequency, module, preset)
        return self._build_chunked_frames(CMD_START_RECORDING, payload)

    def build_stop_record_command(self) -> list[bytes]:
        """Build Stop Recording command."""
        return self._build_single_frame(CMD_STOP_RECORDING)

    def build_idle_command(self) -> list[bytes]:
        """Build Idle command (stop any in-progress radio activity)."""
        return self._build_single_frame(CMD_IDLE)

    def build_send_signal_command(self, file_path: str) -> list[bytes]:
        """Build Send Signal command frames (replay .sub file).

        Payload format: [cmd:1B][path_len:uint8][path:N]
        """
        path_bytes = file_path.encode("utf-8")
        payload = struct.pack("B", len(path_bytes)) + path_bytes
        return self._build_chunked_frames(CMD_SEND_SIGNAL, payload)

    def build_file_list_command(self, path: str = "/") -> list[bytes]:
        """Build File List command; response is chunked on WiFi too if > 500 B.

        Payload format: [cmd:1B][path_len:uint8][path:N]
        """
        path_bytes = path.encode("utf-8")
        payload = struct.pack("B", len(path_bytes)) + path_bytes
        return self._build_chunked_frames(CMD_FILE_LIST, payload)

    def build_file_rename_command(self, old_path: str, new_path: str) -> list[bytes]:
        """Build File Rename command.

        Payload format: [cmd:1B][old_len:uint8][old:N][new_len:uint8][new:N]
        """
        old_bytes = old_path.encode("utf-8")
        new_bytes = new_path.encode("utf-8")
        payload = (
            struct.pack("B", len(old_bytes))
            + old_bytes
            + struct.pack("B", len(new_bytes))
            + new_bytes
        )
        return self._build_chunked_frames(CMD_FILE_RENAME, payload)

    def build_file_load_command(self, file_path: str) -> list[bytes]:
        """Build File Load command (CMD_FILE_LOAD 0xA5).

        Payload format: [cmd:1B][path_len:uint8][path:N]
        """
        path_bytes = file_path.encode("utf-8")
        payload = struct.pack("B", len(path_bytes)) + path_bytes
        return self._build_chunked_frames(CMD_FILE_LOAD, payload)

    def build_scan_command(self) -> list[bytes]:
        """Build Scan command (CMD_SCAN 0x02)."""
        return self._build_single_frame(CMD_SCAN)

    def build_start_monitor_command(
        self,
        module: int,
        frequency: int,
        rssi_threshold: int = -80,
    ) -> list[bytes]:
        """Build Start Monitor command (CMD_START_MONITOR 0x1B).

        Payload format: [cmd:1B][module:uint8][frequency:uint32 LE][rssi_threshold:int8]
        """
        payload = struct.pack("<Bi", module, frequency) + struct.pack("b", rssi_threshold)
        return self._build_chunked_frames(CMD_START_MONITOR, payload)

    def build_stop_monitor_command(self) -> list[bytes]:
        """Build Stop Monitor command (CMD_STOP_MONITOR 0x1C)."""
        return self._build_single_frame(CMD_STOP_MONITOR)

    def build_settings_update_command(
        self,
        setting_key: int,
        setting_value: bytes,
    ) -> list[bytes]:
        """Build a generic settings-update command.

        Payload format: [cmd:1B][key:uint8][value_len:uint16 LE][value:N]
        """
        payload = (
            struct.pack("B", setting_key) + struct.pack("<H", len(setting_value)) + setting_value
        )
        return self._build_chunked_frames(CMD_SETTINGS_UPDATE, payload)

    def build_smartconfig_command(
        self,
        ssid: str,
        password: str,
        channel: int | None = None,
    ) -> list[bytes]:
        """Build a SmartConfig (ESP-TOUCH) provisioning command (CMD_SMART_CONFIG 0xDC).

        Payload format: [cmd:1B][ssid_len:uint8][ssid:N][pwd_len:uint8][pwd:N][channel:uint8]
        """
        ssid_bytes = ssid.encode("utf-8")
        pwd_bytes = password.encode("utf-8")
        payload = (
            struct.pack("B", len(ssid_bytes))
            + ssid_bytes
            + struct.pack("B", len(pwd_bytes))
            + pwd_bytes
        )
        if channel is not None:
            payload += struct.pack("B", channel)
        return self._build_chunked_frames(CMD_SMART_CONFIG, payload)

    def build_ha_config_sync_command(self) -> list[bytes]:
        """Ask the device for its HA-assigned UUID (CMD_HA_CONFIG_SYNC 0xD8)."""
        return self._build_single_frame(CMD_HA_CONFIG_SYNC)

    # ---- response parsing ----

    @staticmethod
    def parse_response(frame: BinaryFrame) -> dict[str, Any]:
        """Parse a binary response frame into a structured dict.

        Returns a dict with keys:
          - 'type': str — the response type name
          - 'request_id': int — the chunk_id from the frame
          - 'data': dict — parsed payload fields

        Raises ValueError on unknown response type or malformed payload.
        """
        if not frame.data:
            return {
                "type": "unknown",
                "request_id": frame.chunk_id,
                "data": {},
            }

        response_byte = frame.data[0]
        payload = frame.data[1:]

        base: dict[str, Any] = {
            "request_id": frame.chunk_id,
            "data": {},
        }

        if response_byte == RESP_SIGNAL_DETECTED:
            base["type"] = "SignalDetected"
            if len(payload) >= 1:
                base["data"]["rssi"] = struct.unpack("b", payload[:1])[0]
            return base

        elif response_byte == RESP_SIGNAL_RECORDED:
            base["type"] = "SignalRecorded"
            if payload:
                filename = payload.decode("utf-8", errors="replace")
                base["data"]["filename"] = filename
            return base

        elif response_byte == RESP_SIGNAL_SENT:
            base["type"] = "SignalSent"
            if payload:
                filename = payload.decode("utf-8", errors="replace")
                base["data"]["filename"] = filename
            return base

        elif response_byte == RESP_SIGNAL_ERROR:
            base["type"] = "SignalError"
            if payload:
                msg = payload.decode("utf-8", errors="replace")
                base["data"]["message"] = msg
            return base

        elif response_byte == RESP_SIGNAL_SENDING_ERROR:
            base["type"] = "SignalSendingError"
            if payload:
                msg = payload.decode("utf-8", errors="replace")
                base["data"]["message"] = msg
            return base

        elif response_byte == RESP_SIGNAL_MONITOR:
            base["type"] = "SignalMonitor"
            if len(payload) >= 6:
                freq = struct.unpack("<I", payload[:4])[0]
                rssi = struct.unpack("b", payload[4:5])[0]
                protocol = payload[5]
                bit = payload[6] if len(payload) > 6 else 0
                key_len = payload[7] if len(payload) > 7 else 0
                key = payload[8 : 8 + key_len].decode("utf-8", errors="replace") if key_len else ""
                base["data"] = {
                    "frequency": freq,
                    "rssi": rssi,
                    "protocol": protocol,
                    "bit": bit,
                    "key": key,
                }
            return base

        elif response_byte == RESP_FILE_LIST:
            base["type"] = "FileList"
            text = payload.decode("utf-8", errors="replace") if payload else ""
            files = [f.strip() for f in text.split("\n") if f.strip()]
            base["data"]["files"] = files
            return base

        elif response_byte == RESP_FILE_CONTENT:
            base["type"] = "FileContent"
            if len(payload) >= 2:
                chunk_num = payload[0]
                total_chunks = payload[1]
                content = payload[2:]
                base["data"] = {
                    "chunk_num": chunk_num,
                    "total_chunks": total_chunks,
                    "content": content,
                }
            return base

        elif response_byte == RESP_FILE_ACTION:
            base["type"] = "FileAction"
            text = payload.decode("utf-8", errors="replace") if payload else ""
            parts = text.split(":", 1)
            base["data"]["action"] = parts[0] if parts else ""
            if len(parts) > 1:
                base["data"]["message"] = parts[1]
            return base

        elif response_byte == RESP_VERSION_INFO:
            base["type"] = "VersionInfo"
            if len(payload) >= 3:
                base["data"]["major"] = payload[0]
                base["data"]["minor"] = payload[1]
                base["data"]["patch"] = payload[2]
            return base

        elif response_byte == RESP_HA_CONFIG_SYNC:
            base["type"] = "HaConfigSync"
            if len(payload) >= 2:
                uuid_len = struct.unpack("<H", payload[:2])[0]
                uuid_str = payload[2 : 2 + uuid_len].decode("utf-8", errors="replace")
                base["data"]["device_id"] = uuid_str
            return base

        elif response_byte == RESP_HA_SETTINGS_WRITE_SD_ACK:
            base["type"] = "HaSettingsWriteSdAck"
            if payload:
                key = payload.decode("utf-8", errors="replace")
                base["data"]["key"] = key
            return base

        elif response_byte == RESP_SMART_CONFIG_STATUS:
            base["type"] = "SmartConfigStatus"
            if payload:
                status = payload.decode("utf-8", errors="replace")
                base["data"]["status"] = status
            return base

        elif response_byte == RESP_DEVICE_NAME:
            base["type"] = "DeviceName"
            if payload:
                name = payload.decode("utf-8", errors="replace")
                base["data"]["name"] = name
            return base

        elif response_byte == RESP_SETTINGS_SYNC:
            base["type"] = "SettingsSync"
            base["data"]["raw"] = payload
            return base

        else:
            base["type"] = f"Unknown(0x{response_byte:02X})"
            base["data"]["raw"] = frame.data
            return base
