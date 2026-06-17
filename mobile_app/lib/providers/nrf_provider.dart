import 'dart:async';
import 'package:flutter/foundation.dart';
import '../connection/message_dispatcher.dart';
import '../models/protopirate_result.dart';
import 'firmware_protocol.dart';

/// NRF24 provider — handles MouseJack scanning, spectrum analysis, jamming,
/// and ProtoPirate (automotive key fob decoding/emulation).
///
/// ProtoPirate is kept in this provider (not split out) because it shares
/// the NRF24 hardware module and SPI bus.
///
/// Subscribes to [MessageDispatcher.messages].
class NrfProvider extends ChangeNotifier {
  final MessageDispatcher _messageDispatcher;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Callback set by owner to send a raw binary command.
  Future<bool> Function(Uint8List)? sendCommand;

  /// Callback for user-facing notifications.
  void Function(String level, String message)? notify;

  NrfProvider(this._messageDispatcher) {
    _subscription = _messageDispatcher.messages.listen(_dispatch);
  }

  // ══════════════════════════════════════════════════════════════
  //  State fields — NRF
  // ══════════════════════════════════════════════════════════════

  bool nrfInitialized = false;
  bool nrfScanning = false;
  bool nrfAttacking = false;
  bool nrfSpectrumRunning = false;
  bool nrfJammerRunning = false;
  int nrfJamMode = 0;
  int nrfJamChannel = 0;
  int nrfJamDwellTimeMs = 0;
  List<Map<String, dynamic>> nrfTargets = [];
  List<int> nrfSpectrumLevels = List.filled(126, 0);
  Map<int, Map<String, dynamic>> nrfJamModeConfigs = {};
  Map<int, Map<String, dynamic>> nrfJamModeInfos = {};

  Completer<bool>? _nrfInitResult;

