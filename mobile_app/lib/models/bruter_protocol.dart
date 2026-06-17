/// Data model for a bruter protocol entry.
///
/// Extracted from `screens/brute_screen.dart` as part of Milestone 4 (M4)
/// of `docs/refactor.md`.
library;

import 'package:flutter/material.dart' show IconData, Icons;

class BruterProtocol {
  final int menuId;
  final String name;
  final String category;
  final double frequencyMhz;
  final int bits;
  final String encoding;
  final IconData icon;

  /// Timing element in microseconds (shortest pulse duration)
  final int te;

  /// Ratio of long pulse to short pulse (e.g. 3 means 1:3)
  final int ratio;

  const BruterProtocol({
    required this.menuId,
    required this.name,
    required this.category,
    required this.frequencyMhz,
    required this.bits,
    required this.encoding,
    required this.icon,
    this.te = 300,
    this.ratio = 3,
  });

  /// Whether this protocol uses De Bruijn mode (menu 35-40)
  bool get isDeBruijn => menuId >= 35 && menuId <= 40;

  /// Whether this protocol is compatible with De Bruijn attack.
  /// Requires binary encoding and n <= 16 bits.
  bool get deBruijnCompatible => encoding == 'binary' && bits <= 16;

  /// Estimated time for full keyspace brute force
  /// Formula: keyspace * (delay_ms * repetitions + singleCodeTime_ms) / 1000
  /// Default: delay=10ms, repetitions=4, singleCodeTime≈2ms per repetition
  String estimatedTimeWithDelay(int delayMs) {
    // De Bruijn protocols are ~90x faster
    if (isDeBruijn) {
      return _estimatedTimeDeBruijn();
    }
    final keyspace = encoding.contains('tristate') ? _pow3(bits) : (1 << bits);
    // Each code: repetitions * (inter_frame_delay + ~2ms RF transmission time)
    const int repetitions = 4;
    const double singleTxMs =
        2.0; // Approximate RF transmission time per repetition
    double totalPerCodeMs = repetitions * (delayMs + singleTxMs);
    double totalSeconds = keyspace * totalPerCodeMs / 1000.0;

    if (totalSeconds < 60) return '< 1 min';
    if (totalSeconds < 3600) return '~${(totalSeconds / 60).round()} min';
    if (totalSeconds < 86400) return '~${(totalSeconds / 3600).round()} hrs';
    return '~${(totalSeconds / 86400).round()} days';
  }

  /// Estimated time for De Bruijn attack (vastly faster)
  String _estimatedTimeDeBruijn() {
    if (menuId == 40) return '~3 min'; // Universal sweep: 96 configs × ~2s
    // B(2,n) sequence = n + 2^n - 1 bits, ~300µs per bit, 3-5 repeats
    final seqLen = bits + (1 << bits) - 1;
    const double usPerBit = 300.0; // Approximate OOK bit time
    const int repeats = 5;
    double totalSec = seqLen * usPerBit * repeats / 1e6;
    if (totalSec < 60) return '~${totalSec.round()} sec';
    return '~${(totalSec / 60).round()} min';
  }

  /// Legacy estimatedTime getter (uses default 10ms delay)
  String get estimatedTime => estimatedTimeWithDelay(10);

  int _pow3(int n) {
    int result = 1;
    for (int i = 0; i < n; i++) {
      result *= 3;
    }
    return result;
  }

  String get frequencyLabel {
    if (frequencyMhz == 433.92) return '433.92 MHz';
    if (frequencyMhz == 433.42) return '433.42 MHz';
    if (frequencyMhz == 868.35) return '868.35 MHz';
    if (frequencyMhz == 315.0) return '315 MHz';
    if (frequencyMhz == 318.0) return '318 MHz';
    if (frequencyMhz == 300.0) return '300 MHz';
    return '${frequencyMhz.toStringAsFixed(2)} MHz';
  }
}

