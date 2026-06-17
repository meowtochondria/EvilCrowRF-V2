/// NRF24 target model for scanned wireless keyboard / mouse receivers.
///
/// Extracted from `nrf_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
class NrfTarget {
  final String type;
  final int channel;
  final List<int> address;

  NrfTarget({required this.type, required this.channel, required this.address});

  String get addressHex => address
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');

  /// Convert device type code from firmware to human-readable string.
  static String typeFromCode(int code) {
    switch (code) {
      case 1:
        return 'Microsoft';
      case 2:
        return 'MS Encrypted';
      case 3:
        return 'Logitech';
      default:
        return 'Unknown';
    }
  }
}
