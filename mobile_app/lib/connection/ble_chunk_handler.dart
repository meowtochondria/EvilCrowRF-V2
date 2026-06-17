import 'dart:typed_data';

/// Assembles chunked BLE notification frames into complete payloads.
///
/// BLE has a ~509-byte MTU per notify, so large responses (> 500 bytes of
/// payload) are split into multiple chunks by the firmware. This handler
/// reassembles them.
///
/// **WiFi does NOT use this class** — WebSocket delivers complete frames.
///
/// Usage:
/// ```dart
/// final handler = BleChunkHandler();
/// Uint8List? complete = handler.processChunk(chunkId, chunkNum, total, data);
/// if (complete != null) {
///   // All chunks received — parse and dispatch
///   final parsed = FirmwareBinaryProtocol.parseResponse(complete);
///   messageDispatcher.dispatch(parsed);
/// }
/// ```
class BleChunkHandler {
  // chunkId → { chunkNumber → data }
  final Map<int, Map<int, Uint8List>> _chunkData = {};
  // chunkId → expected chunk count
  final Map<int, int> _expectedChunks = {};
  // chunkId → set of received chunk numbers
  final Map<int, Set<int>> _receivedChunks = {};
  // chunkId → timestamp when buffer was created
  final Map<int, DateTime> _chunkStartTimes = {};
  // chunkId → timestamp when last chunk was received
  final Map<int, DateTime> _chunkLastReceived = {};

  /// Overall timeout for a complete chunked transfer.
  static const Duration _chunkTimeout = Duration(seconds: 10);

  /// Timeout if chunks stop arriving (handles BLE stack scheduling jitter).
  static const Duration _chunkStaleTimeout = Duration(seconds: 4);

  /// Process an incoming chunk.
  ///
  /// Returns the complete assembled [Uint8List] when all chunks for this
  /// [chunkId] have been received. Returns `null` while still waiting for
  /// more chunks.
  Uint8List? processChunk(
    int chunkId,
    int chunkNumber,
    int totalChunks,
    Uint8List data,
  ) {
    final now = DateTime.now();

    // Initialize storage for this chunkId if new.
    if (!_chunkData.containsKey(chunkId)) {
      _chunkData[chunkId] = <int, Uint8List>{};
      _expectedChunks[chunkId] = totalChunks;
      _receivedChunks[chunkId] = <int>{};
      _chunkStartTimes[chunkId] = now;
      _chunkLastReceived[chunkId] = now;
    } else {
      _chunkLastReceived[chunkId] = now;
    }

    // Handle duplicates gracefully (BLE retransmission).
    if (!_receivedChunks[chunkId]!.contains(chunkNumber)) {
      _receivedChunks[chunkId]!.add(chunkNumber);
    }

    // Store (or overwrite if duplicate).
    _chunkData[chunkId]![chunkNumber] = data;

    // Check if all chunks are present.
    if (_receivedChunks[chunkId]!.length == totalChunks) {
      final builder = BytesBuilder();
      for (int i = 1; i <= totalChunks; i++) {
        builder.add(_chunkData[chunkId]![i]!);
      }
      final complete = builder.toBytes();

      // Clean up before returning.
      _cleanupChunkId(chunkId);

      return complete;
    }

    return null;
  }

  /// Remove stale buffers that have exceeded timeouts.
  ///
  /// Call periodically (e.g. on each incoming frame) to prevent memory leaks
  /// from abandoned chunk transfers.
  void cleanupStaleBuffers() {
    final now = DateTime.now();
    final staleIds = <int>[];

    for (final chunkId in _chunkStartTimes.keys) {
      final age = now.difference(_chunkStartTimes[chunkId]!);
      if (age > _chunkTimeout) {
        staleIds.add(chunkId);
        continue;
      }

      if (_chunkLastReceived.containsKey(chunkId)) {
        final idle = now.difference(_chunkLastReceived[chunkId]!);
        if (idle > _chunkStaleTimeout) {
          staleIds.add(chunkId);
        }
      }
    }

    for (final id in staleIds) {
      _cleanupChunkId(id);
    }
  }

  /// Release all resources.
  void dispose() {
    _chunkData.clear();
    _expectedChunks.clear();
    _receivedChunks.clear();
    _chunkStartTimes.clear();
    _chunkLastReceived.clear();
  }

  // ---- Private helpers ----

  void _cleanupChunkId(int chunkId) {
    _chunkData.remove(chunkId);
    _expectedChunks.remove(chunkId);
    _receivedChunks.remove(chunkId);
    _chunkStartTimes.remove(chunkId);
    _chunkLastReceived.remove(chunkId);
  }
}
