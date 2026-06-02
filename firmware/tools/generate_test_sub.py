#!/usr/bin/env python3
"""
Generate test .sub files for EvilCrow-RF-V2 ProtoPirate decoder testing.

Creates Flipper-compatible .sub files with known signal patterns that
can be used to validate the firmware's StreamingSubFileParser and
ProtoPirate protocol decoders.

Each test file is designed to match EXACTLY what the corresponding
firmware decoder expects (timing, bit count, preamble structure).

Output files are placed in tools/test_data/

Protocols tested:
  1. KiaV0  — PWM, 61-bit, CRC8 poly 0x7F (te=250/500µs)
  2. Subaru — PWM, 64-bit (te=800/1600µs)
  3. Scher-Khan — PWM, 51-bit Dynamic (te=750/1100µs)
"""

import os

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "test_data")


# ============================================================================
# Helpers
# ============================================================================

def pulses_to_raw_data_lines(pulses: list, max_per_line: int = 512) -> list:
    """Convert pulse list to RAW_Data lines for .sub file."""
    lines = []
    current = []
    for p in pulses:
        current.append(str(p))
        if len(current) >= max_per_line:
            lines.append("RAW_Data: " + " ".join(current))
            current = []
    if current:
        lines.append("RAW_Data: " + " ".join(current))
    return lines


def write_sub_file(filepath: str, frequency: int, preset: str,
                   protocol: str, pulses: list, repeats: int = 3):
    """Write a Flipper-compatible .sub file."""
    all_pulses = []
    for _ in range(repeats):
        all_pulses.extend(pulses)

    raw_lines = pulses_to_raw_data_lines(all_pulses)

    with open(filepath, "w", newline="\n") as f:
        f.write("Filetype: Flipper SubGhz RAW File\n")
        f.write("Version: 1\n")
        f.write(f"Frequency: {frequency}\n")
        f.write(f"Preset: {preset}\n")
        f.write(f"Protocol: {protocol}\n")
        for line in raw_lines:
            f.write(line + "\n")

    total_samples = len(all_pulses)
    print(f"  Written: {filepath}")
    print(f"  Samples: {total_samples} ({repeats} repeats of {len(pulses)})")


# ============================================================================
# KIA V0 — PWM, 61 bits, CRC8 poly 0x7F
# ============================================================================

def kia_v0_crc8(data: int, start_bit: int, end_bit: int) -> int:
    """CRC8 with polynomial 0x7F (matches PPKiaV0 firmware)."""
    crc = 0
    for i in range(start_bit, end_bit - 1, -1):
        bit = (data >> i) & 1
        if ((crc >> 7) ^ bit) & 1:
            crc = ((crc << 1) ^ 0x7F) & 0xFF
        else:
            crc = (crc << 1) & 0xFF
    return crc


def generate_kia_v0_pulses(counter: int, serial: int, button: int) -> list:
    """Generate KiaV0 PWM-encoded pulse durations.

    Decoder: PPKiaV0 (te_short=250, te_long=500, te_delta=100, min_count_bit=61)
    Structure:
      - Preamble: 32 x (+250 -250)
      - Sync: +500 -500
      - Data: 61 bits PWM MSB first (bit 60 down to 0)
        short HIGH (250) = bit 0, long HIGH (500) = bit 1
        always followed by short LOW (-250)
      - End gap: -2000

    Bit layout (61 bits):
      [60..56] reserved (0)
      [55..40] counter (16 bits)
      [39..12] serial (28 bits)
      [11..8]  button (4 bits)
      [7..0]   CRC8 (poly 0x7F, computed over bits 55..8)
    """
    TE_SHORT = 250
    TE_LONG = 500

    # Build 61-bit data word
    data = ((counter & 0xFFFF) << 40) | \
           ((serial & 0x0FFFFFFF) << 12) | \
           ((button & 0x0F) << 8)

    # CRC8 over bits 55..8
    crc = kia_v0_crc8(data, 55, 8)
    data |= crc

    print(f"  KiaV0 data word: 0x{data:016X} ({bin(data)})")
    print(f"  counter={counter}, serial=0x{serial:07X}, button={button}, crc=0x{crc:02X}")

    # Verify extraction matches firmware
    assert (data >> 40) & 0xFFFF == counter
    assert (data >> 12) & 0x0FFFFFFF == serial
    assert (data >> 8) & 0x0F == button
    assert data & 0xFF == crc

    pulses = []

    # Preamble: 32 short pairs
    for _ in range(32):
        pulses.append(TE_SHORT)
        pulses.append(-TE_SHORT)

    # Sync: long HIGH + long LOW
    pulses.append(TE_LONG)
    pulses.append(-TE_LONG)

    # Data bits: 61 bits MSB first (bit 60 down to 0)
    for bit_pos in range(60, -1, -1):
        if (data >> bit_pos) & 1:
            pulses.append(TE_LONG)      # 1 = long HIGH
        else:
            pulses.append(TE_SHORT)     # 0 = short HIGH
        pulses.append(-TE_SHORT)        # separator LOW

    # End gap (triggers decoder: LOW > te_long*3 = 1500)
    pulses.append(-2000)

    print(f"  Pulse count: {len(pulses)} (preamble=64, sync=2, data=122, gap=1)")
    return pulses


