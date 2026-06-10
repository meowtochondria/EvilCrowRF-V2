import 'transport_layer.dart';
import '../services/logger_service.dart';

// Adapter for integrating the transport layer with existing Flutter code
class TransportAdapter {
  ITransportLayer? _transport;
  Function(String)? _dataCallback;

  // Statistics
  int _totalCommands = 0;
  int _successfulCommands = 0;
  int _failedCommands = 0;

  // Host for WiFi WebSocket transport
  String? _wifiHost;

  // Initialization
  Future<bool> initialize(int transportType, {String? host}) async {
    AppLogger.debug('Initializing transport adapter with type: $transportType');
    _wifiHost = host;

    try {
      // Create transport layer
      _transport = TransportFactory.createTransport(transportType, host: host);

      // Initialize transport
      if (!await _transport!.initialize()) {
        AppLogger.debug('Failed to initialize transport layer');
        _transport = null;
        return false;
      }

      // Set data receive callback
      _transport!.setDataReceivedCallback((String data) {
        _onDataReceived(data);
      });

      AppLogger.debug('Transport adapter initialized successfully');
      return true;
    } catch (e) {
      AppLogger.debug('Error initializing transport adapter: $e', e);
      _transport = null;
      return false;
    }
  }

  // Process commands
  Future<void> handleCommand(String command) async {
    if (_transport == null) {
      AppLogger.debug('Transport not initialized');
      return;
    }

    _totalCommands++;
    AppLogger.debug('Handling command: $command');

    try {
      // Send command
      bool success = await _transport!.sendData(command);

      if (success) {
        _successfulCommands++;
        AppLogger.debug('Command sent successfully');
      } else {
        _failedCommands++;
        AppLogger.debug('Failed to send command');
      }
    } catch (e) {
      _failedCommands++;
      AppLogger.debug('Command processing failed: $e', e);
    }
  }

  // Get statistics
  Map<String, int> getStats() {
    Map<String, int> stats = {
      'totalCommands': _totalCommands,
      'successfulCommands': _successfulCommands,
      'failedCommands': _failedCommands,
    };

    // Add transport layer statistics
    if (_transport != null) {
      Map<String, int> transportStats = _transport!.getStats();
      stats.addAll(transportStats);
    }

    return stats;
  }

  // Check connection
  bool get isConnected => _transport?.isConnected ?? false;

  // Switch protocol
  Future<bool> switchProtocol(int newType, {String? host}) async {
    AppLogger.debug('Switching protocol to type: $newType');

    if (_transport == null) {
      AppLogger.debug('No transport to switch');
      return false;
    }

    try {
      // Save current state
      // Clean up old transport
      _transport!.dispose();
      _transport = null;

      // Create new transport
      _transport =
          TransportFactory.createTransport(newType, host: host ?? _wifiHost);

      // Initialize new transport
      if (!await _transport!.initialize()) {
        AppLogger.debug('Failed to initialize new transport');
        _transport = null;
        return false;
      }

      // Restore callback
      _transport!.setDataReceivedCallback((String data) {
        _onDataReceived(data);
      });

      AppLogger.debug('Protocol switched successfully');
      return true;
    } catch (e) {
      AppLogger.debug('Error switching protocol: $e', e);
      _transport = null;
      return false;
    }
  }

  // Process received data
  void _onDataReceived(String data) {
    AppLogger.debug('Data received: ${data.length} bytes');
    AppLogger.debug('Data content: $data');

    // Call callback if set
    if (_dataCallback != null) {
      _dataCallback!(data);
    }
  }

  // Set data receive callback
  void setDataReceivedCallback(Function(String) callback) {
    _dataCallback = callback;
  }

  // Clean up resources
  void dispose() {
    if (_transport != null) {
      _transport!.dispose();
      _transport = null;
    }
  }
}

// Global adapter instance
TransportAdapter? gTransportAdapter;
