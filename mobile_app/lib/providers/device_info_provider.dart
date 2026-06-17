import 'dart:async';
import 'package:flutter/foundation.dart';
import '../connection/message_dispatcher.dart';
import 'firmware_protocol.dart';

/// Device information and status provider.
///
/// Extracted from [BleProvider]: handles device identity, firmware version,
/// battery, SD card, NRF presence, HW button config, and settings sync.
/// Subscribes to [MessageDispatcher.messages].
class DeviceInfoProvider extends ChangeNotifier {
  final MessageDispatcher _messageDispatcher;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  // ── Connection to transport (set externally for sendCommand) ──
  Future<bool> Function(Uint8List)? sendCommand;

  DeviceInfoProvider(this._messageDispatcher) {
    _subscription = _messageDispatcher.messages.listen(_dispatch);
  }

  // ══════════════════════════════════════════════════════════════
  //  State fields
  // ══════════════════════════════════════════════════════════════

  // -- Device status --
  Map<String, dynamic>? deviceStatus;
  int? freeHeap;
  double? cpuTempC;
  int? core0Mhz;
  int? core1Mhz;
  List<Map<String, dynamic>>? cc1101Modules;

  // -- Firmware version --
  String _firmwareVersion = '';
  String get firmwareVersion => _firmwareVersion;
  int _fwMajor = 0;
  int get fwMajor => _fwMajor;
  int _fwMinor = 0;
  int get fwMinor => _fwMinor;
  int _fwPatch = 0;
  int get fwPatch => _fwPatch;

  // -- Device name --
  String _deviceName = 'EvilCrow_RF2';
  String get deviceName => _deviceName;

  // -- Battery --
  double _batteryVoltage = 0.0;
  double get batteryVoltage => _batteryVoltage;
  int _batteryPercent = 0;
  int get batteryPercent => _batteryPercent;
  bool _batteryCharging = false;
  bool get batteryCharging => _batteryCharging;
  bool _hasBatteryInfo = false;
  bool get hasBatteryInfo => _hasBatteryInfo;

  // -- WiFi AP config --
  String _wifiApName = '';
  String get wifiApName => _wifiApName;
  String _wifiApPassword = '';
  String get wifiApPassword => _wifiApPassword;
  String? apHost;

  // -- SD card --
  bool _sdMounted = false;
  bool get sdMounted => _sdMounted;
  int _sdTotalMB = 0;
  int get sdTotalMB => _sdTotalMB;
  int _sdFreeMB = 0;
  int get sdFreeMB => _sdFreeMB;

  // -- NRF presence --
  bool _nrfPresent = false;
  bool get nrfPresent => _nrfPresent;

  // -- HW button config --
  int deviceBtn1Action = -1;
  int deviceBtn2Action = -1;
  int deviceBtn1PathType = -1;
  int deviceBtn2PathType = -1;

  // -- SDR state --
  bool sdrModeActive = false;
  int sdrSubMode = 0;
  double sdrFrequencyMHz = 433.92;
  int sdrModulation = 2; // ASK/OOK default

  // -- CPU temp offset --
  int cpuTempOffsetDeciC = -200;

  // -- Settings sync state --
  bool _settingsSynced = false;
  bool get settingsSynced => _settingsSynced;

  // ══════════════════════════════════════════════════════════════
  //  Dispatch — filter by type field
  // ══════════════════════════════════════════════════════════════

