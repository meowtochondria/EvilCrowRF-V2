"""Tests for the Flipper Sub file format parser/serializer.

Validates the round-trip guarantee: parse -> serialize -> parse produces
identical output. Tests cover optional fields, comments, extra lines,
and edge cases.
"""

from __future__ import annotations

from custom_components.evilcrow_rf.flipper_sub import FlipperSubFile


class TestFlipperSubRoundTrip:
    """Round-trip: parse -> serialize -> parse, verify identical output."""

    def test_round_trip_simple(self, sample_flipper_sub_files: dict[str, bytes]) -> None:
        """A simple .sub file round-trips byte-for-byte."""
        raw = sample_flipper_sub_files["simple.sub"]
        sub = FlipperSubFile.parse(raw, path="/ext/subghz/simple.sub")
        serialized = sub.serialize()
        assert serialized == raw

    def test_round_trip_with_comments(self, sample_flipper_sub_files: dict[str, bytes]) -> None:
        """A .sub file with comments round-trips identically."""
        raw = sample_flipper_sub_files["with_comments.sub"]
        sub = FlipperSubFile.parse(raw, path="/ext/subghz/with_comments.sub")
        serialized = sub.serialize()
        assert serialized == raw

    def test_round_trip_with_latency(self, sample_flipper_sub_files: dict[str, bytes]) -> None:
        """A .sub file with optional Latency field round-trips."""
        raw = sample_flipper_sub_files["with_latency.sub"]
        sub = FlipperSubFile.parse(raw, path="/ext/subghz/with_latency.sub")
        serialized = sub.serialize()
        assert serialized == raw

    def test_parse_then_parse_again_identical(
        self, sample_flipper_sub_files: dict[str, bytes]
    ) -> None:
        """Round-trip consistency: parse -> serialize -> parse -> serialize."""
        raw = sample_flipper_sub_files["simple.sub"]
        sub1 = FlipperSubFile.parse(raw)
        serialized1 = sub1.serialize()

        sub2 = FlipperSubFile.parse(serialized1)
        serialized2 = sub2.serialize()

        assert serialized1 == serialized2
        # Also verify the parsed fields match
        assert sub1.frequency == sub2.frequency
        assert sub1.protocol == sub2.protocol
        assert sub1.key == sub2.key
        assert sub1.te == sub2.te
        assert sub1.repeat == sub2.repeat
        assert sub1.preset == sub2.preset


class TestFlipperSubParsing:
    """Field-level parsing correctness."""

    def test_parse_simple_fields(self, sample_flipper_sub_files: dict[str, bytes]) -> None:
        raw = sample_flipper_sub_files["simple.sub"]
        sub = FlipperSubFile.parse(raw)
        assert sub.filetype == "Flipper SubGhz Key File"
        assert sub.version == 1
        assert sub.frequency == 433920000
        assert sub.preset == "FuriHalSubGhzPresetOok650Async"
        assert sub.protocol == 1
        assert sub.bit == 24
        assert sub.key == "00 A1 B2 C3"
        assert sub.te == 400
        assert sub.repeat == 3
        assert sub.latency == 0  # default

    def test_frequency_mhz(self, sample_flipper_sub_files: dict[str, bytes]) -> None:
        raw = sample_flipper_sub_files["simple.sub"]
        sub = FlipperSubFile.parse(raw)
        # 433920000 Hz -> 433.92 MHz
        assert sub.frequency_mhz == 433.92

    def test_parse_latency_field(self, sample_flipper_sub_files: dict[str, bytes]) -> None:
        raw = sample_flipper_sub_files["with_latency.sub"]
        sub = FlipperSubFile.parse(raw)
        assert sub.latency == 1000

    def test_parse_comment_lines_preserved(
        self, sample_flipper_sub_files: dict[str, bytes]
    ) -> None:
        raw = sample_flipper_sub_files["with_comments.sub"]
        sub = FlipperSubFile.parse(raw)
        # Comments should be preserved in _lines
        comment_lines = [line for line in sub._lines if line.strip().startswith("#")]
        assert len(comment_lines) >= 2

    def test_parse_blank_lines_preserved(self) -> None:
        """Blank lines in the file are preserved."""
        raw = b"Filetype: Flipper SubGhz Key File\nVersion: 1\n\nFrequency: 433920000\n"
        sub = FlipperSubFile.parse(raw)
        assert any(line.strip() == "" for line in sub._lines)

    def test_unrecognized_key_preserved(self) -> None:
        """Unknown key/value pairs are preserved."""
        raw = (
            b"Filetype: Flipper SubGhz Key File\n"
            b"Version: 1\n"
            b"CustomField: some_value\n"
            b"Frequency: 433920000\n"
        )
        sub = FlipperSubFile.parse(raw)
        custom_lines = [line for line in sub._lines if "CustomField" in line]
        assert len(custom_lines) == 1
        assert "some_value" in custom_lines[0]


