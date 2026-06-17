import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/message_dispatcher.dart';
import '../services/logger_service.dart';
import 'firmware_protocol.dart';

/// Available actions for hardware buttons.
/// Order matches firmware enum HwButtonAction (0-7).
enum HwButtonAction {
  none, // 0 — Do nothing
  toggleJammer, // 1 — Toggle NRF 2.4 GHz jammer
  toggleRecording, // 2 — Toggle SubGhz signal recording
  replayLast, // 3 — Replay last recorded signal
  toggleLed, // 4 — Toggle LED on/off
  deepSleep, // 5 — Enter deep sleep
  reboot, // 6 — Reboot device
  wifiSoftAp, // 7 — Disconnect WiFi, start SoftAP mode
}

extension HwButtonActionLabel on HwButtonAction {
  String get label {
    switch (this) {
      case HwButtonAction.none:
        return 'None';
      case HwButtonAction.toggleJammer:
        return 'Toggle Jammer';
      case HwButtonAction.toggleRecording:
        return 'Toggle Recording';
      case HwButtonAction.replayLast:
        return 'Replay Last Signal';
      case HwButtonAction.toggleLed:
        return 'Toggle LED';
      case HwButtonAction.deepSleep:
        return 'Deep Sleep';
      case HwButtonAction.reboot:
        return 'Reboot';
      case HwButtonAction.wifiSoftAp:
        return 'WiFi SoftAP';
    }
  }

  IconData get icon {
    switch (this) {
      case HwButtonAction.none:
        return Icons.block;
      case HwButtonAction.toggleJammer:
        return Icons.wifi_tethering_off;
      case HwButtonAction.toggleRecording:
        return Icons.fiber_manual_record;
      case HwButtonAction.replayLast:
        return Icons.replay;
      case HwButtonAction.toggleLed:
        return Icons.lightbulb_outline;
      case HwButtonAction.deepSleep:
        return Icons.bedtime;
      case HwButtonAction.reboot:
        return Icons.restart_alt;
      case HwButtonAction.wifiSoftAp:
        return Icons.wifi_find;
    }
  }
}

class SettingsProvider with ChangeNotifier {
  int _bruterDelayMs = 10; // Default inter-frame delay in ms
  int _bruterModule = 1; // Default bruter module (0=Module 1, 1=Module 2)
  HwButtonAction _button1Action = HwButtonAction.none;
  HwButtonAction _button2Action = HwButtonAction.none;
  String? _button1ReplayPath;
  int _button1ReplayPathType = 1;
  String? _button2ReplayPath;
  int _button2ReplayPathType = 1;
  // NRF24 settings
  int _nrfPaLevel = 3; // 0=MIN, 1=LOW, 2=HIGH, 3=MAX
  int _nrfDataRate = 0; // 0=1MBPS, 1=2MBPS, 2=250KBPS
  int _nrfChannel = 76; // Default channel (0-125)
  int _nrfAutoRetransmit = 5; // Retransmit count (0-15)
  // RF / Scanner settings (extracted from BleProvider as part of M4/M5)
  int _scannerRssi = -80; // RSSI threshold in dBm
  int _bruterPower = 7; // CC1101 TX power (0..7)
  int _bruterRepeats = 4; // Repeats per code
  int _radioPowerMod1 = 10; // CC1101 module 1 power (dBm, -30..10)
  int _radioPowerMod2 = 10; // CC1101 module 2 power (dBm, -30..10)
  int _cpuTempOffsetDeciC = -200; // CPU temperature offset (deci-°C, -500..500)
  int get bruterDelayMs => _bruterDelayMs;
  int get bruterModule => _bruterModule;
  HwButtonAction get button1Action => _button1Action;
  HwButtonAction get button2Action => _button2Action;
  String? get button1ReplayPath => _button1ReplayPath;
  int get button1ReplayPathType => _button1ReplayPathType;
  String? get button2ReplayPath => _button2ReplayPath;
  int get button2ReplayPathType => _button2ReplayPathType;
  int get nrfPaLevel => _nrfPaLevel;
  int get nrfDataRate => _nrfDataRate;
  int get nrfChannel => _nrfChannel;
  int get nrfAutoRetransmit => _nrfAutoRetransmit;
  int get scannerRssi => _scannerRssi;
  int get bruterPower => _bruterPower;
  int get bruterRepeats => _bruterRepeats;
  int get radioPowerMod1 => _radioPowerMod1;
  int get radioPowerMod2 => _radioPowerMod2;
  int get cpuTempOffsetDeciC => _cpuTempOffsetDeciC;

