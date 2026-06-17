import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's last successful connection so the app can prepopulate
/// the Quick Connect / Settings fields on the next launch.
///
/// Stores:
///   - `last_transport`   — 'ble' | 'wifi' (or null if never connected)
///   - `last_wifi_host`   — IP / FQDN the user last connected to over WiFi
///   - `last_ble_device_id` — BLE device id (e.g. mac address) the user last
///     connected to over BLE
///
/// F3 of `docs/refactor.md` — Persist Last Connection Method & Prepopulate Fields.
class ConnectionHistoryService {
  static const String _keyLastTransport = 'last_transport';
  static const String _keyWifiHost = 'last_wifi_host';
  static const String _keyBleDeviceId = 'last_ble_device_id';

  /// Save the last successful connection details. Pass `null` for fields that
  /// are not relevant to the current transport (e.g. `bleDeviceId` when
  /// connecting over WiFi).
  static Future<void> saveConnection({
    required String transport,
    String? wifiHost,
    String? bleDeviceId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyLastTransport, transport);
      if (wifiHost != null) {
        await prefs.setString(_keyWifiHost, wifiHost);
      }
      if (bleDeviceId != null) {
        await prefs.setString(_keyBleDeviceId, bleDeviceId);
      }
    } catch (_) {
      // Swallow errors — history persistence is best-effort.
    }
  }

  /// Returns the last transport ('ble' or 'wifi'), or null if never connected.
  static Future<String?> getLastTransport() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyLastTransport);
    } catch (_) {
      return null;
    }
  }

  /// Returns the last WiFi host (IP / FQDN / mDNS), or null if none saved.
  static Future<String?> getLastWifiHost() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyWifiHost);
    } catch (_) {
      return null;
    }
  }

  /// Returns the last BLE device id, or null if none saved.
  static Future<String?> getLastBleDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyBleDeviceId);
    } catch (_) {
      return null;
    }
  }

  /// Clear all saved connection history.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastTransport);
      await prefs.remove(_keyWifiHost);
      await prefs.remove(_keyBleDeviceId);
    } catch (_) {}
  }
}