/// All supported bruter protocols
const List<BruterProtocol> bruterProtocols = [
  // EU Garage Remotes
  BruterProtocol(
      menuId: 1,
      name: 'CAME',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 320,
      ratio: 2),
  BruterProtocol(
      menuId: 2,
      name: 'Princeton',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'tristate',
      icon: Icons.garage,
      te: 350,
      ratio: 3),
  BruterProtocol(
      menuId: 3,
      name: 'NiceFlo',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 700,
      ratio: 2),
  BruterProtocol(
      menuId: 6,
      name: 'Holtek',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 430,
      ratio: 2),
  BruterProtocol(
      menuId: 8,
      name: 'Ansonic',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 555,
      ratio: 2),
  BruterProtocol(
      menuId: 11,
      name: 'FAAC',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 400,
      ratio: 3),
  BruterProtocol(
      menuId: 12,
      name: 'BFT',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 400,
      ratio: 2),
  BruterProtocol(
      menuId: 13,
      name: 'SMC5326',
      category: 'EU Garage',
      frequencyMhz: 433.42,
      bits: 12,
      encoding: 'tristate',
      icon: Icons.garage,
      te: 320,
      ratio: 3),
  BruterProtocol(
      menuId: 14,
      name: 'Clemsa',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 400,
      ratio: 2),
  BruterProtocol(
      menuId: 15,
      name: 'GateTX',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 350,
      ratio: 2),
  BruterProtocol(
      menuId: 16,
      name: 'Phox',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 400,
      ratio: 2),
  BruterProtocol(
      menuId: 17,
      name: 'Phoenix V2',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 500,
      ratio: 2),
  BruterProtocol(
      menuId: 18,
      name: 'Prastel',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 400,
      ratio: 2),
  BruterProtocol(
      menuId: 19,
      name: 'Doitrand',
      category: 'EU Garage',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.garage,
      te: 400,
      ratio: 2),

  // US Garage Remotes
  BruterProtocol(
      menuId: 4,
      name: 'Chamberlain',
      category: 'US Garage',
      frequencyMhz: 315.0,
      bits: 12,
      encoding: 'binary',
      icon: Icons.door_sliding,
      te: 430,
      ratio: 2),
  BruterProtocol(
      menuId: 5,
      name: 'Linear',
      category: 'US Garage',
      frequencyMhz: 300.0,
      bits: 10,
      encoding: 'binary',
      icon: Icons.door_sliding,
      te: 500,
      ratio: 3),
  BruterProtocol(
      menuId: 7,
      name: 'LiftMaster',
      category: 'US Garage',
      frequencyMhz: 315.0,
      bits: 12,
      encoding: 'binary',
      icon: Icons.door_sliding,
      te: 400,
      ratio: 2),
  BruterProtocol(
      menuId: 23,
      name: 'Firefly',
      category: 'US Garage',
      frequencyMhz: 300.0,
      bits: 10,
      encoding: 'binary',
      icon: Icons.door_sliding,
      te: 400,
      ratio: 2),
  BruterProtocol(
      menuId: 24,
      name: 'Linear MegaCode',
      category: 'US Garage',
      frequencyMhz: 318.0,
      bits: 24,
      encoding: 'binary',
      icon: Icons.door_sliding,
      te: 500,
      ratio: 2),

  // Home Automation
  BruterProtocol(
      menuId: 20,
      name: 'Dooya',
      category: 'Home Auto',
      frequencyMhz: 433.92,
      bits: 24,
      encoding: 'binary',
      icon: Icons.blinds,
      te: 350,
      ratio: 2),
  BruterProtocol(
      menuId: 21,
      name: 'Nero',
      category: 'Home Auto',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.blinds,
      te: 450,
      ratio: 2),
  BruterProtocol(
      menuId: 22,
      name: 'Magellen',
      category: 'Home Auto',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.blinds,
      te: 400,
      ratio: 2),

  // Alarm / Sensors
  BruterProtocol(
      menuId: 9,
      name: 'EV1527',
      category: 'Alarm',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.security,
      te: 320,
      ratio: 3),
  BruterProtocol(
      menuId: 10,
      name: 'Honeywell',
      category: 'Alarm',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.security,
      te: 300,
      ratio: 2),
  BruterProtocol(
      menuId: 29,
      name: 'EV1527 24b',
      category: 'Alarm',
      frequencyMhz: 433.92,
      bits: 24,
      encoding: 'binary',
      icon: Icons.security,
      te: 320,
      ratio: 3),

  // 868 MHz
  BruterProtocol(
      menuId: 25,
      name: 'Hörmann',
      category: '868 MHz',
      frequencyMhz: 868.35,
      bits: 12,
      encoding: 'binary',
      icon: Icons.radio,
      te: 500,
      ratio: 2),
  BruterProtocol(
      menuId: 26,
      name: 'Marantec',
      category: '868 MHz',
      frequencyMhz: 868.35,
      bits: 12,
      encoding: 'binary',
      icon: Icons.radio,
      te: 600,
      ratio: 2),
  BruterProtocol(
      menuId: 27,
      name: 'Berner',
      category: '868 MHz',
      frequencyMhz: 868.35,
      bits: 12,
      encoding: 'binary',
      icon: Icons.radio,
      te: 400,
      ratio: 2),

  // Misc
  BruterProtocol(
      menuId: 28,
      name: 'Intertechno V3',
      category: 'Misc',
      frequencyMhz: 433.92,
      bits: 32,
      encoding: 'binary',
      icon: Icons.power,
      te: 250,
      ratio: 5),
  BruterProtocol(
      menuId: 30,
      name: 'StarLine',
      category: 'Misc',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.key,
      te: 500,
      ratio: 2),
  BruterProtocol(
      menuId: 31,
      name: 'Tedsen',
      category: 'Misc',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.key,
      te: 600,
      ratio: 2),
  BruterProtocol(
      menuId: 32,
      name: 'Airforce',
      category: 'Misc',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.key,
      te: 350,
      ratio: 3),
  BruterProtocol(
      menuId: 33,
      name: 'Unilarm',
      category: 'Misc',
      frequencyMhz: 433.42,
      bits: 12,
      encoding: 'binary',
      icon: Icons.key,
      te: 350,
      ratio: 3),
  BruterProtocol(
      menuId: 34,
      name: 'ELKA',
      category: 'Misc',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'binary',
      icon: Icons.key,
      te: 400,
      ratio: 2),

  // De Bruijn protocols (~90x faster for binary ≤16 bits)
  BruterProtocol(
      menuId: 35,
      name: 'DeBruijn Generic 433',
      category: 'De Bruijn',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'debruijn',
      icon: Icons.bolt,
      te: 300,
      ratio: 3),
  BruterProtocol(
      menuId: 36,
      name: 'DeBruijn Generic 315',
      category: 'De Bruijn',
      frequencyMhz: 315.0,
      bits: 12,
      encoding: 'debruijn',
      icon: Icons.bolt,
      te: 300,
      ratio: 3),
  BruterProtocol(
      menuId: 37,
      name: 'DeBruijn Holtek',
      category: 'De Bruijn',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'debruijn',
      icon: Icons.bolt,
      te: 430,
      ratio: 2),
  BruterProtocol(
      menuId: 38,
      name: 'DeBruijn Linear',
      category: 'De Bruijn',
      frequencyMhz: 300.0,
      bits: 10,
      encoding: 'debruijn',
      icon: Icons.bolt,
      te: 500,
      ratio: 3),
  BruterProtocol(
      menuId: 39,
      name: 'DeBruijn EV1527',
      category: 'De Bruijn',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'debruijn',
      icon: Icons.bolt,
      te: 320,
      ratio: 3),
  BruterProtocol(
      menuId: 40,
      name: 'Universal Sweep',
      category: 'De Bruijn',
      frequencyMhz: 433.92,
      bits: 12,
      encoding: 'debruijn',
      icon: Icons.radar,
      te: 300,
      ratio: 3),
];

/// Get unique category list preserving order.
List<String> getBruterCategories() {
  final seen = <String>{};
  final result = <String>[];
  for (final p in bruterProtocols) {
    if (seen.add(p.category)) {
      result.add(p.category);
    }
  }
  return result;
}
