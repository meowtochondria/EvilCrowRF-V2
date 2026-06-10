import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import '../services/logger_service.dart';

// Abstract interface for the Flutter transport layer
abstract class ITransportLayer {
  // Initialize transport layer
  Future<bool> initialize();

  // Send data
  Future<bool> sendData(String data);

  // Send binary data
  Future<bool> sendBinaryData(List<int> data);

  // Set data receive callback
  void setDataReceivedCallback(Function(String) callback);

  // Check connection
  bool get isConnected;

  // Get statistics
  Map<String, int> getStats();

  // Clean up resources
  void dispose();
}

// Concrete implementation for BLE with Binary Protocol
class BLEBinaryTransport implements ITransportLayer {
  // ignore: unused_field — backing store for ITransportLayer.setDataReceivedCallback
  late Function(String) _dataCallback;
  final bool _isConnected = false;

  // Statistics
  int _packetsSent = 0;
  int _packetsReceived = 0;
  int _errors = 0;

  // Buffers for data assembly
  final Map<int, ChunkBuffer> _chunkBuffers = {};

  // Packet structure
  static const int PACKET_HEADER_SIZE = 7; // Updated: dataLen is now 2 bytes
  static const int MAX_DATA_SIZE = 500; // Updated for Bluetooth 5.0

  @override
  Future<bool> initialize() async {
    AppLogger.debug('Initializing BLE Binary Transport');
    // BLE initialization goes here
    return true;
  }

  @override
  Future<bool> sendData(String data) async {
    if (!_isConnected) {
      AppLogger.debug('Not connected, cannot send data');
      return false;
    }

    AppLogger.debug('Sending data: ${data.length} bytes');

    // Split data into small packets
    int totalChunks = (data.length + MAX_DATA_SIZE - 1) ~/ MAX_DATA_SIZE;
    int chunkId = DateTime.now().millisecondsSinceEpoch & 0xFF;

    for (int i = 0; i < totalChunks; i++) {
      int chunkNum = i + 1;

      // Create packet
      List<int> packet = _createPacket(
        type: 0x01, // data
        chunkId: chunkId,
        chunkNum: chunkNum,
        totalChunks: totalChunks,
        data: data.substring(
            i * MAX_DATA_SIZE,
            (i + 1) * MAX_DATA_SIZE > data.length
                ? data.length
                : (i + 1) * MAX_DATA_SIZE),
      );

      // Send packet
      if (!await _sendPacket(packet)) {
        AppLogger.debug('Failed to send packet $chunkNum');
        _errors++;
        return false;
      }

      // Wait for acknowledgment
      if (!await _waitForACK(chunkId, chunkNum, 1000)) {
        AppLogger.debug('No ACK for packet $chunkNum, retrying');
        // Retry sending
        if (!await _sendPacket(packet)) {
          AppLogger.debug('Retry failed for packet $chunkNum');
          _errors++;
          return false;
        }
      }

      _packetsSent++;

      // Short pause
      await Future.delayed(const Duration(milliseconds: 5));
    }

    AppLogger.debug('Data sent successfully: $totalChunks chunks');
    return true;
  }

  @override
  Future<bool> sendBinaryData(List<int> data) async {
    // Convert to String for unification
    String dataStr = String.fromCharCodes(data);
    return await sendData(dataStr);
  }

  @override
  void setDataReceivedCallback(Function(String) callback) {
    _dataCallback = callback;
  }

  @override
  bool get isConnected => _isConnected;

  @override
  Map<String, int> getStats() {
    return {
      'packetsSent': _packetsSent,
      'packetsReceived': _packetsReceived,
      'errors': _errors,
    };
  }

  @override
  void dispose() {
    _chunkBuffers.clear();
  }

  // Create packet
  List<int> _createPacket({
    required int type,
    required int chunkId,
    required int chunkNum,
    required int totalChunks,
    required String data,
  }) {
    List<int> packet = List.filled(PACKET_HEADER_SIZE + data.length, 0);

    packet[0] = 0xAA; // magic
    packet[1] = type;
    packet[2] = chunkId;
    packet[3] = chunkNum;
    packet[4] = totalChunks;
    packet[5] = data.length & 0xFF; // Data length (low byte)
    packet[6] = (data.length >> 8) & 0xFF; // Data length (high byte)

    // Copy data
    for (int i = 0; i < data.length; i++) {
      packet[7 + i] = data.codeUnitAt(i); // Data starts at offset 7
    }

    // Calculate checksum
    packet[7 + data.length] = _calculateChecksum(packet, data.length);

    return packet;
  }

  // Calculate checksum
  int _calculateChecksum(List<int> packet, int dataLength) {
    int checksum = packet[0] ^
        packet[1] ^
        packet[2] ^
        packet[3] ^
        packet[4] ^
        packet[5] ^
        packet[6];

    for (int i = 0; i < dataLength; i++) {
      checksum ^= packet[7 + i];
    }

    return checksum;
  }

  // Send packet
  Future<bool> _sendPacket(List<int> packet) async {
    // Actual BLE send will go here
    AppLogger.debug('Sending packet: ${packet.length} bytes');
    return true;
  }

  // Wait for acknowledgment
  Future<bool> _waitForACK(int chunkId, int chunkNum, int timeoutMs) async {
    // Simplified implementation - always returns true
    // Full implementation will check received ACKs here
    await Future.delayed(Duration(milliseconds: timeoutMs));
    return true;
  }
}

