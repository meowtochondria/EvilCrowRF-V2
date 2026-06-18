import 'package:flutter/foundation.dart';
import '../connection/ble_connection_provider.dart';
import 'wifi_provider.dart';

/// Lightweight ChangeNotifier that tracks whether *any* transport is connected.
///
/// Watches [BleConnectionProvider] and [WifiProvider] via [addListener] and
/// exposes a unified `isConnected`, `connectedTransport`, and the active
/// transport's device info.
class ConnectionStateProvider extends ChangeNotifier {
  final BleConnectionProvider _bleConn;
  final WifiProvider _wifi;

  ConnectionStateProvider(this._bleConn, this._wifi) {
    _bleConn.addListener(_onChange);
    _wifi.addListener(_onChange);
  }

  /// Returns `true` if any BLE or WiFi transport is connected.
  bool get isConnected => _bleConn.isConnected || _wifi.isConnected;

  /// Returns 'ble', 'wifi', or `null` if disconnected.
  String? get connectedTransport =>
      _bleConn.isConnected ? 'ble' : (_wifi.isConnected ? 'wifi' : null);

  /// Returns the display name from whichever transport is active.
  /// Falls back to empty string when disconnected.
  String get deviceName =>
      _bleConn.isConnected ? _bleConn.deviceName : _wifi.deviceName;

  void _onChange() {
    notifyListeners();
  }

  @override
  void dispose() {
    _bleConn.removeListener(_onChange);
    _wifi.removeListener(_onChange);
    super.dispose();
  }
}