class TestFlipperSubSerialization:
    """Serialization edge cases."""

    def test_serialize_without_path(self) -> None:
        """Serialization works even without a path set."""
        sub = FlipperSubFile(
            frequency=433920000,
            preset="FuriHalSubGhzPresetOok650Async",
            protocol=2,
            bit=12,
            key="AB CD",
            te=200,
            repeat=3,
        )
        data = sub.serialize()
        assert b"Frequency: 433920000" in data
        assert b"Protocol: 2" in data
        assert b"Key: AB CD" in data

    def test_serialize_includes_latency_when_set(self) -> None:
        """Latency is only emitted when non-zero."""
        sub = FlipperSubFile(
            frequency=433920000,
            preset="FuriHalSubGhzPresetOok650Async",
            key="AA",
            te=400,
            repeat=1,
            latency=500,
        )
        data = sub.serialize()
        assert b"Latency: 500" in data

    def test_serialize_omits_zero_latency(self) -> None:
        """Zero latency should not appear in the serialized output."""
        sub = FlipperSubFile(
            frequency=433920000,
            preset="FuriHalSubGhzPresetOok650Async",
            key="BB",
            te=400,
            repeat=1,
            latency=0,
        )
        data = sub.serialize()
        assert b"Latency:" not in data

    def test_to_entity_attributes(self) -> None:
        """to_entity_attributes returns expected fields."""
        sub = FlipperSubFile(
            frequency=433920000,
            preset="FuriHalSubGhzPresetOok650Async",
            protocol=1,
            bit=24,
            key="00 A1 B2 C3",
            te=400,
            repeat=3,
            path="/ext/subghz/test.sub",
        )
        attrs = sub.to_entity_attributes()
        assert attrs["frequency"] == 433920000
        assert attrs["frequency_mhz"] == 433.92
        assert attrs["protocol"] == 1
        assert attrs["bit"] == 24
        assert attrs["key"] == "00 A1 B2 C3"
        assert attrs["te"] == 400
        assert attrs["repeat"] == 3
        assert attrs["signal_file"] == "/ext/subghz/test.sub"


class TestFlipperSubErrors:
    """Edge cases and error handling."""

    def test_empty_data(self) -> None:
        """Parsing empty data returns a default FlipperSubFile."""
        sub = FlipperSubFile.parse(b"")
        assert sub.filetype == "Flipper SubGhz Key File"
        assert sub.frequency == 0

    def test_non_utf8_data(self) -> None:
        """Data with invalid UTF-8 bytes uses replace mode."""
        raw = b"Filetype: Flipper SubGhz Key File\n\xff\xfe\n"
        sub = FlipperSubFile.parse(raw)
        # Should not crash; invalid bytes are replaced
        assert sub.filetype == "Flipper SubGhz Key File"

    def test_invalid_int_fields_fallback_default(self) -> None:
        """Non-numeric values for int fields are silently ignored."""
        raw = (
            b"Filetype: Flipper SubGhz Key File\n"
            b"Version: abc\n"
            b"Frequency: not_a_number\n"
            b"Protocol: 1\n"
        )
        sub = FlipperSubFile.parse(raw)
        # Integer fields that fail to parse stay at their defaults
        assert sub.version == 1  # default
        assert sub.frequency == 0  # default (never set)
        assert sub.protocol == 1  # parsed successfully

    def test_extra_lines_serialized_after_known(self) -> None:
        """Preserved extra lines appear after known fields in serialized output."""
        raw = (
            b"Filetype: Flipper SubGhz Key File\n"
            b"Version: 1\n"
            b"Frequency: 433920000\n"
            b"# A comment\n"
            b"SomeRandomKey: value\n"
        )
        sub = FlipperSubFile.parse(raw)
        serialized = sub.serialize().decode("utf-8")
        lines = serialized.splitlines()
        # Known fields come first
        assert lines[0].startswith("Filetype:")
        assert lines[1].startswith("Version:")
        assert lines[2].startswith("Frequency:")
        # Extra lines (comment + unknown key) come after
        extra_idx = next(i for i, line in enumerate(lines) if line.strip().startswith("#"))
        assert extra_idx > 2
