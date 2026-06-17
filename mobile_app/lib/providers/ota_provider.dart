import 'dart:async';
import 'package:flutter/foundation.dart';
import '../connection/message_dispatcher.dart';
import 'firmware_protocol.dart';

/// OTA (Over-The-Air) firmware update provider.
///
/// Uses a proper state machine instead of scattered booleans.
///
/// State machine:
/// ```
/// IDLE → UPLOADING → REBOOTING → WAITING_RECONNECT → COMPLETE
///                                                      → ERROR
/// ```
///
/// Subscribes to [MessageDispatcher.messages].
class OtaProvider extends ChangeNotifier {
  final MessageDispatcher _messageDispatcher;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Callback set by owner to send a raw binary command.
  Future<bool> Function(Uint8List)? sendCommand;

  /// Callback for user-facing notifications.
  void Function(String level, String message)? notify;

  OtaProvider(this._messageDispatcher) {
    _subscription = _messageDispatcher.messages.listen(_dispatch);
  }

  // ══════════════════════════════════════════════════════════════
  //  State machine
  // ══════════════════════════════════════════════════════════════

  OtaState _state = OtaState.idle;
  OtaState get state => _state;

  /// Progress percentage (0-100).
  int otaProgress = 0;

  /// Bytes written so far.
  int otaBytesWritten = 0;

  /// Error message, if any.
  String? otaErrorMessage;

  /// The firmware version before OTA reboot (for verification).
  String? preRebootVersion;

  /// Timer for reconnection after reboot.
  Timer? _reconnectTimer;

  /// Called by the connection provider when a reconnect is detected,
  /// to verify the firmware version changed.
  void Function()? onReconnectForVerification;

  // ══════════════════════════════════════════════════════════════
  //  Dispatch
  // ══════════════════════════════════════════════════════════════

  void _dispatch(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'OtaProgress':
        _handleOtaProgress(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'OtaComplete':
        _handleOtaComplete();
        break;
      case 'OtaError':
        _handleOtaError(msg['data'] as Map<String, dynamic>? ?? {});
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers
  // ══════════════════════════════════════════════════════════════

  void _handleOtaProgress(Map<String, dynamic> data) {
    if (_state == OtaState.idle) transition(OtaState.uploading);
    otaProgress = data['percentage'] ?? otaProgress;
    otaBytesWritten = data['bytesWritten'] ?? otaBytesWritten;
    notifyListeners();
  }

  void _handleOtaComplete() {
    transition(OtaState.complete);
    notify?.call('success', 'Firmware update complete!');
    notifyListeners();
  }

  void _handleOtaError(Map<String, dynamic> data) {
    otaErrorMessage = data['message'] ?? 'Unknown error';
    transition(OtaState.error);
    notify?.call('error', 'OTA error: $otaErrorMessage');
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands
  // ══════════════════════════════════════════════════════════════

  /// Start uploading a firmware file.
  Future<void> uploadFile(int firmwareSize, String md5) async {
    if (sendCommand == null) return;
    final cmd = FirmwareBinaryProtocol.createOtaBeginCommand(firmwareSize, md5);
    await sendCommand!(cmd);
    transition(OtaState.uploading);
    otaProgress = 0;
    otaBytesWritten = 0;
    otaErrorMessage = null;
    notifyListeners();
  }

  /// Upload firmware from byte array (chunked upload).
  Future<void> uploadFileFromBytes(Uint8List data) async {
    if (sendCommand == null) return;
    transition(OtaState.uploading);
    otaProgress = 0;
    otaBytesWritten = 0;
    otaErrorMessage = null;
    notifyListeners();

    const chunkSize = 500;
    final totalChunks = (data.length + chunkSize - 1) ~/ chunkSize;

    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end =
          (start + chunkSize > data.length) ? data.length : start + chunkSize;
      final chunk = data.sublist(start, end);

      final cmd = FirmwareBinaryProtocol.createOtaDataCommand(chunk);
      await sendCommand!(cmd);

      otaProgress = ((i + 1) / totalChunks * 100).round();
      otaBytesWritten = end;
      notifyListeners();
    }

    // Send end marker
    final endCmd = FirmwareBinaryProtocol.createOtaEndCommand();
    await sendCommand!(endCmd);
  }

  /// Notify the system that an OTA reboot is pending.
  /// Saves the current firmware version for post-reboot verification.
  void notifyOtaReboot(String currentVersion) {
    preRebootVersion = currentVersion;
    transition(OtaState.rebooting);
    notifyListeners();
  }

  /// Schedule reconnection attempt after reboot.
  void scheduleReconnect(Duration delay, void Function() reconnectAction) {
    _reconnectTimer?.cancel();
    transition(OtaState.waitingReconnect);
    notifyListeners();

    _reconnectTimer = Timer(delay, () {
      transition(OtaState.awaitingVerify);
      notifyListeners();
      reconnectAction();
    });
  }

  /// Mark firmware version as verified (called after reconnect detects new version).
  void markVerified() {
    preRebootVersion = null;
    _reconnectTimer?.cancel();
    notifyListeners();
  }

  /// Reset to idle (on connection loss or explicit cancel).
  void reset() {
    _reconnectTimer?.cancel();
    preRebootVersion = null;
    otaProgress = 0;
    otaBytesWritten = 0;
    otaErrorMessage = null;
    transition(OtaState.idle);
  }

  // ══════════════════════════════════════════════════════════════
  //  State machine helpers
  // ══════════════════════════════════════════════════════════════

  void transition(OtaState newState) {
    _state = newState;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Lifecycle
  // ══════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _subscription?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}

/// OTA state machine states.
enum OtaState {
  /// No update in progress.
  idle,

  /// Firmware binary is being uploaded in chunks.
  uploading,

  /// Upload complete, device is rebooting.
  rebooting,

  /// Waiting for device to come back online.
  waitingReconnect,

  /// Reconnected, waiting for version verification.
  awaitingVerify,

  /// Update completed successfully.
  complete,

  /// An error occurred during the update.
  error,
}
