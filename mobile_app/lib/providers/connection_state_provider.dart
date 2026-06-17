import 'package:flutter/foundation.dart';
import 'ble_provider.dart';
import 'wifi_provider.dart';

/// Lightweight ChangeNotifier that tracks whether *any* transport is connected.
///
/// Watches both [BleProvider] and [WifiProvider] via [addListener] and exposes
/// a unified `isConnected`, `connectedTransport`, and the active transport's
/// device info.
///
/// **Transition note:** During Milestones 0-2 this references [BleProvider] and
/// [WifiProvider] directly. Once Milestone 1 creates [BleConnectionProvider]
/// and [WifiConnectionProvider], update the constructor. The public API
/// (`isConnected`, `connectedTransport`) stays the same.
class ConnectionStateProvider extends ChangeNotifier {
  final BleProvider _ble;
  final WifiProvider _wifi;

  ConnectionStateProvider(this._ble, this._wifi) {
    _ble.addListener(_onChange);
    _wifi.addListener(_onChange);
  }

  /// Returns `true` if either BLE or WiFi transport is connected.
  bool get isConnected => _ble.isConnected || _wifi.isConnected;

  /// Returns 'ble', 'wifi', or `null` if disconnected.
  String? get connectedTransport =>
      _ble.isConnected ? 'ble' : (_wifi.isConnected ? 'wifi' : null);

  /// Returns the display name from whichever transport is active.
  /// Falls back to empty string when disconnected.
  String get deviceName =>
      _ble.isConnected ? _ble.deviceName : _wifi.deviceName;

  void _onChange() {
    notifyListeners();
  }

  @override
  void dispose() {
    _ble.removeListener(_onChange);
    _wifi.removeListener(_onChange);
    super.dispose();
  }
}
