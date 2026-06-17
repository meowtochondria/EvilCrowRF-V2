import 'dart:async';
import 'package:flutter/foundation.dart';
import '../connection/message_dispatcher.dart';
import 'firmware_protocol.dart';

/// Brute-force attack provider.
///
/// Extracted from [BleProvider]: handles protocol brute-force attacks
/// (rolling codes, fixed codes, De Bruijn sequences).
/// Subscribes to [MessageDispatcher.messages].
class BruterProvider extends ChangeNotifier {
  final MessageDispatcher _messageDispatcher;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Callback set by owner to send a raw binary command to the device.
  Future<bool> Function(Uint8List)? sendCommand;

  /// Callback for user-facing notifications.
  void Function(String level, String message)? notify;

  BruterProvider(this._messageDispatcher) {
    _subscription = _messageDispatcher.messages.listen(_dispatch);
  }

  // ══════════════════════════════════════════════════════════════
  //  State fields
  // ══════════════════════════════════════════════════════════════

  bool _isBruterRunning = false;
  bool get isBruterRunning => _isBruterRunning;

  int _bruterActiveProtocol = 0;
  int get bruterActiveProtocol => _bruterActiveProtocol;

  int _bruterCurrentCode = 0;
  int get bruterCurrentCode => _bruterCurrentCode;
  int _bruterTotalCodes = 0;
  int get bruterTotalCodes => _bruterTotalCodes;
  int _bruterPercentage = 0;
  int get bruterPercentage => _bruterPercentage;
  int _bruterCodesPerSec = 0;
  int get bruterCodesPerSec => _bruterCodesPerSec;

  int _bruterDelayMs = 10;
  int get bruterDelayMs => _bruterDelayMs;
  int _bruterPower = 7;
  int get bruterPower => _bruterPower;
  int _bruterRepeats = 4;
  int get bruterRepeats => _bruterRepeats;

  bool _bruterSavedStateAvailable = false;
  bool get bruterSavedStateAvailable => _bruterSavedStateAvailable;
  int _bruterSavedMenuId = 0;
  int get bruterSavedMenuId => _bruterSavedMenuId;
  int _bruterSavedCurrentCode = 0;
  int get bruterSavedCurrentCode => _bruterSavedCurrentCode;
  int _bruterSavedTotalCodes = 0;
  int get bruterSavedTotalCodes => _bruterSavedTotalCodes;
  int _bruterSavedPercentage = 0;
  int get bruterSavedPercentage => _bruterSavedPercentage;

  int _lastBruterCompletionStatus = -1;
  int get lastBruterCompletionStatus => _lastBruterCompletionStatus;
  int _lastBruterCompletionMenuId = 0;
  int get lastBruterCompletionMenuId => _lastBruterCompletionMenuId;

  // ══════════════════════════════════════════════════════════════
  //  Dispatch
  // ══════════════════════════════════════════════════════════════