  /// Callback set by the owner (main.dart) to send a raw binary command to
  /// the device. Used by [sendSettingsToDevice] to push all settings in a
  /// single 9-byte firmware payload.
  Future<bool> Function(Uint8List command)? sendCommand;

  StreamSubscription<Map<String, dynamic>>? _subscription;

  SettingsProvider({MessageDispatcher? messageDispatcher}) {
    _loadSettings();
    _subscription = messageDispatcher?.messages.listen(_onMessage);
  }

  void _onMessage(Map<String, dynamic> msg) {
    if (msg['type'] == 'SettingsSync') {
      final data = msg['data'];
      if (data is Map) {
        syncFromDevice(Map<String, dynamic>.from(data));
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// Build the 9-byte settings payload expected by the firmware's
  /// SETTINGS_UPDATE command.
  ///
  /// Layout (matches `BleProvider.sendSettingsToDevice`):
  ///   [0]  int8_t  scannerRssi
  ///   [1]  uint8_t bruterPower
  ///   [2]  uint8_t bruterDelayMs low
  ///   [3]  uint8_t bruterDelayMs high
  ///   [4]  uint8_t bruterRepeats
  ///   [5]  int8_t  radioPowerMod1
  ///   [6]  int8_t  radioPowerMod2
  ///   [7]  uint8_t cpuTempOffsetDeciC low
  ///   [8]  uint8_t cpuTempOffsetDeciC high
  Uint8List _buildSettingsPayload() {
    final payload = Uint8List(9);
    payload[0] = _scannerRssi < 0 ? (_scannerRssi + 256) & 0xFF : _scannerRssi;
    payload[1] = _bruterPower;
    payload[2] = _bruterDelayMs & 0xFF;
    payload[3] = (_bruterDelayMs >> 8) & 0xFF;
    payload[4] = _bruterRepeats;
    payload[5] =
        _radioPowerMod1 < 0 ? (_radioPowerMod1 + 256) & 0xFF : _radioPowerMod1;
    payload[6] =
        _radioPowerMod2 < 0 ? (_radioPowerMod2 + 256) & 0xFF : _radioPowerMod2;
    payload[7] = _cpuTempOffsetDeciC & 0xFF;
    payload[8] = (_cpuTempOffsetDeciC >> 8) & 0xFF;
    return payload;
  }

  /// Push current settings to the device. Updates local state for any
  /// non-null arguments, persists CPU temp offset locally, then sends a
  /// single SETTINGS_UPDATE command carrying all settings.
  Future<bool> sendSettingsToDevice({
    int? scannerRssi,
    int? bruterPower,
    int? bruterDelay,
    int? bruterRepeats,
    int? radioPowerMod1,
    int? radioPowerMod2,
    int? cpuTempOffsetDeciC,
  }) async {
    if (scannerRssi != null) _scannerRssi = scannerRssi;
    if (bruterPower != null) _bruterPower = bruterPower.clamp(0, 7);
    if (bruterDelay != null) _bruterDelayMs = bruterDelay.clamp(1, 1000);
    if (bruterRepeats != null) _bruterRepeats = bruterRepeats.clamp(1, 10);
    if (radioPowerMod1 != null) {
      _radioPowerMod1 = radioPowerMod1.clamp(-30, 10);
    }
    if (radioPowerMod2 != null) {
      _radioPowerMod2 = radioPowerMod2.clamp(-30, 10);
    }
    if (cpuTempOffsetDeciC != null) {
      _cpuTempOffsetDeciC = cpuTempOffsetDeciC.clamp(-500, 500);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('cpuTempOffsetDeciC', _cpuTempOffsetDeciC);
      } catch (e) {
        AppLogger.warning('Failed to persist cpu temp offset: $e');
      }
    }
    notifyListeners();

    final cmd = sendCommand;
    if (cmd == null) return false;
    final payload = _buildSettingsPayload();
    final command = FirmwareBinaryProtocol.createSettingsUpdateCommand(payload);
    return await cmd(command);
  }

  /// Apply a settings-sync payload received from the device (the firmware
  /// echoes its current settings on connect or after a SETTINGS_UPDATE).
  void syncFromDevice(Map<String, dynamic> data) {
    bool changed = false;
    if (data['scannerRssi'] is int && data['scannerRssi'] != _scannerRssi) {
      _scannerRssi = data['scannerRssi'] as int;
      changed = true;
    }
    if (data['bruterPower'] is int && data['bruterPower'] != _bruterPower) {
      _bruterPower = data['bruterPower'] as int;
      changed = true;
    }
    if (data['bruterDelay'] is int && data['bruterDelay'] != _bruterDelayMs) {
      _bruterDelayMs = data['bruterDelay'] as int;
      changed = true;
    }
    if (data['bruterRepeats'] is int &&
        data['bruterRepeats'] != _bruterRepeats) {
      _bruterRepeats = data['bruterRepeats'] as int;
      changed = true;
    }
    if (data['radioPowerMod1'] is int &&
        data['radioPowerMod1'] != _radioPowerMod1) {
      _radioPowerMod1 = data['radioPowerMod1'] as int;
      changed = true;
    }
    if (data['radioPowerMod2'] is int &&
        data['radioPowerMod2'] != _radioPowerMod2) {
      _radioPowerMod2 = data['radioPowerMod2'] as int;
      changed = true;
    }
    if (data['cpuTempOffsetDeciC'] is int &&
        data['cpuTempOffsetDeciC'] != _cpuTempOffsetDeciC) {
      _cpuTempOffsetDeciC = data['cpuTempOffsetDeciC'] as int;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _bruterDelayMs = prefs.getInt('bruterDelayMs') ?? 10;
    _bruterModule = (prefs.getInt('bruterModule') ?? 1).clamp(0, 1);
    _button1Action = HwButtonAction.values[
        (prefs.getInt('hwButton1Action') ?? 0)
            .clamp(0, HwButtonAction.values.length - 1)];
    _button2Action = HwButtonAction.values[
        (prefs.getInt('hwButton2Action') ?? 0)
            .clamp(0, HwButtonAction.values.length - 1)];
    _button1ReplayPath = prefs.getString('hwButton1ReplayPath');
    _button1ReplayPathType =
        (prefs.getInt('hwButton1ReplayPathType') ?? 1).clamp(0, 5);
    _button2ReplayPath = prefs.getString('hwButton2ReplayPath');
    _button2ReplayPathType =
        (prefs.getInt('hwButton2ReplayPathType') ?? 1).clamp(0, 5);
    // NRF24 settings
    _nrfPaLevel = (prefs.getInt('nrfPaLevel') ?? 3).clamp(0, 3);
    _nrfDataRate = (prefs.getInt('nrfDataRate') ?? 0).clamp(0, 2);
    _nrfChannel = (prefs.getInt('nrfChannel') ?? 76).clamp(0, 125);
    _nrfAutoRetransmit = (prefs.getInt('nrfAutoRetransmit') ?? 5).clamp(0, 15);
    notifyListeners();
  }

  Future<void> setBruterDelayMs(int value) async {
    _bruterDelayMs = value.clamp(1, 1000);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bruterDelayMs', _bruterDelayMs);
    notifyListeners();
  }

  // ── RF / scanner / power settings (delegated to sendSettingsToDevice) ──
  Future<bool> setScannerRssi(int rssi) =>
      sendSettingsToDevice(scannerRssi: rssi);
  Future<bool> setBruterPowerValue(int power) =>
      sendSettingsToDevice(bruterPower: power);
  Future<bool> setBruterRepeats(int repeats) =>
      sendSettingsToDevice(bruterRepeats: repeats);
  Future<bool> setRadioPowerMod1(int power) =>
      sendSettingsToDevice(radioPowerMod1: power);
  Future<bool> setRadioPowerMod2(int power) =>
      sendSettingsToDevice(radioPowerMod2: power);
  Future<bool> setCpuTempOffsetDeciC(int offset) =>
      sendSettingsToDevice(cpuTempOffsetDeciC: offset);

  Future<void> setBruterModule(int value) async {
    _bruterModule = value.clamp(0, 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bruterModule', _bruterModule);
    notifyListeners();
  }

  Future<void> setButton1Action(HwButtonAction action) async {
    _button1Action = action;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hwButton1Action', action.index);
    notifyListeners();
  }

  Future<void> setButton2Action(HwButtonAction action) async {
    _button2Action = action;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hwButton2Action', action.index);
    notifyListeners();
  }

  Future<void> setButton1ReplayFile(String? path, int pathType) async {
    _button1ReplayPath = path;
    _button1ReplayPathType = pathType.clamp(0, 5);
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove('hwButton1ReplayPath');
    } else {
      await prefs.setString('hwButton1ReplayPath', path);
    }
    await prefs.setInt('hwButton1ReplayPathType', _button1ReplayPathType);
    notifyListeners();
  }

  Future<void> setButton2ReplayFile(String? path, int pathType) async {
    _button2ReplayPath = path;
    _button2ReplayPathType = pathType.clamp(0, 5);
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove('hwButton2ReplayPath');
    } else {
      await prefs.setString('hwButton2ReplayPath', path);
    }
    await prefs.setInt('hwButton2ReplayPathType', _button2ReplayPathType);
    notifyListeners();
  }

  Future<void> setNrfPaLevel(int value) async {
    _nrfPaLevel = value.clamp(0, 3);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nrfPaLevel', _nrfPaLevel);
    notifyListeners();
  }

  Future<void> setNrfDataRate(int value) async {
    _nrfDataRate = value.clamp(0, 2);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nrfDataRate', _nrfDataRate);
    notifyListeners();
  }

  Future<void> setNrfChannel(int value) async {
    _nrfChannel = value.clamp(0, 125);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nrfChannel', _nrfChannel);
    notifyListeners();
  }

  Future<void> setNrfAutoRetransmit(int value) async {
    _nrfAutoRetransmit = value.clamp(0, 15);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nrfAutoRetransmit', _nrfAutoRetransmit);
    notifyListeners();
  }

  /// Sync HW button config received from the device (0xC8 message).
  /// Updates local settings to reflect what the firmware actually has.
  Future<void> syncButtonsFromDevice({
    required int btn1Action,
    required int btn2Action,
    int btn1PathType = 0,
    int btn2PathType = 0,
  }) async {
    final b1 = HwButtonAction
        .values[btn1Action.clamp(0, HwButtonAction.values.length - 1)];
    final b2 = HwButtonAction
        .values[btn2Action.clamp(0, HwButtonAction.values.length - 1)];
    bool changed = false;
    if (_button1Action != b1) {
      _button1Action = b1;
      changed = true;
    }
    if (_button2Action != b2) {
      _button2Action = b2;
      changed = true;
    }
    if (_button1ReplayPathType != btn1PathType) {
      _button1ReplayPathType = btn1PathType;
      changed = true;
    }
    if (_button2ReplayPathType != btn2PathType) {
      _button2ReplayPathType = btn2PathType;
      changed = true;
    }
    if (changed) {
      // Persist new values
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('hwButton1Action', _button1Action.index);
      await prefs.setInt('hwButton2Action', _button2Action.index);
      await prefs.setInt('hwButton1ReplayPathType', _button1ReplayPathType);
      await prefs.setInt('hwButton2ReplayPathType', _button2ReplayPathType);
      notifyListeners();
    }
  }
}
