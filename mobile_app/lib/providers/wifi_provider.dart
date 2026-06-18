import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import '../services/logger_service.dart';
import '../services/connection_history_service.dart';
import '../connection/message_dispatcher.dart';
import '../services/binary_message_parser.dart';
import 'firmware_protocol.dart';

/// Configuration for a discovered EvilCrowRF device.
class WifiDeviceInfo {
  final String name;
  final String host;
  final int port;
  final String? fwVersion;

  WifiDeviceInfo({
    required this.name,
    required this.host,
    this.port = 80,
    this.fwVersion,
  });

  @override
  String toString() =>
      'WifiDeviceInfo(name: $name, host: $host, port: $port, fw: $fwVersion)';
}

/// WifiProvider — ChangeNotifier that manages WiFi discovery, provisioning,
/// WebSocket connection, and binary protocol command/response exchange.
///
/// Replaces BleProvider when the app is built with TRANSPORT_MODE=wifi.
/// Uses the same FirmwareBinaryProtocol for command creation and response parsing.
class WifiProvider extends ChangeNotifier {
  // ── Connection state ─────────────────────────────────────────────
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isScanning = false;
  String? _deviceHost;
  String _deviceName = '';
  String _fwVersion = '';
  String? _lastError;

  // ── Discovery ────────────────────────────────────────────────────
  List<WifiDeviceInfo> _discoveredDevices = [];

  // ── WebSocket ────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;

  // ── Binary protocol ──────────────────────────────────────────────
  final FirmwareBinaryProtocol _protocol = FirmwareBinaryProtocol();

  // ── Response handler ─────────────────────────────────────────────
  Function(Map<String, dynamic>)? onJsonReceived;
  Function(Uint8List)? onBinaryReceived;

  /// MessageDispatcher for forwarding parsed responses to module providers.
  /// Set externally after construction. When set, every parsed firmware
  /// response is dispatched here.
  MessageDispatcher? messageDispatcher;

  // ── Getters ──────────────────────────────────────────────────────
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  bool get isScanning => _isScanning;
  String? get deviceHost => _deviceHost;
  String get deviceName => _deviceName;
  String get fwVersion => _fwVersion;
  String? get lastError => _lastError;
  List<WifiDeviceInfo> get discoveredDevices => _discoveredDevices;
  FirmwareBinaryProtocol get protocol => _protocol;

  // ═════════════════════════════════════════════════════════════════
  //  Discovery
  // ═════════════════════════════════════════════════════════════════