  void _dispatch(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'BruterProgress':
        _handleBruterProgress(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'BruterComplete':
        _handleBruterComplete(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'BruterPaused':
        _handleBruterPaused(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'BruterResumed':
        _handleBruterResumed(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'BruterStateAvail':
        _handleBruterStateAvail(msg['data'] as Map<String, dynamic>? ?? {});
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers
  // ══════════════════════════════════════════════════════════════

  void _handleBruterProgress(Map<String, dynamic> data) {
    _bruterCurrentCode = data['currentCode'] ?? 0;
    _bruterTotalCodes = data['totalCodes'] ?? 0;
    _bruterPercentage = data['percentage'] ?? 0;
    _bruterCodesPerSec = data['codesPerSec'] ?? 0;
    final menuId = data['menuId'] ?? 0;

    if (menuId > 0 && !_isBruterRunning && !_bruterSavedStateAvailable) {
      _isBruterRunning = true;
      _bruterActiveProtocol = menuId;
    }

    notifyListeners();
  }

  void _handleBruterComplete(Map<String, dynamic> data) {
    final menuId = data['menuId'] ?? 0;
    final status = data['status'] ?? 0;
    final totalSent = data['totalSent'] ?? 0;

    final statusStr =
        status == 0 ? 'completed' : (status == 1 ? 'cancelled' : 'error');

    _isBruterRunning = false;
    _bruterActiveProtocol = 0;
    _bruterPercentage = status == 0 ? 100 : _bruterPercentage;
    _bruterCodesPerSec = 0;

    _lastBruterCompletionStatus = status;
    _lastBruterCompletionMenuId = menuId;

    notify?.call(status == 0 ? 'success' : 'warning',
        'Bruter $statusStr ($totalSent codes)');
    notifyListeners();
  }

  void _handleBruterPaused(Map<String, dynamic> data) {
    final menuId = data['menuId'] ?? 0;
    final currentCode = data['currentCode'] ?? 0;
    final totalCodes = data['totalCodes'] ?? 0;
    final percentage = data['percentage'] ?? 0;

    _isBruterRunning = false;
    _bruterActiveProtocol = 0;
    _bruterCodesPerSec = 0;

    _bruterSavedStateAvailable = true;
    _bruterSavedMenuId = menuId;
    _bruterSavedCurrentCode = currentCode;
    _bruterSavedTotalCodes = totalCodes;
    _bruterSavedPercentage = percentage;

    notifyListeners();
  }

  void _handleBruterResumed(Map<String, dynamic> data) {
    final menuId = data['menuId'] ?? 0;

    _isBruterRunning = true;
    _bruterActiveProtocol = menuId;
    _bruterSavedStateAvailable = false;

    notifyListeners();
  }

  void _handleBruterStateAvail(Map<String, dynamic> data) {
    final menuId = data['menuId'] ?? 0;
    final currentCode = data['currentCode'] ?? 0;
    final totalCodes = data['totalCodes'] ?? 0;
    final percentage = data['percentage'] ?? 0;

    _bruterSavedStateAvailable = true;
    _bruterSavedMenuId = menuId;
    _bruterSavedCurrentCode = currentCode;
    _bruterSavedTotalCodes = totalCodes;
    _bruterSavedPercentage = percentage;

    notifyListeners();
  }

  /// Clear completion notification (called by UI after displaying).
  void clearBruterCompletion() {
    _lastBruterCompletionStatus = -1;
    _lastBruterCompletionMenuId = 0;
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands
  // ══════════════════════════════════════════════════════════════

  Future<void> sendBruterCommand(int menuChoice) async {
    final cmd = FirmwareBinaryProtocol.createBruterCommand(menuChoice);
    await sendCommand?.call(cmd);
    _isBruterRunning = true;
    _bruterActiveProtocol = menuChoice;
    notifyListeners();
  }

  Future<void> sendBruterCancelCommand() async {
    final cmd = FirmwareBinaryProtocol.createBruterCancelCommand();
    await sendCommand?.call(cmd);
    _isBruterRunning = false;
    _bruterActiveProtocol = 0;
    _bruterSavedStateAvailable = false;
    notifyListeners();
  }

  Future<void> sendBruterPauseCommand() async {
    final cmd = FirmwareBinaryProtocol.createBruterPauseCommand();
    await sendCommand?.call(cmd);
  }

  Future<void> sendBruterResumeCommand() async {
    final cmd = FirmwareBinaryProtocol.createBruterResumeCommand();
    await sendCommand?.call(cmd);
    _isBruterRunning = true;
    _bruterActiveProtocol = _bruterSavedMenuId;
    _bruterSavedStateAvailable = false;
    notifyListeners();
  }

  Future<void> queryBruterSavedState() async {
    final cmd = FirmwareBinaryProtocol.createBruterQueryStateCommand();
    await sendCommand?.call(cmd);
  }

  Future<void> setBruterDelay(int delayMs) async {
    _bruterDelayMs = delayMs.clamp(1, 1000);
    final cmd =
        FirmwareBinaryProtocol.createBruterSetDelayCommand(_bruterDelayMs);
    await sendCommand?.call(cmd);
    notifyListeners();
  }

  Future<void> setBruterModule(int power, int repeats) async {
    _bruterPower = power.clamp(0, 7);
    _bruterRepeats = repeats.clamp(1, 10);
    notifyListeners();
  }

  void _resetBruterState() {
    _isBruterRunning = false;
    _bruterActiveProtocol = 0;
    _bruterCurrentCode = 0;
    _bruterTotalCodes = 0;
    _bruterPercentage = 0;
    _bruterCodesPerSec = 0;
    _bruterSavedStateAvailable = false;
    _bruterSavedMenuId = 0;
    _bruterSavedCurrentCode = 0;
    _bruterSavedTotalCodes = 0;
    _bruterSavedPercentage = 0;
  }

  /// Reset state on connection loss.
  void onConnectionLost() {
    _resetBruterState();
    notifyListeners();
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