  Future<bool> awaitNrfInitResult() {
    _nrfInitResult = Completer<bool>();
    return _nrfInitResult!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => false,
    );
  }

  void resolveNrfInitResult(bool present) {
    _nrfInitResult?.complete(present);
    _nrfInitResult = null;
  }

  // ══════════════════════════════════════════════════════════════
  //  State fields — ProtoPirate
  // ══════════════════════════════════════════════════════════════

  bool ppDecoding = false;
  List<ProtoPirateResult> ppResults = [];
  List<Map<String, dynamic>> ppHistory = [];
  Map<String, dynamic>? ppStatus;
  int ppHistoryCount = 0;
  bool ppTranismitting = false;
  List<Map<String, dynamic>> ppFileList = [];
  bool ppFileListReceived = false;
  int ppModule = -1;
  int ppSignalCount = 0;
  int ppTxState = 0;
  int ppTxErrorCode = 0;

  // ══════════════════════════════════════════════════════════════
  //  Dispatch
  // ══════════════════════════════════════════════════════════════

  void _dispatch(Map<String, dynamic> msg) {
    switch (msg['type'] as String?) {
      case 'NrfModuleStatus':
        _handleNrfModuleStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfDeviceFound':
        _handleNrfDeviceFound(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfAttackComplete':
        _handleNrfAttackComplete();
        break;
      case 'NrfScanComplete':
        _handleNrfScanComplete();
        break;
      case 'NrfScanStatus':
        _handleNrfScanStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfSpectrumData':
        _handleNrfSpectrumData(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfJamStatus':
        _handleNrfJamStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfJamModeConfig':
        _handleNrfJamModeConfig(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'NrfJamModeInfo':
        _handleNrfJamModeInfo(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      // ProtoPirate
      case 'PPDecodeResult':
        _handlePPDecodeResult(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'PPHistoryEntry':
        _handlePPHistoryEntry(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'PPStatus':
        _handlePPStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'PPHistoryCount':
        _handlePPHistoryCount(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'PPFileList':
        _handlePPFileList(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'PPTxStatus':
        _handlePPTxStatus(msg['data'] as Map<String, dynamic>? ?? {});
        break;
      case 'PPSaveResult':
        _handlePPSaveResult(msg['data'] as Map<String, dynamic>? ?? {});
        break;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers — NRF
  // ══════════════════════════════════════════════════════════════

  void _handleNrfModuleStatus(Map<String, dynamic> data) {
    final present = data['present'] == true || data['present'] == 1;
    resolveNrfInitResult(present);
    if (present) {
      nrfInitialized = true;
    }
    notifyListeners();
  }

  void _handleNrfDeviceFound(Map<String, dynamic> data) {
    nrfTargets.add({
      'deviceType': data['deviceType'] ?? 0,
      'channel': data['channel'] ?? 0,
      'address': data['address'] ?? [],
    });
    notifyListeners();
  }

  void _handleNrfAttackComplete() {
    nrfAttacking = false;
    notify?.call('info', 'NRF attack finished');
    notifyListeners();
  }

  void _handleNrfScanComplete() {
    nrfScanning = false;
    notify?.call('info', 'MouseJack scan finished');
    notifyListeners();
  }

  void _handleNrfScanStatus(Map<String, dynamic> data) {
    if (data['targets'] is List) {
      nrfTargets = List<Map<String, dynamic>>.from(data['targets']);
    }
    notifyListeners();
  }

  void _handleNrfSpectrumData(Map<String, dynamic> data) {
    if (data['levels'] is List) {
      nrfSpectrumLevels = List<int>.from(data['levels']);
    }
    notifyListeners();
  }

  void _handleNrfJamStatus(Map<String, dynamic> data) {
    nrfJammerRunning = data['running'] == true;
    nrfJamMode = data['mode'] ?? 0;
    nrfJamDwellTimeMs = data['dwellTimeMs'] ?? 0;
    nrfJamChannel = data['channel'] ?? 0;
    notifyListeners();
  }

  void _handleNrfJamModeConfig(Map<String, dynamic> data) {
    final mode = data['mode'] ?? 0;
    nrfJamModeConfigs[mode] = data;
    notifyListeners();
  }

  void _handleNrfJamModeInfo(Map<String, dynamic> data) {
    final mode = data['mode'] ?? 0;
    nrfJamModeInfos[mode] = data;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Handlers — ProtoPirate
  // ══════════════════════════════════════════════════════════════

  void _handlePPDecodeResult(Map<String, dynamic> data) {
    ppResults.add(ProtoPirateResult.fromMap(data));
    if (ppResults.length > 100) {
      ppResults = ppResults.sublist(ppResults.length - 100);
    }
    notifyListeners();
  }

  void _handlePPHistoryEntry(Map<String, dynamic> data) {
    ppHistory.add(data);
    notifyListeners();
  }

  void _handlePPStatus(Map<String, dynamic> data) {
    ppStatus = data;
    ppDecoding = data['state'] == 'decoding' || data['state'] == 1;
    ppModule = data['module'] ?? -1;
    ppSignalCount = data['signalCount'] ?? 0;
    notifyListeners();
  }

  void _handlePPHistoryCount(Map<String, dynamic> data) {
    ppHistoryCount = data['count'] ?? 0;
    notifyListeners();
  }

  void _handlePPFileList(Map<String, dynamic> data) {
    if (data['files'] is List) {
      ppFileList = List<Map<String, dynamic>>.from(data['files']);
    }
    ppFileListReceived = true;
    notifyListeners();
  }

  void _handlePPTxStatus(Map<String, dynamic> data) {
    ppTranismitting = data['state'] == 'tx' || data['state'] == 1;
    notifyListeners();
  }

  void _handlePPSaveResult(Map<String, dynamic> data) {
    notify?.call(
        data['success'] == true ? 'success' : 'error',
        data['success'] == true
            ? 'ProtoPirate saved'
            : 'ProtoPirate save failed');
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands — NRF
  // ══════════════════════════════════════════════════════════════

  Future<void> initNrf() async {
    final cmd = FirmwareBinaryProtocol.createNrfInitCommand();
    await sendCommand?.call(cmd);
  }

  Future<void> startScan() async {
    final cmd = FirmwareBinaryProtocol.createNrfScanStartCommand();
    await sendCommand?.call(cmd);
    nrfScanning = true;
    notifyListeners();
  }

  Future<void> stopScan() async {
    final cmd = FirmwareBinaryProtocol.createNrfScanStopCommand();
    await sendCommand?.call(cmd);
    nrfScanning = false;
    notifyListeners();
  }

  Future<void> attackString(int targetIndex, String text) async {
    final cmd =
        FirmwareBinaryProtocol.createNrfAttackStringCommand(targetIndex, text);
    await sendCommand?.call(cmd);
    nrfAttacking = true;
    notifyListeners();
  }

  Future<void> attackDucky(int targetIndex, String path) async {
    final cmd =
        FirmwareBinaryProtocol.createNrfAttackDuckyCommand(targetIndex, path);
    await sendCommand?.call(cmd);
    nrfAttacking = true;
    notifyListeners();
  }

  Future<void> stopAttack() async {
    final cmd = FirmwareBinaryProtocol.createNrfAttackStopCommand();
    await sendCommand?.call(cmd);
    nrfAttacking = false;
    notifyListeners();
  }

  Future<void> requestScanStatus() async {
    final cmd = FirmwareBinaryProtocol.createNrfScanStatusCommand();
    await sendCommand?.call(cmd);
  }

  Future<void> startSpectrum() async {
    final cmd = FirmwareBinaryProtocol.createNrfSpectrumStartCommand();
    await sendCommand?.call(cmd);
    nrfSpectrumRunning = true;
    notifyListeners();
  }

  Future<void> stopSpectrum() async {
    final cmd = FirmwareBinaryProtocol.createNrfSpectrumStopCommand();
    await sendCommand?.call(cmd);
    nrfSpectrumRunning = false;
    nrfSpectrumLevels = List.filled(126, 0);
    notifyListeners();
  }

  Future<void> startJammer(int mode,
      {int channel = 50,
      int hopStart = 0,
      int hopStop = 80,
      int hopStep = 2}) async {
    final cmd = FirmwareBinaryProtocol.createNrfJamStartCommand(mode,
        channel: channel,
        hopStart: hopStart,
        hopStop: hopStop,
        hopStep: hopStep);
    await sendCommand?.call(cmd);
    nrfJammerRunning = true;
    notifyListeners();
  }

  Future<void> stopJammer() async {
    final cmd = FirmwareBinaryProtocol.createNrfJamStopCommand();
    await sendCommand?.call(cmd);
    nrfJammerRunning = false;
    notifyListeners();
  }

  Future<void> setJamDwellTime(int ms) async {
    final cmd = FirmwareBinaryProtocol.createNrfJamSetDwellCommand(ms);
    await sendCommand?.call(cmd);
  }

  Future<void> stopAll() async {
    final cmd = FirmwareBinaryProtocol.createNrfStopAllCommand();
    await sendCommand?.call(cmd);
    nrfScanning = false;
    nrfAttacking = false;
    nrfSpectrumRunning = false;
    nrfJammerRunning = false;
    notifyListeners();
  }

  Future<void> requestJamModeConfig(int mode) async {
    final cmd = FirmwareBinaryProtocol.createNrfJamModeConfigGetCommand(mode);
    await sendCommand?.call(cmd);
  }

  Future<void> requestJamModeInfo(int mode) async {
    final cmd = FirmwareBinaryProtocol.createNrfJamModeInfoCommand(mode);
    await sendCommand?.call(cmd);
  }

  /// Stop all NRF operations on connection loss.
  void onConnectionLost() {
    nrfScanning = false;
    nrfAttacking = false;
    nrfSpectrumRunning = false;
    nrfJammerRunning = false;
    nrfInitialized = false;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Commands — ProtoPirate
  // ══════════════════════════════════════════════════════════════

  Future<void> ppStartDecode(int module, double frequencyMhz) async {
    final cmd =
        FirmwareBinaryProtocol.createPPStartDecodeCommand(module, frequencyMhz);
    await sendCommand?.call(cmd);
    ppDecoding = true;
    notifyListeners();
  }

  Future<void> ppStopDecode() async {
    final cmd = FirmwareBinaryProtocol.createPPStopDecodeCommand();
    await sendCommand?.call(cmd);
    ppDecoding = false;
    notifyListeners();
  }

  /// List .sub files on the SD card at the given path.
  Future<void> ppListSubFiles([String path = '/']) async {
    ppFileList = [];
    ppFileListReceived = false;
    final cmd = FirmwareBinaryProtocol.createPPListSubFilesCommand(path);
    await sendCommand?.call(cmd);
    notifyListeners();
  }

  /// List saved captures on the SD card.
  Future<void> ppListSaved() async {
    ppFileList = [];
    ppFileListReceived = false;
    final cmd = FirmwareBinaryProtocol.createPPListSavedCommand();
    await sendCommand?.call(cmd);
    notifyListeners();
  }

  /// Save a decoded capture to SD card (/DATA/PROTOPIRATE/).
  Future<void> ppSaveCapture(ProtoPirateResult result) async {
    final cmd = FirmwareBinaryProtocol.createPPSaveCaptureCommand(
      protocolName: result.protocolName,
      data: result.data,
      data2: result.data2,
      serial: result.serial,
      button: result.button,
      counter: result.counter,
      dataBits: result.dataBits,
      frequencyMhz: result.frequency,
    );
    await sendCommand?.call(cmd);
  }

  /// Clear local PP results list.
  void ppClearResults() {
    ppResults.clear();
    notifyListeners();
  }

  /// Load a .sub file and feed it to PP decoders (diagnostic).
  Future<void> ppLoadSubFile(String filePath) async {
    final cmd = FirmwareBinaryProtocol.createPPLoadSubFileCommand(filePath);
    await sendCommand?.call(cmd);
  }

  /// Emulate (TX) a decoded ProtoPirate signal.
  Future<void> ppEmulate(ProtoPirateResult result,
      {int module = 0, int repeat = 3}) async {
    ppTxState = 0;
    ppTxErrorCode = 0;
    final cmd = FirmwareBinaryProtocol.createPPEmulateCommand(
      module: module,
      repeat: repeat,
      protocolName: result.protocolName,
      data: result.data,
      data2: result.data2,
      serial: result.serial,
      button: result.button,
      counter: result.counter,
      dataBits: result.dataBits,
      frequencyMhz: result.frequency,
    );
    await sendCommand?.call(cmd);
    notifyListeners();
  }

  /// Reset all ProtoPirate state (called on disconnect).
  void resetPPState() {
    ppDecoding = false;
    ppModule = -1;
    ppResults.clear();
    ppHistoryCount = 0;
    ppSignalCount = 0;
    ppTxState = 0;
    ppTxErrorCode = 0;
    ppFileList = [];
    ppFileListReceived = false;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════
  //  Lifecycle
  // ══════════════════════════════════════════════════════════════

  /// Trigger UI rebuild after NRF state fields are modified externally.
  void nrfNotify() => notifyListeners();

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