/// WebSocket transport implementation for WiFi mode.
///
/// Uses a WebSocket connection to the EvilCrowRF device at ws://host:80/api/ws
/// and sends/receives binary frames using the same chunked protocol format.
class WifiWebSocketTransport implements ITransportLayer {
  WebSocketChannel? _channel;
  late Function(String) _dataCallback;

  /// Device host (IP or mDNS hostname with .local).
  final String host;

  /// Connection timeout.
  final Duration connectTimeout;

  // Statistics
  int _packetsSent = 0;
  int _packetsReceived = 0;
  int _errors = 0;

  /// Buffers for chunk assembly.
  final Map<int, ChunkBuffer> _chunkBuffers = {};

  // Packet structure (same as BLE)
  static const int PACKET_HEADER_SIZE = 7;
  static const int MAX_DATA_SIZE = 500;

  WifiWebSocketTransport({
    required this.host,
    this.connectTimeout = const Duration(seconds: 5),
  });

  @override
  Future<bool> initialize() async {
    AppLogger.debug('Initializing WiFi WebSocket Transport to $host');

    try {
      final uri = Uri.parse('ws://$host/api/ws');
      _channel = WebSocketChannel.connect(
        uri,
      );

      // Wait for connection or timeout
      await _channel!.ready;

      AppLogger.debug('WebSocket connected to $host');

      // Listen for incoming data
      _channel!.stream.listen(
        (data) {
          if (data is List<int>) {
            // Binary frame
            _packetsReceived++;
            _handleBinaryData(data);
          } else if (data is String) {
            _packetsReceived++;
            _dataCallback(data);
          }
        },
        onError: (error) {
          AppLogger.debug('WebSocket error: $error');
          _errors++;
        },
        onDone: () {
          AppLogger.debug('WebSocket connection closed');
          _channel = null;
        },
      );

      return true;
    } catch (e) {
      AppLogger.debug('Failed to connect WebSocket: $e');
      _errors++;
      return false;
    }
  }

  @override
  Future<bool> sendData(String data) async {
    if (_channel == null) {
      AppLogger.debug('WebSocket not connected, cannot send data');
      return false;
    }

    try {
      _channel!.sink.add(data);
      _packetsSent++;
      return true;
    } catch (e) {
      AppLogger.debug('Failed to send data: $e');
      _errors++;
      return false;
    }
  }

  @override
  Future<bool> sendBinaryData(List<int> data) async {
    if (_channel == null) {
      AppLogger.debug('WebSocket not connected, cannot send binary data');
      return false;
    }

    try {
      _channel!.sink.add(data);
      _packetsSent++;
      return true;
    } catch (e) {
      AppLogger.debug('Failed to send binary data: $e');
      _errors++;
      return false;
    }
  }

  @override
  void setDataReceivedCallback(Function(String) callback) {
    _dataCallback = callback;
  }

  @override
  bool get isConnected => _channel != null;

  @override
  Map<String, int> getStats() {
    return {
      'packetsSent': _packetsSent,
      'packetsReceived': _packetsReceived,
      'errors': _errors,
    };
  }

  @override
  void dispose() {
    _channel?.sink.close(status.goingAway);
    _channel = null;
    _chunkBuffers.clear();
  }

  /// Handle incoming binary data in chunked protocol format.
  void _handleBinaryData(List<int> data) {
    if (data.length < PACKET_HEADER_SIZE + 1) {
      AppLogger.debug('Binary data too short: ${data.length} bytes');
      return;
    }

    // Parse chunked protocol header
    // Variables are parsed for header validation even if not all used yet
    int magic = data[0];
    int dataLen = data[5] | (data[6] << 8); // Little-endian
    // Protocol fields parsed for future multi-chunk assembly support
    // ignore: unused_local_variable
    int packetType = data[1];
    // ignore: unused_local_variable
    int chunkId = data[2];
    // ignore: unused_local_variable
    int chunkNum = data[3];
    // ignore: unused_local_variable
    int totalChunks = data[4];

    if (magic != 0xAA) {
      AppLogger.debug('Invalid magic byte: 0x${magic.toRadixString(16)}');
      return;
    }

    if (data.length < PACKET_HEADER_SIZE + dataLen + 1) {
      AppLogger.debug(
          'Data length mismatch: header=${data.length}, expected=${PACKET_HEADER_SIZE + dataLen + 1}');
      return;
    }

    // Extract payload
    List<int> payload =
        data.sublist(PACKET_HEADER_SIZE, PACKET_HEADER_SIZE + dataLen);

    // Convert to string and pass to callback
    String payloadStr = String.fromCharCodes(payload);
    _dataCallback(payloadStr);
  }
}

// Buffer for chunk assembly
class ChunkBuffer {
  String data = '';
  int totalChunks;
  int receivedChunks;
  DateTime timestamp;

  ChunkBuffer({
    required this.totalChunks,
    required this.receivedChunks,
    required this.timestamp,
  });
}

// Factory for creating transport layers
class TransportFactory {
  static const int BLE_JSON = 0;
  static const int BLE_BINARY = 1;
  static const int BLE_FAST = 2;
  static const int WIFI_WEBSOCKET = 3;

  static ITransportLayer createTransport(int type, {String? host}) {
    switch (type) {
      case BLE_BINARY:
        return BLEBinaryTransport();
      case WIFI_WEBSOCKET:
        return WifiWebSocketTransport(host: host ?? 'evilcrow.local');
      case BLE_JSON:
        // TODO: Implement JSON transport
        throw UnimplementedError('JSON transport not implemented');
      case BLE_FAST:
        // TODO: Implement fast transport
        throw UnimplementedError('Fast transport not implemented');
      default:
        throw ArgumentError('Unknown transport type: $type');
    }
  }
}