# ============================================================================
# SUBARU — PWM, 64 bits (te_short=800, te_long=1600)
# ============================================================================

def generate_subaru_pulses(serial_bytes: bytes, button: int, counter_lo: int) -> list:
    """Generate Subaru PWM-encoded pulse durations.

    Decoder: PPSubaru (te_short=800, te_long=1600, te_delta=200, min_count_bit=64)
    Structure:
      - Preamble: 80 x (+1600) with -1600 between, last LOW = -4000 (sync gap)
      - Data: 64 bits PWM MSB first
        short HIGH (800) = bit 1, long HIGH (1600) = bit 0
        always followed by short LOW (-800)
      - End: +800 -4000 (triggers processData via LOW > 3000)

    Data layout (64 bits = 8 bytes):
      byte[0..2] = serial (24 bits)
      byte[3..4] = counter related
      byte[5]    = button in high nibble
      byte[6..7] = more counter bits
    """
    TE_SHORT = 800
    TE_LONG = 1600

    # Build 8 key bytes
    key_bytes = bytearray(8)
    key_bytes[0] = serial_bytes[0] & 0xFF
    key_bytes[1] = serial_bytes[1] & 0xFF
    key_bytes[2] = serial_bytes[2] & 0xFF
    key_bytes[3] = 0x12  # Counter-related
    key_bytes[4] = (counter_lo & 0x0F) << 4  # lo nibble in high nibble of byte 4
    key_bytes[5] = (button & 0x0F) << 4       # Button in high nibble
    key_bytes[6] = 0x56
    key_bytes[7] = counter_lo & 0x0F          # lo nibble to low nibble of byte 7

    # Convert to 64-bit data word (MSB first)
    data = 0
    for b in key_bytes:
        data = (data << 8) | b

    print(f"  Subaru data word: 0x{data:016X}")
    print(f"  serial=0x{serial_bytes[0]:02X}{serial_bytes[1]:02X}{serial_bytes[2]:02X}, "
          f"button={button}, counter_lo=0x{counter_lo:02X}")
    print(f"  key_bytes: {' '.join(f'{b:02X}' for b in key_bytes)}")

    pulses = []

    # Preamble: 80 long HIGH/LOW pairs, last LOW = sync gap (>2500µs)
    for i in range(80):
        pulses.append(TE_LONG)
        if i < 79:
            pulses.append(-TE_LONG)
        else:
            pulses.append(-4000)  # Sync gap

    # Data bits: 64 bits MSB first
    for bit_pos in range(63, -1, -1):
        if (data >> bit_pos) & 1:
            pulses.append(TE_SHORT)     # short HIGH = 1
        else:
            pulses.append(TE_LONG)      # long HIGH = 0
        pulses.append(-TE_SHORT)        # separator LOW

    # End: short HIGH + long LOW gap (triggers processData)
    pulses.append(TE_SHORT)
    pulses.append(-4000)

    print(f"  Pulse count: {len(pulses)} (preamble=160, data=128, end=2)")
    return pulses


# ============================================================================
# SCHER-KHAN — PWM, 51-bit Dynamic (te_short=750, te_long=1100)
# ============================================================================

