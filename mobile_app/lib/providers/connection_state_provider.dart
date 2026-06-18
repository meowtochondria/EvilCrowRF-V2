import 'package:flutter/foundation.dart';
import '../connection/ble_connection_provider.dart';
import 'ble_provider.dart';
import 'wifi_provider.dart';

/// Lightweight ChangeNotifier that tracks whether *any* transport is connected.
///
/// Watches [BleConnectionProvider], [BleProvider], and [WifiProvider] via
/// [addListener] and exposes a unified `isConnected`, `connectedTransport`,
/// and the active transport's device info.
///
/// **Transition note (M5):** [BleConnectionProvider] is the new BLE transport;
/// [BleProvider] is kept temporarily for consumers not yet migrated.
/// Once everything is on [BleConnectionProvider], drop the [BleProvider]
/// reference.
class ConnectionStateProvider extends ChangeNotifier {
  final BleConnectionProvider _bleConn;
  final BleProvider _ble;
  final WifiProvider _wifi;

  ConnectionStateProvider(this._bleConn, this._ble, this._wifi) {
    _bleConn.addListener(_onChange);
    _ble.addListener(_onChange);
    _wifi.addListener(_onChange);
  }

  /// Returns `true` if any BLE or WiFi transport is connected.
  bool get isConnected =>
      _bleConn.isConnected || _ble.isConnected || _wifi.isConnected;

  /// Returns 'ble', 'wifi', or `null` if disconnected.
  /// Prefers [BleConnectionProvider] for new BLE transport.
  String? get connectedTransport => _bleConn.isConnected
      ? 'ble'
      : (_ble.isConnected ? 'ble' : (_wifi.isConnected ? 'wifi' : null));

  /// Returns the display name from whichever transport is active.
  /// Falls back to empty string when disconnected.
  String get deviceName => _bleConn.isConnected
      ? _bleConn.deviceName
      : (_ble.isConnected ? _ble.deviceName : _wifi.deviceName);

  void _onChange() {
    notifyListeners();
  }

  @override
  void dispose() {
    _bleConn.removeListener(_onChange);
    _ble.removeListener(_onChange);
    _wifi.removeListener(_onChange);
    super.dispose();
  }
}
