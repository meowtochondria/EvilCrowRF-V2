import 'dart:async';

/// Layer 1 of the two-layer routing model.
///
/// Broadcasts **already-parsed** firmware responses as `Map<String, dynamic>`
/// to all subscribing module providers.
///
/// Why parsed maps, not raw bytes?
/// ---------------------------------
/// `FirmwareBinaryProtocol.parseResponse()` handles both binary payloads (where
/// `messageType` is `payload[0]`) and JSON payloads (where `type` is a string
/// like `"SignalRecorded"`). Accepting raw `Uint8List` would mean JSON responses
/// have no meaningful message type byte. The dispatcher accepts the
/// **already-parsed** form so providers can filter uniformly on the `type`
/// field — the same pattern `_handleCompleteResponse` uses today.
///
/// Layering rule (prevents double-listening bugs):
///   MessageDispatcher handles parsed transport frames.
///   AppEventBus handles domain events.
///   A provider never listens to both for the same piece of state.
class MessageDispatcher {
  // Broadcast so multiple providers can observe simultaneously.
  final StreamController<Map<String, dynamic>> _controller =
      StreamController.broadcast();

  /// Stream of parsed firmware responses.
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  /// Dispatch a parsed firmware response to all subscribers.
  ///
  /// Called by:
  /// - [BleConnectionProvider]: after [BleChunkHandler] reassembles chunks and
  ///   [FirmwareBinaryProtocol.parseResponse()] parses the complete payload.
  /// - [WifiConnectionProvider]: after [FirmwareBinaryProtocol.parseResponse()]
  ///   parses the complete WebSocket frame.
  void dispatch(Map<String, dynamic> parsedResponse) {
    _controller.add(parsedResponse);
  }

  void dispose() => _controller.close();
}