def generate_scher_khan_pulses(data_50bits: int) -> list:
    """Generate Scher-Khan 51-bit Dynamic PWM-encoded pulse durations.

    Decoder: PPScherKhan (te_short=750, te_long=1100, te_delta=160, min_count_bit=35)
    Structure:
      - Preamble: 3 header pairs (+1500 -750)
      - Start bit: +750 -750 (sets decodeCountBit_=1)
      - Data: 50 bits PWM
        short pair (+750 -750) = bit 0
        long pair (+1100 -1100) = bit 1
      - Stop bit: +2000 (HIGH >= te_delta*2 + te_long = 1420)
      - End gap: -3000

    Data (50 bits, fed into 51-bit decodeCountBit_ = 1 start + 50 data):
      For case 51 (Dynamic):
        serial extracted from upper bits, button from bits 27..24, counter from bits 15..0
    """
    TE_SHORT = 750
    TE_LONG = 1100
    TE_HEADER = 1500  # te_short * 2

    print(f"  Scher-Khan data (50 bits): 0x{data_50bits:013X}")

    # Extract fields (mirrors firmware extractData for case 51)
    serial_raw = ((data_50bits >> 24) & 0xFFFFFF0) | ((data_50bits >> 20) & 0x0F)
    btn = (data_50bits >> 24) & 0x0F
    cnt = data_50bits & 0xFFFF
    print(f"  serial=0x{serial_raw:08X}, button={btn}, counter=0x{cnt:04X}")

    pulses = []

    # Preamble: 3 header pairs (double-short HIGH + short LOW)
    for _ in range(3):
        pulses.append(TE_HEADER)    # 1500µs HIGH
        pulses.append(-TE_SHORT)    # 750µs LOW

    # Start bit (short HIGH + short LOW)
    pulses.append(TE_SHORT)         # 750µs HIGH
    pulses.append(-TE_SHORT)        # 750µs LOW

    # Data: 50 bits MSB first
    for bit_pos in range(49, -1, -1):
        if (data_50bits >> bit_pos) & 1:
            pulses.append(TE_LONG)      # 1100µs HIGH = 1
            pulses.append(-TE_LONG)     # 1100µs LOW = 1
        else:
            pulses.append(TE_SHORT)     # 750µs HIGH = 0
            pulses.append(-TE_SHORT)    # 750µs LOW = 0

    # Stop bit: long HIGH (>= 1420µs) triggers extractData
    pulses.append(2000)
    # End gap
    pulses.append(-3000)

    print(f"  Pulse count: {len(pulses)} (header=6, start=2, data=100, stop+gap=2)")
    return pulses


# ============================================================================
# Main
# ============================================================================

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # ── Test 1: KiaV0 key fob signal (61-bit PWM + CRC8) ─────────
    print("\n=== Test 1: KiaV0 (PWM, 61-bit, CRC8) ===")
    kia_pulses = generate_kia_v0_pulses(
        counter=1,
        serial=0x0ABCDEF,
        button=3
    )
    write_sub_file(
        os.path.join(OUTPUT_DIR, "test_kia_v0.sub"),
        frequency=433920000,
        preset="FuriHalSubGhzPresetOok270Async",
        protocol="RAW",
        pulses=kia_pulses,
        repeats=3
    )

    # ── Test 2: Subaru key fob signal (64-bit PWM) ────────────────
    print("\n=== Test 2: Subaru (PWM, 64-bit) ===")
    subaru_pulses = generate_subaru_pulses(
        serial_bytes=bytes([0xAB, 0xCD, 0xEF]),
        button=2,   # Unlock
        counter_lo=0x05
    )
    write_sub_file(
        os.path.join(OUTPUT_DIR, "test_subaru.sub"),
        frequency=433920000,
        preset="FuriHalSubGhzPresetOok650Async",
        protocol="RAW",
        pulses=subaru_pulses,
        repeats=3
    )

    # ── Test 3: Scher-Khan Dynamic (51-bit PWM) ──────────────────
    print("\n=== Test 3: Scher-Khan Dynamic (PWM, 51-bit) ===")
    # Build a 50-bit test data word
    # Layout for case 51: serial from upper bits, btn at bits 27..24, cnt at bits 15..0
    sk_data = (0x5 << 24) | (0xABCD << 8) | 0x1234  # btn=5, some serial data, counter=0x1234
    # Ensure only 50 bits used
    sk_data = sk_data & ((1 << 50) - 1)
    scher_khan_pulses = generate_scher_khan_pulses(sk_data)
    write_sub_file(
        os.path.join(OUTPUT_DIR, "test_scher_khan.sub"),
        frequency=433920000,
        preset="FuriHalSubGhzPresetOok650Async",
        protocol="RAW",
        pulses=scher_khan_pulses,
        repeats=3
    )

    print("\n=== All test .sub files generated ===")
    print(f"Output directory: {OUTPUT_DIR}")
    print("\nExpected firmware decode results:")
    print("  test_kia_v0.sub    → PPKiaV0: serial=0x0ABCDEF, button=3, counter=1, CRC valid")
    print("  test_subaru.sub    → PPSubaru: serial=0xABCDEF, button=2")
    print("  test_scher_khan.sub→ PPScherKhan: 51-bit Dynamic, button=5, counter=0x1234")


if __name__ == "__main__":
    main()
