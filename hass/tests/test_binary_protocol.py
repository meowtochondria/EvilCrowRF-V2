"""Tests for the EvilCrowRF V2 binary protocol.

Covers BinaryFrame encode/decode, XOR checksum validation, chunking,
command builders for all command types, and response parsing for all
response types.
"""

from __future__ import annotations

import struct

import pytest

from custom_components.evilcrow_rf.binary_protocol import (
    BinaryFrame,
    EvilCrowBinaryProtocol,
)
from custom_components.evilcrow_rf.const import (
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

# ---------------------------------------------------------------------------
# BinaryFrame encode / decode
# ---------------------------------------------------------------------------


class TestBinaryFrameEncodeDecode:
    """Frame-level encoding and decoding with XOR checksum validation."""

    def test_encode_basic(self) -> None:
        """A simple frame encodes to the expected byte layout."""
        frame = BinaryFrame(
            magic=BINARY_MAGIC,
            frame_type=FRAME_TYPE_DATA,
            chunk_id=1,
            chunk_num=1,
            total_chunks=1,
            data=b"hello",
        )
        raw = frame.encode()

        # Header (5 B) + len (2 B LE) + data (5 B) + checksum (1 B) = 13
        assert len(raw) == 13
        assert raw[0] == BINARY_MAGIC
        assert raw[1] == FRAME_TYPE_DATA
        assert raw[2] == 1  # chunk_id
        assert raw[3] == 1  # chunk_num
        assert raw[4] == 1  # total_chunks
        assert raw[5:7] == struct.pack("<H", 5)  # data length
        assert raw[7:12] == b"hello"

        # Verify XOR checksum (last byte)
        expected_cs = 0
        for b in raw[:-1]:
            expected_cs ^= b
        assert raw[-1] == expected_cs

    def test_encode_empty_data(self) -> None:
        """Frame with empty data still produces valid output."""
        frame = BinaryFrame(data=b"")
        raw = frame.encode()
        # 5 + 2 + 0 + 1 = 8 bytes
        assert len(raw) == 8
        assert raw[5:7] == struct.pack("<H", 0)

    def test_decode_roundtrip(self) -> None:
        """Encode then decode yields an identical BinaryFrame."""
        original = BinaryFrame(
            magic=BINARY_MAGIC,
            frame_type=FRAME_TYPE_DATA,
            chunk_id=42,
            chunk_num=2,
            total_chunks=5,
            data=b"\x01\x02\x03\x04",
        )
        raw = original.encode()
        decoded = BinaryFrame.decode(raw)
        assert decoded.magic == original.magic
        assert decoded.frame_type == original.frame_type
        assert decoded.chunk_id == original.chunk_id
        assert decoded.chunk_num == original.chunk_num
        assert decoded.total_chunks == original.total_chunks
        assert decoded.data == original.data

    def test_decode_too_short(self) -> None:
        """Frame shorter than 8 bytes raises ValueError."""
        with pytest.raises(ValueError, match="Frame too short"):
            BinaryFrame.decode(b"\xaa\x01\x02")

    def test_decode_incomplete_payload(self) -> None:
        """Frame length header says 10 but body is shorter -> ValueError."""
        # Build a frame with a deceptive data_len
        header = struct.pack("BBBBB", BINARY_MAGIC, 1, 1, 1, 1)
        len_field = struct.pack("<H", 10)  # claims 10 bytes of data
        partial = header + len_field + b"abc"
        cs = 0
        for b in partial:
            cs ^= b
        raw = partial + struct.pack("B", cs)
        with pytest.raises(ValueError, match="Frame payload incomplete"):
            BinaryFrame.decode(raw)

    def test_decode_checksum_mismatch(self) -> None:
        """Corrupted checksum raises ValueError."""
        frame = BinaryFrame(data=b"test")
        raw = frame.encode()
        # Flip a bit in the payload
        corrupted = bytearray(raw)
        corrupted[-1] ^= 0xFF  # corrupt checksum
        with pytest.raises(ValueError, match="Checksum mismatch"):
            BinaryFrame.decode(bytes(corrupted))

    def test_decode_binary_data_in_payload(self) -> None:
        """Binary payloads (null bytes, high bytes) round-trip correctly."""
        payload = bytes(range(256))
        frame = BinaryFrame(chunk_id=7, data=payload)
        raw = frame.encode()
        decoded = BinaryFrame.decode(raw)
        assert decoded.data == payload
        assert decoded.chunk_id == 7


# ---------------------------------------------------------------------------
# XOR checksum validation
# ---------------------------------------------------------------------------


class TestXorChecksum:
    """Standalone XOR checksum correctness."""

    def test_xor_checksum_correctness(self) -> None:
        """Manually computed XOR must match the frame's checksum byte."""
        frame = BinaryFrame(data=b"\x00\xff\xab\xcd")
        raw = frame.encode()
        # Compute XOR over everything except the checksum byte itself
        manual = 0
        for b in raw[:-1]:
            manual ^= b
        assert raw[-1] == manual

    def test_xor_checksum_empty_data(self) -> None:
        """Checksum for empty-data frame."""
        raw = BinaryFrame(data=b"").encode()
        manual = 0
        for b in raw[:-1]:
            manual ^= b
        assert raw[-1] == manual


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------


class TestChunking:
    """Command chunking when payload exceeds MAX_PAYLOAD_SIZE."""

    def test_single_frame_for_small_payload(self) -> None:
        """Small payloads produce exactly one frame, no chunking."""
        proto = EvilCrowBinaryProtocol()
        frames = proto.build_request_record_command(frequency=433920000, module=1)
        assert len(frames) == 1

    def test_multiple_frames_for_large_payload(self) -> None:
        """Large payloads are split across multiple chunks."""
        proto = EvilCrowBinaryProtocol()
        # Build a file list with a very long path to force chunking
        long_path = "/" + "a" * (MAX_PAYLOAD_SIZE * 2)
        frames = proto.build_file_list_command(path=long_path)
        assert len(frames) > 1

    def test_chunked_metadata_consistency(self) -> None:
        """All chunks share the same chunk_id and correct chunk numbering."""
        proto = EvilCrowBinaryProtocol()
        long_path = "/" + "b" * (MAX_PAYLOAD_SIZE * 3)
        frames = proto.build_file_list_command(path=long_path)
        assert len(frames) >= 2

        decoded_frames = [BinaryFrame.decode(f) for f in frames]
        chunk_id = decoded_frames[0].chunk_id
        total = decoded_frames[0].total_chunks
        assert total == len(frames)

        for i, df in enumerate(decoded_frames):
            assert df.chunk_id == chunk_id
            assert df.chunk_num == i + 1
            assert df.total_chunks == total

    def test_chunked_first_chunk_contains_command_byte(self) -> None:
        """The first chunk of a chunked command carries the command byte."""
        proto = EvilCrowBinaryProtocol()
        long_path = "/" + "c" * (MAX_PAYLOAD_SIZE * 2)
        frames = proto.build_file_list_command(path=long_path)
        first = BinaryFrame.decode(frames[0])
        assert first.data[0] == CMD_FILE_LIST

    def test_chunked_subsequent_chunks_no_command_byte(self) -> None:
        """Chunks after the first carry only continuation data."""
        proto = EvilCrowBinaryProtocol()
        long_path = "/" + "d" * (MAX_PAYLOAD_SIZE * 2)
        frames = proto.build_file_list_command(path=long_path)
        assert len(frames) > 1
        second = BinaryFrame.decode(frames[1])
        # No command byte prefix in continuation chunks
        assert second.data[0] != CMD_FILE_LIST


# ---------------------------------------------------------------------------
# Command builders — all command types
# ---------------------------------------------------------------------------


class TestCommandBuilders:
    """Every command builder produces well-formed frames."""

    def make_proto(self) -> EvilCrowBinaryProtocol:
        return EvilCrowBinaryProtocol()

    def assert_valid_frames(self, frames: list[bytes], expected_cmd: int) -> None:
        """Helper: verify all frames decode and first has the expected cmd."""
        assert len(frames) >= 1
        decoded = [BinaryFrame.decode(f) for f in frames]
        assert decoded[0].data[0] == expected_cmd
        # Sequential request IDs within a single command
        ids = {f.chunk_id for f in decoded}
        assert len(ids) == 1  # all same chunk_id

    def test_build_start_recording(self) -> None:
        proto = self.make_proto()
        frames = proto.build_request_record_command(frequency=433920000, module=1, preset=0)
        self.assert_valid_frames(frames, CMD_START_RECORDING)
        decoded = BinaryFrame.decode(frames[0])
        _, freq, mod, preset = struct.unpack_from("B<IBB", decoded.data, 0)
        assert freq == 433920000
        assert mod == 1
        assert preset == 0

    def test_build_stop_recording(self) -> None:
        proto = self.make_proto()
        frames = proto.build_stop_record_command()
        self.assert_valid_frames(frames, CMD_STOP_RECORDING)

    def test_build_idle(self) -> None:
        proto = self.make_proto()
        frames = proto.build_idle_command()
        self.assert_valid_frames(frames, CMD_IDLE)

    def test_build_send_signal(self) -> None:
        proto = self.make_proto()
        frames = proto.build_send_signal_command("/ext/subghz/test.sub")
        self.assert_valid_frames(frames, CMD_SEND_SIGNAL)
        decoded = BinaryFrame.decode(frames[0])
        # payload: cmd(1) + path_len(1) + path(N)
        path_len = decoded.data[1]
        path = decoded.data[2 : 2 + path_len].decode("utf-8")
        assert path == "/ext/subghz/test.sub"

    def test_build_file_list(self) -> None:
        proto = self.make_proto()
        frames = proto.build_file_list_command("/ext/subghz")
        self.assert_valid_frames(frames, CMD_FILE_LIST)

    def test_build_file_rename(self) -> None:
        proto = self.make_proto()
        frames = proto.build_file_rename_command("/ext/subghz/old.sub", "/ext/subghz/new.sub")
        self.assert_valid_frames(frames, CMD_FILE_RENAME)
        decoded = BinaryFrame.decode(frames[0])
        old_len = decoded.data[1]
        old_path = decoded.data[2 : 2 + old_len].decode("utf-8")
        rest = decoded.data[2 + old_len :]
        new_len = rest[0]
        new_path = rest[1 : 1 + new_len].decode("utf-8")
        assert old_path == "/ext/subghz/old.sub"
        assert new_path == "/ext/subghz/new.sub"

    def test_build_file_load(self) -> None:
        proto = self.make_proto()
        frames = proto.build_file_load_command("/ext/subghz/test.sub")
        self.assert_valid_frames(frames, CMD_FILE_LOAD)

    def test_build_scan(self) -> None:
        proto = self.make_proto()
        frames = proto.build_scan_command()
        self.assert_valid_frames(frames, CMD_SCAN)

    def test_build_start_monitor(self) -> None:
        proto = self.make_proto()
        frames = proto.build_start_monitor_command(
            module=0, frequency=433920000, rssi_threshold=-80
        )
        self.assert_valid_frames(frames, CMD_START_MONITOR)

    def test_build_stop_monitor(self) -> None:
        proto = self.make_proto()
        frames = proto.build_stop_monitor_command()
        self.assert_valid_frames(frames, CMD_STOP_MONITOR)

    def test_build_settings_update(self) -> None:
        proto = self.make_proto()
        frames = proto.build_settings_update_command(setting_key=1, setting_value=b"\x00\xff")
        self.assert_valid_frames(frames, CMD_SETTINGS_UPDATE)

    def test_build_smartconfig(self) -> None:
        proto = self.make_proto()
        frames = proto.build_smartconfig_command(ssid="MyWiFi", password="secret123")
        self.assert_valid_frames(frames, CMD_SMART_CONFIG)

    def test_build_smartconfig_with_channel(self) -> None:
        proto = self.make_proto()
        frames = proto.build_smartconfig_command(ssid="TestNet", password="pass456", channel=6)
        self.assert_valid_frames(frames, CMD_SMART_CONFIG)
        decoded = BinaryFrame.decode(frames[0])
        # Find channel byte at end: cmd(1)+ssid_len(1)+ssid(N)+pwd_len(1)+pwd(N)+channel(1)
        channel = decoded.data[-1]
        assert channel == 6

    def test_build_ha_config_sync(self) -> None:
        proto = self.make_proto()
        frames = proto.build_ha_config_sync_command()
        self.assert_valid_frames(frames, CMD_HA_CONFIG_SYNC)

    def test_request_id_monotonic(self) -> None:
        """Each command gets an incrementing request_id, wrapping at 255."""
        proto = EvilCrowBinaryProtocol()
        ids: list[int] = []
        for _ in range(260):
            frames = proto.build_idle_command()
            decoded = BinaryFrame.decode(frames[0])
            ids.append(decoded.chunk_id)

        # IDs should be 1..255 then wrap to 1 again
        assert ids[0] == 1
        assert ids[254] == 255
        assert ids[255] == 1
        # All within range
        assert all(1 <= i <= 255 for i in ids)


# ---------------------------------------------------------------------------
# Response parsing — all response types
# ---------------------------------------------------------------------------


class TestResponseParsing:
    """Parse every response type into the expected structured dict."""

    def _make_frame(self, payload: bytes, chunk_id: int = 1) -> BinaryFrame:
        """Build a BinaryFrame with the given response payload."""
        return BinaryFrame(
            magic=BINARY_MAGIC,
            frame_type=FRAME_TYPE_DATA,
            chunk_id=chunk_id,
            data=payload,
        )

    def test_signal_detected(self) -> None:
        frame = self._make_frame(struct.pack("Bb", RESP_SIGNAL_DETECTED, -75))
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalDetected"
        assert result["data"]["rssi"] == -75

    def test_signal_detected_no_payload(self) -> None:
        frame = self._make_frame(struct.pack("B", RESP_SIGNAL_DETECTED))
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalDetected"
        assert result["data"] == {}

    def test_signal_recorded(self) -> None:
        payload = struct.pack("B", RESP_SIGNAL_RECORDED) + b"capture.sub"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalRecorded"
        assert result["data"]["filename"] == "capture.sub"

    def test_signal_sent(self) -> None:
        payload = struct.pack("B", RESP_SIGNAL_SENT) + b"sent.sub"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalSent"
        assert result["data"]["filename"] == "sent.sub"

    def test_signal_error(self) -> None:
        payload = struct.pack("B", RESP_SIGNAL_ERROR) + b"Timeout"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalError"
        assert result["data"]["message"] == "Timeout"

    def test_signal_sending_error(self) -> None:
        payload = struct.pack("B", RESP_SIGNAL_SENDING_ERROR) + b"No carrier"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalSendingError"
        assert result["data"]["message"] == "No carrier"

    def test_signal_monitor_basic(self) -> None:
        # payload: response_byte + freq(uint32 LE) + rssi(int8) + protocol(uint8)
        payload = struct.pack("<BIbB", RESP_SIGNAL_MONITOR, 433920000, -60, 1)
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalMonitor"
        assert result["data"]["frequency"] == 433920000
        assert result["data"]["rssi"] == -60
        assert result["data"]["protocol"] == 1
        assert result["data"]["bit"] == 0
        assert result["data"]["key"] == ""

    def test_signal_monitor_with_key(self) -> None:
        # payload: resp(1)+freq(4)+rssi(1)+protocol(1)+bit(1)+keylen(1)+key(N)
        key_bytes = b"DEADBEEF"
        payload = (
            struct.pack("<BIbBBB", RESP_SIGNAL_MONITOR, 868350000, -45, 3, 16, len(key_bytes))
            + key_bytes
        )
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SignalMonitor"
        assert result["data"]["frequency"] == 868350000
        assert result["data"]["rssi"] == -45
        assert result["data"]["protocol"] == 3
        assert result["data"]["bit"] == 16
        assert result["data"]["key"] == "DEADBEEF"

    def test_file_list(self) -> None:
        payload = struct.pack("B", RESP_FILE_LIST) + b"file1.sub\nfile2.sub\nfile3.sub"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "FileList"
        assert result["data"]["files"] == ["file1.sub", "file2.sub", "file3.sub"]

    def test_file_list_empty(self) -> None:
        frame = self._make_frame(struct.pack("B", RESP_FILE_LIST))
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "FileList"
        assert result["data"]["files"] == []

    def test_file_content(self) -> None:
        # resp(1) + chunk_num(1) + total_chunks(1) + content(N)
        content = b"\x00\x01\x02\x03"
        payload = struct.pack("BBB", RESP_FILE_CONTENT, 1, 2) + content
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "FileContent"
        assert result["data"]["chunk_num"] == 1
        assert result["data"]["total_chunks"] == 2
        assert result["data"]["content"] == content

    def test_file_content_no_data(self) -> None:
        """FileContent with only the response byte -> no data fields."""
        frame = self._make_frame(struct.pack("B", RESP_FILE_CONTENT))
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "FileContent"
        assert result["data"] == {}

    def test_file_action(self) -> None:
        payload = struct.pack("B", RESP_FILE_ACTION) + b"rename:ok"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "FileAction"
        assert result["data"]["action"] == "rename"
        assert result["data"]["message"] == "ok"

    def test_file_action_no_message(self) -> None:
        payload = struct.pack("B", RESP_FILE_ACTION) + b"deleted"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "FileAction"
        assert result["data"]["action"] == "deleted"
        assert "message" not in result["data"]

    def test_version_info(self) -> None:
        payload = struct.pack("BBBB", RESP_VERSION_INFO, 3, 0, 1)
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "VersionInfo"
        assert result["data"]["major"] == 3
        assert result["data"]["minor"] == 0
        assert result["data"]["patch"] == 1

    def test_ha_config_sync(self) -> None:
        uuid_str = "550e8400-e29b-41d4-a716-446655440000"
        uuid_bytes = uuid_str.encode("utf-8")
        payload = (
            struct.pack("BB", RESP_HA_CONFIG_SYNC, len(uuid_bytes))
            + struct.pack("<H", len(uuid_bytes))
            + uuid_bytes
        )
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "HaConfigSync"
        assert result["data"]["device_id"] == uuid_str

    def test_ha_settings_write_sd_ack(self) -> None:
        payload = struct.pack("B", RESP_HA_SETTINGS_WRITE_SD_ACK) + b"test_key"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "HaSettingsWriteSdAck"
        assert result["data"]["key"] == "test_key"

    def test_smart_config_status(self) -> None:
        payload = struct.pack("B", RESP_SMART_CONFIG_STATUS) + b"done"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SmartConfigStatus"
        assert result["data"]["status"] == "done"

    def test_device_name(self) -> None:
        payload = struct.pack("B", RESP_DEVICE_NAME) + b"Test Device"
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "DeviceName"
        assert result["data"]["name"] == "Test Device"

    def test_settings_sync(self) -> None:
        raw_payload = b"\x01\x02\x03"
        payload = struct.pack("B", RESP_SETTINGS_SYNC) + raw_payload
        frame = self._make_frame(payload)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "SettingsSync"
        assert result["data"]["raw"] == raw_payload

    def test_unknown_response(self) -> None:
        frame = self._make_frame(struct.pack("B", 0xEE) + b"???")
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "Unknown(0xEE)"
        assert result["data"]["raw"] == struct.pack("B", 0xEE) + b"???"

    def test_empty_data_returns_unknown(self) -> None:
        frame = BinaryFrame(data=b"")
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["type"] == "unknown"
        assert result["data"] == {}

    def test_request_id_preserved(self) -> None:
        """The response dict includes the original chunk_id as request_id."""
        payload = struct.pack("BB", RESP_SIGNAL_DETECTED, -50)
        frame = self._make_frame(payload, chunk_id=127)
        result = EvilCrowBinaryProtocol.parse_response(frame)
        assert result["request_id"] == 127
