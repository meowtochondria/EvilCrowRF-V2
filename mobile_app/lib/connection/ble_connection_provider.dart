import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/logger_service.dart';
import '../services/connection_history_service.dart';
import '../providers/firmware_protocol.dart';
import '../services/binary_message_parser.dart';
import 'message_dispatcher.dart';

/// Pure BLE transport provider.
///
/// Handles scan, connect, disconnect, MTU negotiation, characteristic
/// discovery, notification subscription, and binary command sending.
/// Contains **no** device state or module logic — those live in the
/// module providers (DeviceInfoProvider, SubGhzProvider, etc.) or in
/// the legacy [BleProvider] during the M5 transition.
///
/// ## Architecture (refactor.md §1.4)
///
/// ```
/// Widgets/Screens
///   │
///   ├── ModuleProviders (sendCommand callback ──► BleConnectionProvider.sendBinaryCommand)
///   │
///   └── ConnectionStateProvider ──► BleConnectionProvider.isConnected / .deviceName
/// ```
class BleConnectionProvider extends ChangeNotifier {
  // ── BLE transport state ────────────────────────────────────────
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? txCharacteristic;
  BluetoothCharacteristic? rxCharacteristic;

  bool isScanning = false;
  bool isConnected = false;
  String statusMessage = ''; // Localization key or plain status
  List<ScanResult> scanResults = [];

  // Stream subscriptions (cancelled on reconnect / dispose)
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<List<int>>? _rxValueSubscription;

  // ── Known device persistence ───────────────────────────────────
  String? _knownDeviceId;
  String? _deviceName;
  String? _deviceId;

  // Reconnect state
  Timer? _reconnectTimer;
  static const int _maxReconnectAttempts = 5;

  // ── MessageDispatcher for parsed responses ─────────────────────
  MessageDispatcher? messageDispatcher;

  // ── OTA auto-reconnect state (kept here so reconnect survives) ──
  bool _otaRebootPending = false;

  // ── Constants ──────────────────────────────────────────────────
  static const List<String> supportedDeviceNames = [
    'ESP32_CC1101',
    'EvilCrow_RF2',
    'ESP32_Binary',
    'ESP32',
  ];

  // Nordic UART Service (NUS) UUIDs
  static const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String txUuid =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // Write characteristic
  static const String rxUuid =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // Notify characteristic

  // ── Getters ────────────────────────────────────────────────────

  String get deviceName => _deviceName ?? connectedDevice?.name ?? '';
  String? get deviceId => _deviceId ?? connectedDevice?.id.toString();
  String? get savedDeviceId => _knownDeviceId;
  String get savedDeviceName => _knownDeviceId != null ? 'EvilCrow_RF2' : '';

  /// Filter scan results to show only supported devices.
  List<ScanResult> get supportedScanResults {
    return scanResults.where((result) => isDeviceMatching(result)).toList();
  }

  // ── Initialization ─────────────────────────────────────────────

  Future<void> init() async {
    try {
      await _initializeBle();
    } catch (e) {
      AppLogger.debug(
          'BLE init failed (may be normal on non-BLE platforms)', e);
    }
  }