  void _dispatch(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'state':
      case 'State':
        _handleStateResponse(msg);
        break;
      case 'VersionInfo':
        _handleVersionInfo(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'DeviceName':
        _handleDeviceName(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'BatteryStatus':
        _handleBatteryStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'HwButtonStatus':
        _handleHwButtonStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'SdStatus':
        _handleSdStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfModuleStatus':
        _handleNrfModuleStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'WifiApConfig':
        _handleWifiApConfig(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'SettingsSync':
        _handleSettingsSync(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'SdrStatus':
        _handleSdrStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'ModeSwitch':
        _handleModeSwitch(msg['data'] as Map<String, dynamic>? ?? {});
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers
  // ══════════════════════════════════════════════════════════════

  void _handleStateResponse(Map<String, dynamic> msg) {
    final actualData =
        (msg['data'] is Map) ? Map<String, dynamic>.from(msg['data']) : msg;

    if (actualData['device'] != null) {
      deviceStatus = actualData['device'];
      freeHeap = actualData['device']['freeHeap'];
      final t = actualData['device']['cpuTempC'];
      cpuTempC = t is num ? t.toDouble() : null;
      final c0 = actualData['device']['core0Mhz'];
      final c1 = actualData['device']['core1Mhz'];
      core0Mhz = c0 is num ? c0.toInt() : null;
      core1Mhz = c1 is num ? c1.toInt() : null;
    }
    if (actualData['cc1101'] != null) {
      cc1101Modules = List<Map<String, dynamic>>.from(actualData['cc1101']);
    }
    notifyListeners();
  }

  void _handleVersionInfo(Map<String, dynamic> data) {
    _fwMajor = data['major'] ?? 0;
    _fwMinor = data['minor'] ?? 0;
    _fwPatch = data['patch'] ?? 0;
    _firmwareVersion = data['version'] ?? '$_fwMajor.$_fwMinor.$_fwPatch';
    notifyListeners();
  }

  void _handleDeviceName(Map<String, dynamic> data) {
    final name = data['name'] as String? ?? '';
    if (name.isNotEmpty) {
      _deviceName = name;
      notifyListeners();
    }
  }

  void _handleBatteryStatus(Map<String, dynamic> data) {
    _batteryVoltage = (data['voltage'] as num?)?.toDouble() ?? 0.0;
    _batteryPercent = data['percent'] ?? 0;
    _batteryCharging = data['charging'] == true || data['charging'] == 1;
    _hasBatteryInfo = data['percent'] != null || data['voltage'] != null;
    notifyListeners();
  }

  void _handleHwButtonStatus(Map<String, dynamic> data) {
    deviceBtn1Action = data['btn1Action'] ?? -1;
    deviceBtn2Action = data['btn2Action'] ?? -1;
    deviceBtn1PathType = data['btn1PathType'] ?? -1;
    deviceBtn2PathType = data['btn2PathType'] ?? -1;
    notifyListeners();
  }

  void _handleSdStatus(Map<String, dynamic> data) {
    _sdMounted = data['mounted'] == true || data['mounted'] == 1;
    _sdTotalMB = data['totalMB'] ?? 0;
    _sdFreeMB = data['freeMB'] ?? 0;
    notifyListeners();
  }

  void _handleNrfModuleStatus(Map<String, dynamic> data) {
    _nrfPresent = data['present'] == true || data['present'] == 1;
    notifyListeners();
  }

  void _handleWifiApConfig(Map<String, dynamic> data) {
    _wifiApName = data['name'] ?? '';
    _wifiApPassword = data['password'] ?? '';
    apHost = data['host'] as String?;
    notifyListeners();
  }

  void _handleSettingsSync(Map<String, dynamic> data) {
    // Apply all settings from device
    if (data['name'] != null) _deviceName = data['name'];
    if (data['wifi_ap'] != null) {
      final ap = data['wifi_ap'] as Map?;
      if (ap != null) {
        _wifiApName = ap['name'] ?? _wifiApName;
        _wifiApPassword = ap['password'] ?? _wifiApPassword;
      }
    }
    if (data['hw_buttons'] != null) {
      final btns = data['hw_buttons'] as Map?;
      if (btns != null) {
        deviceBtn1Action = btns['btn1Action'] ?? deviceBtn1Action;
        deviceBtn2Action = btns['btn2Action'] ?? deviceBtn2Action;
        deviceBtn1PathType = btns['btn1PathType'] ?? deviceBtn1PathType;
        deviceBtn2PathType = btns['btn2PathType'] ?? deviceBtn2PathType;
      }
    }
    if (data['sdr_enabled'] != null)
      sdrModeActive = data['sdr_enabled'] == true;
    _settingsSynced = true;
    notifyListeners();
  }

  void _handleSdrStatus(Map<String, dynamic> data) {
    sdrModeActive = data['active'] == true;
    sdrFrequencyMHz = (data['freqKhz'] ?? 433920) / 1000.0;
    sdrModulation = data['modulation'] ?? 2;
    notifyListeners();
  }

  void _handleModeSwitch(Map<String, dynamic> modeData) {
    // Track module modes in cc1101Modules
    final module = int.tryParse('${modeData['module']}') ?? 0;
    final mode = modeData['mode'] as String? ?? 'Unknown';

    if (cc1101Modules != null && module < cc1101Modules!.length) {
      cc1101Modules![module]['mode'] = mode;
    } else {
      cc1101Modules ??= [];
      while (cc1101Modules!.length <= module) {
        cc1101Modules!.add({'id': cc1101Modules!.length, 'mode': 'Unknown'});
      }
      cc1101Modules![module] = {
        ...cc1101Modules![module],
        'id': module,
        'mode': mode,
      };
    }
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands
  // ══════════════════════════════════════════════════════════════

  Future<void> requestGetState() async {
    if (sendCommand == null) return;
    await sendCommand!(FirmwareBinaryProtocol.createGetStateCommand());
  }

  /// Check if a CC1101 module is available for operations.
  bool isModuleAvailable(int moduleIndex) {
    if (cc1101Modules == null || moduleIndex >= cc1101Modules!.length) {
      return false;
    }
    final mode = cc1101Modules![moduleIndex]['mode'] as String? ?? 'Unknown';
    return mode == 'Idle';
  }

  /// Get a CC1101 module's current state string.
  String getModuleStatus(int moduleIndex) {
    if (cc1101Modules == null || moduleIndex >= cc1101Modules!.length) {
      return 'Unknown';
    }
    return cc1101Modules![moduleIndex]['mode'] as String? ?? 'Unknown';
  }

  Future<bool> setDeviceName(String name) async {
    if (sendCommand == null) return false;
    final cmd = FirmwareBinaryProtocol.createSetDeviceNameCommand(name);
    await sendCommand!(cmd);
    _deviceName = name; // optimistic update
    notifyListeners();
    return true;
  }

  Future<bool> applyWifiConfig(String ssid, String password) async {
    if (sendCommand == null) return false;
    final cmd = FirmwareBinaryProtocol.createApplyWifiCommand(ssid, password);
    await sendCommand!(cmd);
    return true;
  }

  // ══════════════════════════════════════════════════════════════
  //  Lifecycle
  // ══════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
