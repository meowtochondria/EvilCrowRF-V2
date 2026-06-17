import 'package:shared_preferences/shared_preferences.dart';

/// Persistent device preferences backed by SharedPreferences.
///
/// Extracted from [BleProvider]: handles the device cache (known device IDs,
/// temp offsets) that was previously stored inline.
///
/// Usage:
/// ```dart
/// final prefs = DevicePreferencesService();
/// final deviceId = await prefs.getSavedDeviceId();
/// await prefs.saveDeviceId('xx:xx:xx:xx:xx:xx');
/// ```
class DevicePreferencesService {
  static const String _deviceIdKey = 'known_device_id';
  static const String _tempOffsetKey = 'cpuTempOffsetDeciC';

  /// Load the last successfully connected BLE device ID.
  Future<String?> getSavedDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_deviceIdKey);
    } catch (_) {
      return null;
    }
  }

  /// Save a BLE device ID for quick reconnect on next launch.
  Future<void> saveDeviceId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deviceIdKey, id);
    } catch (_) {}
  }

  /// Clear the saved BLE device ID.
  Future<void> clearDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_deviceIdKey);
    } catch (_) {}
  }

  /// Load the CPU temperature offset (in deci-°C).
  /// Returns -200 if not set (default offset).
  Future<int> getTempOffset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_tempOffsetKey) ?? -200).clamp(-500, 500);
    } catch (_) {
      return -200;
    }
  }

  /// Save the CPU temperature offset.
  Future<void> setTempOffset(int offset) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_tempOffsetKey, offset.clamp(-500, 500));
    } catch (_) {}
  }

  /// Clear all saved preferences.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_deviceIdKey);
      await prefs.remove(_tempOffsetKey);
    } catch (_) {}
  }
}
