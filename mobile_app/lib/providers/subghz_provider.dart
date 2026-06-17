import 'dart:async';
import 'package:flutter/foundation.dart';
import '../connection/message_dispatcher.dart';
import '../models/detected_signal.dart';
import '../services/logger_service.dart';
import 'firmware_protocol.dart';

/// Sub-GHz signal provider (CC1101).
///
/// Extracted from [BleProvider]: handles recording, scanning, jamming, and
/// signal transmission over the CC1101 modules. Subscribes to
/// [MessageDispatcher.messages].
class SubGhzProvider extends ChangeNotifier {
  final MessageDispatcher _messageDispatcher;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Callback set by owner to send a raw binary command to the device.
  Future<bool> Function(Uint8List)? sendCommand;

  /// Callback for user-facing notifications.
  void Function(String level, String message)? notify;

  SubGhzProvider(this._messageDispatcher) {
    _subscription = _messageDispatcher.messages.listen(_dispatch);
  }

  // ══════════════════════════════════════════════════════════════
  //  State fields
  // ══════════════════════════════════════════════════════════════

  Map<int, bool> isRecording = {0: false, 1: false};
  Map<int, bool> isFrequencySearching = {0: false, 1: false};
  Map<int, bool> isJamming = {0: false, 1: false};
  List<DetectedSignal> detectedSignals = [];
  Map<String, double> frequencySpectrum = {};
  int selectedModule = 0;
  int rssiThreshold = -100;

  List<Map<String, dynamic>> recordedRuntimeFiles = [];

  // ══════════════════════════════════════════════════════════════
  //  Dispatch
  // ══════════════════════════════════════════════════════════════

  void _dispatch(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'SignalDetected':
        _handleSignalDetected(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'SignalRecorded':
        _handleSignalRecorded(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'SignalRecordError':
        _handleSignalRecordError();
        break;
      case 'SignalSent':
        _handleSignalSent();
        break;
      case 'SignalSendingError':
        _handleSignalSendingError(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'ModeSwitch':
        _handleModeSwitch(msg['data'] as Map<String, dynamic>? ?? {});
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers
  // ══════════════════════════════════════════════════════════════

  void _handleSignalDetected(Map<String, dynamic> data) {
    AppLogger.debug('Signal detected: $data');
    if (!data.containsKey('module')) return;

    detectedSignals.add(DetectedSignal.fromJson({
      ...data,
      'timestamp': DateTime.now(),
    }));

    // Keep list manageable
    if (detectedSignals.length > 100) {
      detectedSignals = detectedSignals.sublist(detectedSignals.length - 100);
    }

    notifyListeners();
  }

  void _handleSignalRecorded(Map<String, dynamic> data) {
    AppLogger.debug('Signal recorded: $data');
    String? filename;
    if (data['filename'] != null) {
      filename = data['filename'];
    }

    if (filename != null) {
      recordedRuntimeFiles.insert(0, {
        'filename': filename,
        'date': DateTime.now().toIso8601String(),
        'type': 'recorded',
      });
      if (recordedRuntimeFiles.length > 50) {
        recordedRuntimeFiles = recordedRuntimeFiles.take(50).toList();
      }
      notify?.call('success', 'Signal recorded: $filename');
    }
    notifyListeners();
  }

  void _handleSignalRecordError() {
    AppLogger.debug('Signal record error');
    notify?.call('error', 'Record error');
    notifyListeners();
  }

  void _handleSignalSent() {
    AppLogger.debug('Signal sent');
    notify?.call('success', 'Signal transmitted');
    notifyListeners();
  }

  void _handleSignalSendingError(Map<String, dynamic> data) {
    String errorMessage = 'Transmission failed';
    if (data['error'] != null) {
      errorMessage = 'Transmission failed: ${data['error']}';
      if (data['filename'] != null) {
        errorMessage += ': ${data['filename']}';
      }
    }
    notify?.call('error', errorMessage);
    notifyListeners();
  }

  void _handleModeSwitch(Map<String, dynamic> modeData) {
    final module = int.tryParse('${modeData['module']}') ?? 0;
    final mode = modeData['mode'] as String? ?? 'Unknown';
    final previousMode = modeData['previousMode'] as String? ?? 'Unknown';

    if (mode == 'RecordSignal') {
      isRecording[module] = true;
    } else if (mode == 'Idle') {
      isRecording[module] = false;
    }

    if (mode == 'Jamming') {
      isJamming[module] = true;
    } else if (mode == 'Idle' && previousMode == 'Jamming') {
      isJamming[module] = false;
    }

    if (mode == 'DetectSignal') {
      isFrequencySearching[module] = true;
    } else if (mode == 'Idle' && previousMode == 'DetectSignal') {
      isFrequencySearching[module] = false;
    } else if (mode == 'Idle') {
      isFrequencySearching[module] = false;
    }

    notifyListeners();
  }

  /// Remove file from local recorded files list.
  void removeRecordedFile(String filename) {
    recordedRuntimeFiles.removeWhere((file) => file['filename'] == filename);
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands
  // ══════════════════════════════════════════════════════════════

  Future<void> sendRecordCommand({
    required double frequency,
    required int module,
    String? preset,
    int? modulation,
    double? deviation,
    double? rxBandwidth,
    double? dataRate,
  }) async {
    final cmd = FirmwareBinaryProtocol.createRequestRecordCommand(
      frequency: frequency,
      module: module,
      preset: preset,
      modulation: modulation,
      deviation: deviation,
      rxBandwidth: rxBandwidth,
      dataRate: dataRate,
    );
    await sendCommand?.call(cmd);
  }

  Future<void> sendIdleCommand(int module) async {
    final cmd = FirmwareBinaryProtocol.createRequestIdleCommand(module);
    await sendCommand?.call(cmd);
  }

  Future<void> sendTransmitCommand({
    required double frequency,
    required String data,
    int pulseDuration = 100,
  }) async {
    final cmd = FirmwareBinaryProtocol.createTransmitBinaryCommand(
      frequency,
      pulseDuration,
      data,
    );
    await sendCommand?.call(cmd);
  }

  Future<void> sendStartJamCommand({
    required int module,
    required double frequency,
    int power = 7,
    int patternType = 0,
    int maxDurationMs = 60000,
    int cooldownMs = 5000,
    List<int>? customPattern,
  }) async {
    final cmd = FirmwareBinaryProtocol.createStartJamCommand(
      module: module,
      frequency: frequency,
      power: power,
      patternType: patternType,
      maxDurationMs: maxDurationMs,
      cooldownMs: cooldownMs,
      customPattern: customPattern,
    );
    await sendCommand?.call(cmd);
  }

  Future<void> startFrequencySearch(int module, int minRssi) async {
    final cmd =
        FirmwareBinaryProtocol.createRequestScanCommand(minRssi, module);
    await sendCommand?.call(cmd);
  }

  Future<void> sendTransmitFromFile(String path) async {
    final cmd = FirmwareBinaryProtocol.createTransmitFromFileCommand(path);
    await sendCommand?.call(cmd);
  }

  Future<void> sendSetTimeCommand() async {
    final cmd = FirmwareBinaryProtocol.createSetTimeCommand(DateTime.now());
    await sendCommand?.call(cmd);
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