  /// Scan for EvilCrowRF devices on the local network.
  ///
  /// Currently uses HTTP GET to /api/info on common IPs as a fallback
  /// since mDNS browsing has platform-specific support.
  /// Future: use `dart:isolate` with multicast DNS (mDNS) for native discovery.
  Future<List<WifiDeviceInfo>> startDiscovery() async {
    _isScanning = true;
    _discoveredDevices = [];
    notifyListeners();

    AppLogger.debug('Starting device discovery...');

    // Try mDNS hostname first (common case)
    const String mdnsHost = 'evilcrow.local';
    try {
      final result = await _queryDeviceInfo(mdnsHost);
      if (result != null) {
        _discoveredDevices.add(result);
        AppLogger.debug('Discovered via mDNS: $result');
      }
    } catch (e) {
      AppLogger.debug('mDNS discovery failed: $e');
    }

    // Also try common local IPs on the subnet
    try {
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      if (wifiIP != null) {
        final subnet = wifiIP.substring(0, wifiIP.lastIndexOf('.') + 1);
        for (int i = 1; i <= 10; i++) {
          final ip = '$subnet$i';
          if (ip == wifiIP) continue; // Skip our own IP
          try {
            final result = await _queryDeviceInfo(ip);
            if (result != null &&
                !_discoveredDevices.any((d) => d.host == ip)) {
              _discoveredDevices.add(result);
              AppLogger.debug('Discovered via IP scan: $result');
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      AppLogger.debug('Subnet scan failed: $e');
    }

    _isScanning = false;
    notifyListeners();
    return _discoveredDevices;
  }

  /// Query a potential device host for its /api/info endpoint.
  Future<WifiDeviceInfo?> _queryDeviceInfo(String host) async {
    try {
      final url = Uri.parse('http://$host/api/info');
      final response = await http.get(url).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final name = json['device_name'] as String? ?? 'EvilCrowRF';
        final fwVer = json['fw_version'] as String?;
        return WifiDeviceInfo(
          name: name,
          host: host,
          port: 80,
          fwVersion: fwVer,
        );
      }
    } catch (_) {}
    return null;
  }

  // ═════════════════════════════════════════════════════════════════
  //  Connection
  // ═════════════════════════════════════════════════════════════════

  /// Connect to a device at the given host (IP or mDNS hostname).
  Future<bool> connect(String host) async {
    if (_isConnected) await disconnect();

    _isConnecting = true;
    _deviceHost = host;
    _lastError = null;
    notifyListeners();

    AppLogger.debug('Connecting to $host...');

    try {
      // 1. Fetch device info via HTTP
      final info = await _queryDeviceInfo(host);
      if (info != null) {
        _deviceName = info.name;
        _fwVersion = info.fwVersion ?? '';
        AppLogger.debug('Device info: $info');
      }

      // 2. Connect WebSocket
      final uri = Uri.parse('ws://$host/api/ws');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _isConnected = true;
      _isConnecting = false;

      // Persist successful connection (F3 of refactor.md).
      // Fire-and-forget — failure here must not block connection.
      // ignore: discarded_futures
      ConnectionHistoryService.saveConnection(
        transport: 'wifi',
        wifiHost: host,
      );

      notifyListeners();

      // 3. Start listening
      _wsSubscription = _channel!.stream.listen(
        (data) {
          if (data is List<int>) {
            _handleBinaryFrame(data);
          } else if (data is String) {
            _handleTextFrame(data);
          }
        },
        onError: (error) {
          AppLogger.debug('WebSocket error: $error');
          _lastError = 'WebSocket error: $error';
          _isConnected = false;
          _isConnecting = false;
          notifyListeners();
        },
        onDone: () {
          AppLogger.debug('WebSocket disconnected');
          _isConnected = false;
          _isConnecting = false;
          notifyListeners();
        },
      );

      AppLogger.debug('Connected to $host');
      return true;
    } catch (e) {
      AppLogger.debug('Connection failed: $e');
      _lastError = 'Connection failed: $e';
      _isConnected = false;
      _isConnecting = false;
      notifyListeners();
      return false;
    }
  }

  /// Disconnect from the current device.
  Future<void> disconnect() async {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    if (_channel != null) {
      try {
        // Use normalClosure (1000) — goingAway (1001) is reserved for the
        // server-side protocol; client code must use 1000 or 3000-4999.
        _channel!.sink.close(ws_status.normalClosure);
      } catch (e) {
        AppLogger.debug('Error closing WebSocket: $e');
      }
      _channel = null;
    }
    _isConnected = false;
    _deviceHost = null;
    notifyListeners();
    AppLogger.debug('Disconnected');
  }

  // ═════════════════════════════════════════════════════════════════
  //  Command sending
  // ═════════════════════════════════════════════════════════════════

  /// Send a raw command (list of bytes) over WebSocket.
  Future<bool> sendCommand(Uint8List command) async {
    if (_channel == null || !_isConnected) {
      AppLogger.debug('Cannot send command: not connected');
      return false;
    }

    try {
      _channel!.sink.add(command);
      return true;
    } catch (e) {
      AppLogger.debug('Failed to send command: $e');
      return false;
    }
  }

  /// Send a command string (converted to bytes) over WebSocket.
  Future<bool> sendCommandString(String commandStr) async {
    return sendCommand(Uint8List.fromList(commandStr.codeUnits));
  }

  // ═════════════════════════════════════════════════════════════════
  //  SmartConfig / Provisioning
  // ═════════════════════════════════════════════════════════════════

  /// Send WiFi credentials to the device via SmartConfig (ESP-TOUCH).
  ///
  /// The phone must be connected to a 2.4 GHz WiFi network for this to work.
  /// The device must be in SmartConfig listen mode (fresh boot, no saved WiFi).
  Future<bool> provisionViaSmartConfig() async {
    AppLogger.debug('Starting SmartConfig provisioning...');

    try {
      // Get current SSID from the phone's WiFi connection
      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      if (ssid == null || ssid.isEmpty) {
        _lastError = 'Phone is not connected to WiFi';
        notifyListeners();
        return false;
      }

      // The ESP32's SmartConfig sniffs for ESP-TOUCH packets.
      // Flutter doesn't have a direct ESP-TOUCH plugin, so we use the
      // SoftAP captive portal as the primary provisioning flow.
      // SmartConfig will be implemented natively when available.

      AppLogger.debug('Current WiFi SSID: $ssid');
      AppLogger.debug('For SmartConfig, ensure device is in provisioning mode');
      return false;
    } catch (e) {
      AppLogger.debug('SmartConfig provisioning failed: $e');
      return false;
    }
  }

  // ═════════════════════════════════════════════════════════════════
  //  Internal handlers
  // ═════════════════════════════════════════════════════════════════

  void _handleBinaryFrame(List<int> data) {
    // Parse binary protocol frame
    if (data.length < FirmwareBinaryProtocol.PACKET_HEADER_SIZE + 1) return;

    final magic = data[0];
    if (magic != FirmwareBinaryProtocol.MAGIC_BYTE) return;

    // Parse as response (pass full frame — parseResponse handles header internally)
    try {
      final response =
          FirmwareBinaryProtocol.parseResponse(Uint8List.fromList(data));

      // If the payload is a binary message, parse it through BinaryMessageParser
      // so providers receive typed maps (e.g. {'type': 'SignalDetected', 'data': {...}}).
      if (response['isBinary'] == true &&
          response['payloadBytes'] is Uint8List) {
        final binaryMsg = BinaryMessageParser.parseBinaryMessage(
            response['payloadBytes'] as Uint8List);
        if (binaryMsg != null) {
          messageDispatcher?.dispatch(binaryMsg);
          if (onJsonReceived != null) {
            onJsonReceived!(binaryMsg);
          }
          return;
        }
      }

      // Fallback: dispatch the raw parsed response
      messageDispatcher?.dispatch(response);
      if (onJsonReceived != null) {
        onJsonReceived!(response);
      }
    } catch (e) {
      AppLogger.debug('Failed to parse response: $e');
    }
  }

  void _handleTextFrame(String data) {
    try {
      final Map<String, dynamic> json = jsonDecode(data);
      // Dispatch to module providers
      messageDispatcher?.dispatch(json);
      if (onJsonReceived != null) {
        onJsonReceived!(json);
      }
    } catch (e) {
      AppLogger.debug('Failed to parse JSON frame: $e');
    }
  }

  // ═════════════════════════════════════════════════════════════════
  //  WiFi Apply (provisioning)
  // ═════════════════════════════════════════════════════════════════

  /// Send WiFi credentials and ask the device to connect to the given network.
  /// The device will save the credentials and attempt to connect.
  /// If successful, the device switches networks and this app connection may drop.
  Future<bool> applyWifiConfig(String ssid, String password) async {
    if (!_isConnected || _channel == null) return false;
    try {
      final cmd = FirmwareBinaryProtocol.createApplyWifiCommand(ssid, password);
      _channel!.sink.add(cmd);
      AppLogger.debug('ApplyWifi: sent credentials for SSID=$ssid');
      return true;
    } catch (e) {
      AppLogger.debug('ApplyWifi failed: $e');
      return false;
    }
  }

  // ═════════════════════════════════════════════════════════════════
  //  Cleanup
  // ═════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