  Future<void> _initializeBle() async {
    // Listen to adapter state changes
    await _requestPermissions();
    _adapterStateSubscription?.cancel();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      statusMessage = _adapterStateMessage(state);
      notifyListeners();
    });

    // Load known device for quick connect
    await _loadKnownDevice();
  }

  String _adapterStateMessage(BluetoothAdapterState state) {
    switch (state) {
      case BluetoothAdapterState.on:
        return 'bluetoothEnabled';
      case BluetoothAdapterState.off:
        return 'bluetoothDisabled';
      case BluetoothAdapterState.unauthorized:
        return 'somePermissionsDenied';
      default:
        return state.toString();
    }
  }

  Future<void> _requestPermissions() async {
    try {
      if (await Permission.bluetooth.isDenied) {
        await Permission.bluetooth.request();
      }
      if (await Permission.bluetoothScan.isDenied) {
        await Permission.bluetoothScan.request();
      }
      if (await Permission.bluetoothConnect.isDenied) {
        await Permission.bluetoothConnect.request();
      }
      if (await Permission.location.isDenied) {
        await Permission.location.request();
      }
    } catch (e) {
      AppLogger.debug('Permission request error', e);
    }
  }

  Future<void> requestPermissions() async {
    await _requestPermissions();
    notifyListeners();
  }

  // ── Known device persistence ───────────────────────────────────

  Future<void> _loadKnownDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _knownDeviceId = prefs.getString('saved_device_id');
      _deviceName = prefs.getString('saved_device_name');
      _deviceId = prefs.getString('saved_device_id');
    } catch (e) {
      AppLogger.debug('Failed to load known device', e);
    }
  }

  Future<void> saveKnownDevice(String deviceId, {String? name}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_device_id', deviceId);
      if (name != null) {
        await prefs.setString('saved_device_name', name);
      }
      _knownDeviceId = deviceId;
      _deviceId = deviceId;
      _deviceName = name;
    } catch (e) {
      AppLogger.debug('Failed to save known device', e);
    }
  }

  Future<void> clearDeviceCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('saved_device_id');
      await prefs.remove('saved_device_name');
      _knownDeviceId = null;
      _deviceId = null;
      _deviceName = null;
      notifyListeners();
    } catch (e) {
      AppLogger.debug('Failed to clear device cache', e);
    }
  }

  // ── Scanning ───────────────────────────────────────────────────

  Future<void> startScan() async {
    if (isScanning) return;

    try {
      isScanning = true;
      scanResults.clear();
      statusMessage = 'scanningForDevices';
      notifyListeners();

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      _scanResultsSubscription?.cancel();
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
        scanResults = results;
        notifyListeners();
      });

      statusMessage = 'scanningForDevices';
      notifyListeners();
    } catch (e) {
      isScanning = false;
      statusMessage = 'scanError: $e';
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    if (!isScanning) return;

    try {
      await FlutterBluePlus.stopScan();
      isScanning = false;
      statusMessage = 'scanStopped';
      notifyListeners();
    } catch (e) {
      statusMessage = 'stopScanError: $e';
      notifyListeners();
    }
  }

  /// Check if a scan result matches our known device.
  bool isDeviceMatching(ScanResult result) {
    if (_knownDeviceId != null &&
        result.device.id.toString() == _knownDeviceId) {
      return true;
    }
    final name = result.device.name;
    if (name.isEmpty) return false;
    return supportedDeviceNames.any((supported) =>
        name.startsWith(supported) || supported.startsWith(name));
  }

  // ── Quick Connect ──────────────────────────────────────────────

  Future<void> quickConnect() async {
    if (isConnected || isScanning) return;

    // First try: use known device directly
    if (_knownDeviceId != null) {
      try {
        final device = BluetoothDevice.fromId(_knownDeviceId!);
        AppLogger.debug(
            'Created device object for known device: ${device.name} (${device.id})');
        await connectToDevice(device,
            connectTimeout: const Duration(seconds: 3));
        return;
      } catch (e) {
        AppLogger.debug('Direct connect failed, falling back to scan', e);
      }
    }

    // Second try: scan for matching device
    try {
      final completer = Completer<void>();
      StreamSubscription<List<ScanResult>>? sub;
      Timer? timeout;

      await startScan();

      sub = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          if (isDeviceMatching(result)) {
            AppLogger.debug(
                'Found target device: ${result.device.id} (${result.device.name})');
            sub?.cancel();
            timeout?.cancel();
            stopScan();
            connectToDevice(result.device).then((_) {
              saveKnownDevice(result.device.id.toString());
              if (!completer.isCompleted) completer.complete();
            }).catchError((e) {
              if (!completer.isCompleted) completer.completeError(e);
            });
            return;
          }
        }
      });

      timeout = Timer(const Duration(seconds: 8), () {
        sub?.cancel();
        stopScan();
        if (!completer.isCompleted) {
          completer.completeError(
              TimeoutException('No matching device found during scan'));
        }
      });

      await completer.future;
    } catch (e) {
      AppLogger.debug('quickConnect failed', e);
      rethrow;
    }
  }

  // ── Connection ─────────────────────────────────────────────────

  Future<void> connectToDevice(BluetoothDevice device,
      {Duration connectTimeout = const Duration(seconds: 10)}) async {
    try {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      statusMessage = 'connecting';
      notifyListeners();

      await device.connect(timeout: connectTimeout);
      connectedDevice = device;

      // Connection state monitoring
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        final connected = state == BluetoothConnectionState.connected;
        if (!connected && connectedDevice != null) {
          AppLogger.debug('Device disconnected, resetting state');
          _resetConnectionState();
        }
      });

      // Discover services
      final services = await device.discoverServices();

      BluetoothService? targetService;
      for (final service in services) {
        if (service.uuid.toString().toUpperCase() ==
            serviceUuid.toUpperCase()) {
          targetService = service;
          break;
        }
      }

      if (targetService != null) {
        for (final characteristic in targetService.characteristics) {
          if (characteristic.uuid.toString().toUpperCase() ==
              txUuid.toUpperCase()) {
            txCharacteristic = characteristic;
          } else if (characteristic.uuid.toString().toUpperCase() ==
              rxUuid.toUpperCase()) {
            rxCharacteristic = characteristic;
          }
        }

        if (txCharacteristic != null && rxCharacteristic != null) {
          isConnected = true;
          statusMessage = 'Connected to ${device.name}';
          _deviceName = device.name;
          _deviceId = device.id.toString();

          await saveKnownDevice(device.id.toString(), name: device.name);

          // Persist connection history (F3 of refactor.md)
          // ignore: discarded_futures
          ConnectionHistoryService.saveConnection(
            transport: 'ble',
            bleDeviceId: device.id.toString(),
          );

          // MTU negotiation
          try {
            await device.requestMtu(512);
          } catch (e) {
            AppLogger.debug('MTU negotiation failed', e);
          }

          // Subscribe to notifications
          await rxCharacteristic!.setNotifyValue(true);

          _rxValueSubscription?.cancel();
          _rxValueSubscription =
              rxCharacteristic!.onValueReceived.listen((value) {
            try {
              final response = FirmwareBinaryProtocol.parseResponse(
                  Uint8List.fromList(value));

              // If the payload is a binary message, parse it through
              // BinaryMessageParser so providers receive typed maps.
              if (response['isBinary'] == true &&
                  response['payloadBytes'] is Uint8List) {
                final binaryMsg = BinaryMessageParser.parseBinaryMessage(
                    response['payloadBytes'] as Uint8List);
                if (binaryMsg != null) {
                  messageDispatcher?.dispatch(binaryMsg);
                  return;
                }
              }

              // Fallback: forward the raw parsed response
              messageDispatcher?.dispatch(response);
            } catch (e) {
              // Non-protocol data — ignore
            }
          });
        } else {
          statusMessage = 'Required characteristics not found';
          await disconnect();
        }
      } else {
        statusMessage = 'Required service not found';
        await disconnect();
      }

      notifyListeners();
    } catch (e) {
      statusMessage = 'Connection error: $e';
      notifyListeners();
    }
  }

  void _resetConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _rxValueSubscription?.cancel();
    _rxValueSubscription = null;

    final shouldAutoReconnect = _otaRebootPending;

    connectedDevice = null;
    txCharacteristic = null;
    rxCharacteristic = null;
    isConnected = false;
    statusMessage = 'disconnected';

    notifyListeners();

    if (shouldAutoReconnect) {
      _otaRebootPending = false;
      _scheduleOtaReconnect();
      return;
    }

    if (_knownDeviceId != null) {
      _scheduleReconnect(0);
    }
  }

  Future<void> disconnect() async {
    if (connectedDevice != null) {
      try {
        await connectedDevice!.disconnect();
      } catch (e) {
        AppLogger.debug('Disconnect error', e);
      }
      _resetConnectionState();
    }
  }

  // ── Send Command ───────────────────────────────────────────────

  /// Send a text command by converting to the appropriate firmware binary
  /// protocol command. Supports: getState, SCAN, RECORD, PLAY, STOP, REBOOT.
  Future<void> sendTextCommand(String command) async {
    Uint8List cmdBytes;
    switch (command.toUpperCase()) {
      case 'SCAN':
        cmdBytes = FirmwareBinaryProtocol.createRequestScanCommand(-100, 0);
        break;
      case 'RECORD':
        cmdBytes = FirmwareBinaryProtocol.createGetStateCommand();
        break;
      case 'PLAY':
        cmdBytes = FirmwareBinaryProtocol.createGetStateCommand();
        break;
      case 'STOP':
        cmdBytes = FirmwareBinaryProtocol.createRequestIdleCommand(0);
        break;
      case 'REBOOT':
        cmdBytes = FirmwareBinaryProtocol.createRebootCommand();
        break;
      case 'GETSTATE':
      case 'getState':
        cmdBytes = FirmwareBinaryProtocol.createGetStateCommand();
        break;
      default:
        throw Exception('Unknown debug command: $command');
    }
    await sendBinaryCommand(cmdBytes);
  }

  Future<void> sendBinaryCommand(Uint8List command,
      {bool withoutResponse = false}) async {
    if (!isConnected || txCharacteristic == null) {
      throw Exception('Device not connected');
    }

    try {
      final useNoResp =
          withoutResponse && txCharacteristic!.properties.writeWithoutResponse;
      await txCharacteristic!.write(command, withoutResponse: useNoResp);
    } catch (e) {
      AppLogger.debug('Error sending binary command', e);
      throw Exception('Failed to send command: $e');
    }
  }

  // ── Auto-Reconnect ─────────────────────────────────────────────

  void _scheduleReconnect(int attempt) {
    if (attempt >= _maxReconnectAttempts) return;
    final delay =
        Duration(seconds: [2, 5, 10, 30, 60].elementAt(attempt.clamp(0, 4)));

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      try {
        await quickConnect();
        if (isConnected) {
          // Connected; don't schedule further retries
        } else {
          _scheduleReconnect(attempt + 1);
        }
      } catch (e) {
        _scheduleReconnect(attempt + 1);
      }
    });
  }

  void _scheduleOtaReconnect() {
    const delay = Duration(seconds: 5);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      try {
        await quickConnect();
      } catch (e) {
        // Silently retry
      }
    });
  }

  /// Mark that an OTA reboot is pending so reconnect fires after disconnect.
  void setOtaRebootPending() {
    _otaRebootPending = true;
  }

  // ── Dispose ────────────────────────────────────────────────────

  @override
  void dispose() {
    _adapterStateSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _rxValueSubscription?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
