import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/nrf_provider.dart';
import '../providers/device_info_provider.dart';
import '../providers/connection_state_provider.dart';
import '../providers/firmware_protocol.dart';
import '../models/nrf_jam_mode.dart';
import '../theme/app_colors.dart';

/// NRF target model for scanned devices
class NrfTarget {
  final String type;
  final int channel;
  final List<int> address;

  NrfTarget({required this.type, required this.channel, required this.address});

  String get addressHex => address
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');

  /// Convert device type code from firmware to human-readable string
  static String typeFromCode(int code) {
    switch (code) {
      case 1:
        return 'Microsoft';
      case 2:
        return 'MS Encrypted';
      case 3:
        return 'Logitech';
      default:
        return 'Unknown';
    }
  }
}

/// Full NRF24 screen with three tabs: MouseJack, Spectrum, Jammer.
class NrfScreen extends StatefulWidget {
  const NrfScreen({super.key});

  @override
  State<NrfScreen> createState() => _NrfScreenState();
}

class _NrfScreenState extends State<NrfScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _initializing = false;
  bool _initFailed = false;

  // Local UI state (not data)
  int _selectedTargetIndex = -1;
  final TextEditingController _stringController = TextEditingController();
  final TextEditingController _duckyPathController = TextEditingController();

  // Jammer UI controls (local until sent to firmware)
  int _jamMode = 0;
  int _jamChannel = 50;
  int _hopStart = 0;
  int _hopStop = 80;
  int _hopStep = 2;
  int _liveDwellMs = 0; // Live dwell slider value (0=turbo)

  // MouseJack filter
  bool _hideUnknown = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this, initialIndex: 1);
  }

  @override
  void dispose() {
    // Send NRF_STOP_ALL to firmware to cleanly release SPI bus
    // when user navigates away from NRF screen
    _cleanupNrf();
    _tabController.dispose();
    _stringController.dispose();
    _duckyPathController.dispose();
    super.dispose();
  }

  /// Stop all NRF tasks when leaving this screen so CC1101 (SubGhz)
  /// operations can resume without SPI bus contention.
  void _cleanupNrf() {
    try {
      final nrf = context.read<NrfProvider>();
      if (context.read<ConnectionStateProvider>().isConnected) {
        final cmd = FirmwareBinaryProtocol.createNrfStopAllCommand();
        nrf.sendCommand!(cmd);
      }
    } catch (_) {
      // Ignore errors during dispose — widget tree may be torn down
    }
  }

  // ── NRF Initialization ──────────────────────────────────────

  Future<void> _initNrf() async {
    final nrf = context.read<NrfProvider>();
    if (!context.read<ConnectionStateProvider>().isConnected) return;

    setState(() => _initializing = true);

    try {
      // Send the init command
      final cmd = FirmwareBinaryProtocol.createNrfInitCommand();
      await nrf.sendCommand!(cmd);

      // Wait for firmware to respond with MSG_NRF_STATUS (0xCA).
      // The firmware now sends this after init so the app learns the real
      // detection result (present=true/false).
      final present = await nrf.awaitNrfInitResult();

      if (present) {
        nrf.nrfInitialized = true;
        nrf.nrfNotify();
        setState(() => _initializing = false);
      } else {
        // Firmware responded: NRF24 chip is NOT present on the SPI bus
        setState(() {
          _initializing = false;
          _initFailed = true;
        });
      }
    } catch (e) {
      // BLE write failure or timeout
      setState(() {
        _initializing = false;
        _initFailed = true;
      });
    }
  }

  // ── MouseJack Commands ──────────────────────────────────────

  Future<void> _startScan() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfScanStartCommand();
    await nrf.sendCommand!(cmd);
    nrf.nrfScanning = true;
    nrf.nrfNotify();
  }

  Future<void> _stopScan() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfScanStopCommand();
    await nrf.sendCommand!(cmd);
    nrf.nrfScanning = false;
    nrf.nrfNotify();
  }

  Future<void> _attackString(int targetIndex) async {
    if (_stringController.text.isEmpty) return;
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfAttackStringCommand(
      targetIndex,
      _stringController.text,
    );
    await nrf.sendCommand!(cmd);
    nrf.nrfAttacking = true;
    nrf.nrfNotify();
  }

  Future<void> _attackDucky(int targetIndex) async {
    if (_duckyPathController.text.isEmpty) return;
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfAttackDuckyCommand(
      targetIndex,
      _duckyPathController.text,
    );
    await nrf.sendCommand!(cmd);
    nrf.nrfAttacking = true;
    nrf.nrfNotify();
  }

  Future<void> _stopAttack() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfAttackStopCommand();
    await nrf.sendCommand!(cmd);
    nrf.nrfAttacking = false;
    nrf.nrfNotify();
  }

  Future<void> _requestScanStatus() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfScanStatusCommand();
    await nrf.sendCommand!(cmd);
  }

  // ── Spectrum Commands ───────────────────────────────────────

  Future<void> _startSpectrum() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfSpectrumStartCommand();
    await nrf.sendCommand!(cmd);
    nrf.nrfSpectrumRunning = true;
    nrf.nrfNotify();
  }

  Future<void> _stopSpectrum() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfSpectrumStopCommand();
    await nrf.sendCommand!(cmd);
    nrf.nrfSpectrumRunning = false;
    nrf.nrfSpectrumLevels = List.filled(126, 0);
    nrf.nrfNotify();
  }

  // ── Jammer Commands ─────────────────────────────────────────

  Future<void> _startJammer() async {
    final nrf = context.read<NrfProvider>();
    Uint8List cmd;
    if (_jamMode == 8) {
      // Single channel mode
      cmd = FirmwareBinaryProtocol.createNrfJamStartCommand(_jamMode,
          channel: _jamChannel);
    } else if (_jamMode == 9) {
      // Custom hopper mode
      cmd = FirmwareBinaryProtocol.createNrfJamStartCommand(_jamMode,
          hopStart: _hopStart, hopStop: _hopStop, hopStep: _hopStep);
    } else {
      cmd = FirmwareBinaryProtocol.createNrfJamStartCommand(_jamMode);
    }
    await nrf.sendCommand!(cmd);
    nrf.nrfJammerRunning = true;
    nrf.nrfNotify();
    // Read current dwell from cached config for the live slider
    final cachedCfg = nrf.nrfJamModeConfigs[_jamMode];
    setState(() {
      _liveDwellMs = cachedCfg?['dwellTimeMs'] ?? 0;
    });
  }

  Future<void> _stopJammer() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfJamStopCommand();
    await nrf.sendCommand!(cmd);
    nrf.nrfJammerRunning = false;
    nrf.nrfNotify();
  }

  // ── Jammer Per-Mode Commands ────────────────────────────────

  Future<void> _setDwellTimeLive(int ms) async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfJamSetDwellCommand(ms);
    await nrf.sendCommand!(cmd);
  }

  Future<void> _requestModeConfig(int mode) async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfJamModeConfigGetCommand(mode);
    await nrf.sendCommand!(cmd);
  }

  Future<void> _setModeConfig(
      int mode, int pa, int dr, int dwell, bool flooding, int bursts) async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfJamModeConfigSetCommand(
        mode, pa, dr, dwell, flooding, bursts);
    await nrf.sendCommand!(cmd);
  }

  Future<void> _requestModeInfo(int mode) async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfJamModeInfoCommand(mode);
    await nrf.sendCommand!(cmd);
  }

  Future<void> _resetAllConfigs() async {
    final nrf = context.read<NrfProvider>();
    final cmd = FirmwareBinaryProtocol.createNrfJamResetConfigCommand();
    await nrf.sendCommand!(cmd);
    // Clear local cache so it gets refreshed
    nrf.nrfJamModeConfigs.clear();
    nrf.nrfNotify();
  }

  // ── Build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Consumer<NrfProvider>(
      builder: (context, nrf, _) {
        if (!context.read<ConnectionStateProvider>().isConnected) {
          return _buildNotConnected();
        }

        // If GetState already told us NRF24 hardware is absent (from a
        // previous init attempt that failed), show the not-detected screen.
        if (!nrf.nrfInitialized) {
          return _buildInitScreen(nrf: nrf);
        }
        return _buildMainScreen(nrf);
      },
    );
  }

  Widget _buildNotConnected() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bluetooth_disabled,
              size: 64, color: AppColors.disabledText),
          const SizedBox(height: 16),
          Text('Connect to device first',
              style: TextStyle(color: AppColors.secondaryText, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildInitScreen({NrfProvider? nrf}) {
    // Proactive message: GetState already told us NRF24 hardware is absent
    // (from a previous init attempt that set present=false).
    final bool knownNotPresent = nrf != null &&
        context.read<ConnectionStateProvider>().isConnected &&
        !context.read<DeviceInfoProvider>().nrfPresent;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.memory,
              size: 72,
              color: knownNotPresent
                  ? AppColors.disabledText
                  : AppColors.primaryAccent),
          const SizedBox(height: 24),
          Text('nRF24L01 Module',
              style: TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('MouseJack / Spectrum / Jammer',
              style: TextStyle(color: AppColors.secondaryText, fontSize: 14)),
          const SizedBox(height: 32),
          if (knownNotPresent && !_initFailed && !_initializing)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  border:
                      Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('nRF24L01 hardware absent on this device',
                    style: TextStyle(color: AppColors.error, fontSize: 13)),
              ),
            ),
          _initializing
              ? const CircularProgressIndicator(color: AppColors.primaryAccent)
              : ElevatedButton.icon(
                  onPressed: _initNrf,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Initialize NRF24'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryAccent,
                    foregroundColor: AppColors.primaryBackground,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 14),
                  ),
                ),
          if (_initFailed && !_initializing)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.1),
                  border:
                      Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('nRF24L01 module not detected',
                    style: TextStyle(color: AppColors.error, fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMainScreen(NrfProvider nrf) {
    return Column(
      children: [
        Container(
          color: AppColors.secondaryBackground,
          child: TabBar(
            controller: _tabController,
            indicatorColor: AppColors.primaryAccent,
            labelColor: AppColors.primaryAccent,
            unselectedLabelColor: AppColors.secondaryText,
            tabs: const [
              Tab(icon: Icon(Icons.search), text: 'MouseJack'),
              Tab(icon: Icon(Icons.graphic_eq), text: 'Spectrum'),
              Tab(icon: Icon(Icons.wifi_tethering), text: 'Jammer'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildMouseJackTab(nrf),
              _buildSpectrumTab(nrf),
              _buildJammerTab(nrf),
            ],
          ),
        ),
      ],
    );
  }

  // ── MouseJack Tab ───────────────────────────────────────────

  Widget _buildMouseJackTab(NrfProvider nrf) {
    final allTargets = nrf.nrfTargets;
    final targets = _hideUnknown
        ? allTargets.where((t) {
            final code = t['deviceType'] ?? 0;
            return NrfTarget.typeFromCode(code) != 'Unknown';
          }).toList()
        : allTargets;
    final isScanning = nrf.nrfScanning;
    final isAttacking = nrf.nrfAttacking;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scan controls
          _buildSectionCard(
            title: 'Scan',
            icon: Icons.radar,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: isScanning ? _stopScan : _startScan,
                        icon: Icon(isScanning ? Icons.stop : Icons.play_arrow),
                        label: Text(isScanning ? 'Stop Scan' : 'Start Scan'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isScanning
                              ? AppColors.error
                              : AppColors.primaryAccent,
                          foregroundColor: isScanning
                              ? AppColors.onButton
                              : AppColors.primaryBackground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _requestScanStatus,
                      icon: const Icon(Icons.refresh,
                          color: AppColors.primaryAccent),
                      tooltip: 'Refresh targets',
                    ),
                  ],
                ),
                // Hide Unknown toggle
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        height: 24,
                        width: 36,
                        child: Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: _hideUnknown,
                            onChanged: (v) => setState(() {
                              _hideUnknown = v;
                              _selectedTargetIndex = -1;
                            }),
                            activeTrackColor:
                                AppColors.primaryAccent.withValues(alpha: 0.5),
                            activeThumbColor: AppColors.primaryAccent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('Hide Unknown',
                          style: TextStyle(
                              color: AppColors.secondaryText, fontSize: 12)),
                      if (_hideUnknown && allTargets.length != targets.length)
                        Text(
                          '  (${allTargets.length - targets.length} hidden)',
                          style: TextStyle(
                              color: AppColors.disabledText, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                if (isScanning)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                      color: AppColors.primaryAccent,
                      backgroundColor:
                          AppColors.primaryAccent.withValues(alpha: 0.2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Targets list
          _buildSectionCard(
            title: 'Targets (${targets.length})',
            icon: Icons.devices,
            child: targets.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('No devices found yet',
                        style: TextStyle(
                            color: AppColors.disabledText, fontSize: 13)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: targets.length,
                    itemBuilder: (ctx, idx) => _buildTargetTile(idx, targets),
                  ),
          ),
          const SizedBox(height: 12),

          // Attack controls (visible when target selected)
          if (_selectedTargetIndex >= 0 &&
              _selectedTargetIndex < targets.length)
            _buildAttackSection(isAttacking),
        ],
      ),
    );
  }

  Widget _buildTargetTile(int index, List<Map<String, dynamic>> targets) {
    final t = targets[index];
    final typeName = NrfTarget.typeFromCode(t['deviceType'] ?? 0);
    final channel = t['channel'] ?? 0;
    final address = t['address'] as List? ?? [];
    final addressHex = address
        .map((b) => (b as int).toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    final isSelected = _selectedTargetIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTargetIndex = index),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryAccent.withValues(alpha: 0.1)
              : AppColors.surfaceElevated,
          border: Border.all(
            color:
                isSelected ? AppColors.primaryAccent : AppColors.borderDefault,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              typeName == 'Microsoft' || typeName == 'MS Encrypted'
                  ? Icons.window
                  : typeName == 'Logitech'
                      ? Icons.keyboard
                      : Icons.device_unknown,
              color: AppColors.primaryAccent,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(typeName,
                      style: TextStyle(
                          color: AppColors.primaryText,
                          fontWeight: FontWeight.bold)),
                  Text('CH: $channel  Addr: $addressHex',
                      style: TextStyle(
                          color: AppColors.secondaryText, fontSize: 12)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: AppColors.primaryAccent),
          ],
        ),
      ),
    );
  }

  Widget _buildAttackSection(bool isAttacking) {
    return _buildSectionCard(
      title: 'Attack',
      icon: Icons.bolt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // String injection
          Text('Inject Text',
              style: TextStyle(
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                  fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _stringController,
                  style: const TextStyle(color: AppColors.primaryText),
                  decoration: InputDecoration(
                    hintText: 'Text to inject...',
                    hintStyle: TextStyle(color: AppColors.disabledText),
                    filled: true,
                    fillColor: AppColors.primaryBackground,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: AppColors.borderDefault),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: isAttacking
                    ? null
                    : () => _attackString(_selectedTargetIndex),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryAccent,
                    foregroundColor: AppColors.primaryBackground),
                child: const Text('Send'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // DuckyScript
          Text('DuckyScript',
              style: TextStyle(
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                  fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _duckyPathController,
                  style: const TextStyle(color: AppColors.primaryText),
                  decoration: InputDecoration(
                    hintText: '/DATA/DUCKY/payload.txt',
                    hintStyle: TextStyle(color: AppColors.disabledText),
                    filled: true,
                    fillColor: AppColors.primaryBackground,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: AppColors.borderDefault),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: isAttacking
                    ? null
                    : () => _attackDucky(_selectedTargetIndex),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: AppColors.primaryBackground),
                child: const Text('Run'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Stop button
          if (isAttacking)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _stopAttack,
                icon: const Icon(Icons.stop),
                label: const Text('Stop Attack'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: AppColors.onButton),
              ),
            ),
        ],
      ),
    );
  }

  // ── Spectrum Tab ────────────────────────────────────────────

  Widget _buildSpectrumTab(NrfProvider nrf) {
    final spectrumRunning = nrf.nrfSpectrumRunning;
    final spectrumLevels = nrf.nrfSpectrumLevels;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: spectrumRunning ? _stopSpectrum : _startSpectrum,
                  icon: Icon(spectrumRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(spectrumRunning ? 'Stop' : 'Start Analyzer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: spectrumRunning
                        ? AppColors.error
                        : AppColors.primaryAccent,
                    foregroundColor: spectrumRunning
                        ? AppColors.onButton
                        : AppColors.primaryBackground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Frequency labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('2.400 GHz',
                  style:
                      TextStyle(color: AppColors.secondaryText, fontSize: 11)),
              Text('2.462 GHz',
                  style:
                      TextStyle(color: AppColors.secondaryText, fontSize: 11)),
              Text('2.525 GHz',
                  style:
                      TextStyle(color: AppColors.secondaryText, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 4),
          // Spectrum bar chart
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.primaryBackground,
                border: Border.all(color: AppColors.borderDefault),
                borderRadius: BorderRadius.circular(8),
              ),
              child: CustomPaint(
                painter: _SpectrumPainter(spectrumLevels),
                size: Size.infinite,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('CH 0',
                  style:
                      TextStyle(color: AppColors.disabledText, fontSize: 10)),
              Text('CH 25',
                  style:
                      TextStyle(color: AppColors.disabledText, fontSize: 10)),
              Text('CH 50',
                  style:
                      TextStyle(color: AppColors.disabledText, fontSize: 10)),
              Text('CH 75',
                  style:
                      TextStyle(color: AppColors.disabledText, fontSize: 10)),
              Text('CH 100',
                  style:
                      TextStyle(color: AppColors.disabledText, fontSize: 10)),
              Text('CH 125',
                  style:
                      TextStyle(color: AppColors.disabledText, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Jammer Tab ──────────────────────────────────────────────

  Widget _buildJammerTab(NrfProvider nrf) {
    final jammerRunning = nrf.nrfJammerRunning;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Legal disclaimer
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: AppColors.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'For educational use only. Jamming may be illegal in your jurisdiction.',
                    style: TextStyle(color: AppColors.error, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Mode selector with settings/info icons
          _buildSectionCard(
            title: 'Mode',
            icon: Icons.tune,
            child: Column(
              children: [
                ...NrfJamModeUiData.allModes
                    .map((m) => _buildModeOption(m, nrf, jammerRunning)),
                // Reset all configs button
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: jammerRunning
                          ? null
                          : () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppColors.surfaceElevated,
                                  title: Text('Reset Defaults',
                                      style: TextStyle(
                                          color: AppColors.primaryText)),
                                  content: Text(
                                      'Reset all per-mode configs to optimal firmware defaults?',
                                      style: TextStyle(
                                          color: AppColors.secondaryText)),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: Text('Cancel',
                                            style: TextStyle(
                                                color:
                                                    AppColors.secondaryText))),
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: Text('Reset',
                                            style: TextStyle(
                                                color: AppColors.error))),
                                  ],
                                ),
                              );
                              if (confirm == true) _resetAllConfigs();
                            },
                      icon: Icon(Icons.restore,
                          size: 16,
                          color: jammerRunning
                              ? AppColors.disabledText
                              : AppColors.secondaryText),
                      label: Text('Reset Defaults',
                          style: TextStyle(
                              fontSize: 12,
                              color: jammerRunning
                                  ? AppColors.disabledText
                                  : AppColors.secondaryText)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Single channel config
          if (_jamMode == 8)
            _buildSectionCard(
              title: 'Channel',
              icon: Icons.radio,
              child: Column(
                children: [
                  Text('Channel: $_jamChannel (${2400 + _jamChannel} MHz)',
                      style: TextStyle(color: AppColors.primaryText)),
                  Slider(
                    value: _jamChannel.toDouble(),
                    min: 0,
                    max: 124,
                    divisions: 124,
                    activeColor: AppColors.primaryAccent,
                    onChanged: (v) => setState(() => _jamChannel = v.round()),
                  ),
                ],
              ),
            ),

          // Custom hopper config
          if (_jamMode == 9)
            _buildSectionCard(
              title: 'Hopper Config',
              icon: Icons.swap_horiz,
              child: Column(
                children: [
                  _buildSliderRow('Start', _hopStart, 0, 124,
                      (v) => setState(() => _hopStart = v.round())),
                  _buildSliderRow('Stop', _hopStop, 0, 124,
                      (v) => setState(() => _hopStop = v.round())),
                  _buildSliderRow('Step', _hopStep, 1, 10,
                      (v) => setState(() => _hopStep = v.round())),
                ],
              ),
            ),

          // Live dwell time slider (visible when jammer is running)
          if (jammerRunning)
            _buildSectionCard(
              title: 'Dwell Time (live)',
              icon: Icons.speed,
              child: Column(
                children: [
                  Text(_liveDwellMs == 0 ? 'TURBO' : '$_liveDwellMs ms',
                      style: TextStyle(
                          color: AppColors.primaryAccent,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('Time spent on each channel hop (0 = turbo, max speed)',
                      style: TextStyle(
                          color: AppColors.secondaryText, fontSize: 11)),
                  Slider(
                    value: _liveDwellMs.toDouble(),
                    min: 0,
                    max: 200,
                    divisions: 200,
                    activeColor: AppColors.primaryAccent,
                    onChanged: (v) {
                      setState(() => _liveDwellMs = v.round());
                    },
                    onChangeEnd: (v) {
                      _setDwellTimeLive(v.round());
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('0 (Turbo)',
                          style: TextStyle(
                              color: AppColors.disabledText, fontSize: 10)),
                      Text('100 ms',
                          style: TextStyle(
                              color: AppColors.disabledText, fontSize: 10)),
                      Text('200 ms',
                          style: TextStyle(
                              color: AppColors.disabledText, fontSize: 10)),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),

          // Start/Stop button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: jammerRunning ? _stopJammer : _startJammer,
              icon: Icon(jammerRunning ? Icons.stop : Icons.play_arrow),
              label: Text(jammerRunning ? 'Stop Jammer' : 'Start Jammer'),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    jammerRunning ? AppColors.error : AppColors.jamming,
                foregroundColor: AppColors.primaryBackground,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Icon for each jammer mode category
  IconData _modeIcon(int mode) {
    switch (mode) {
      case 0:
        return Icons.all_inclusive; // Full Spectrum
      case 1:
        return Icons.wifi; // WiFi
      case 2:
        return Icons.bluetooth; // BLE Data
      case 3:
        return Icons.bluetooth_searching; // BLE Advertising
      case 4:
        return Icons.bluetooth_audio; // Bluetooth
      case 5:
        return Icons.usb; // USB Wireless
      case 6:
        return Icons.videocam; // Video
      case 7:
        return Icons.sports_esports; // RC
      case 8:
        return Icons.radio; // Single Channel
      case 9:
        return Icons.swap_horiz; // Custom Hopper
      case 10:
        return Icons.hub; // Zigbee
      case 11:
        return Icons.flight; // Drone
      default:
        return Icons.wifi_tethering;
    }
  }

  Widget _buildModeOption(
      NrfJamModeUiData modeData, NrfProvider nrf, bool jammerRunning) {
    final isSelected = _jamMode == modeData.mode;
    return GestureDetector(
      onTap: () async {
        setState(() => _jamMode = modeData.mode);
        if (jammerRunning) {
          // Send live mode change command (0x2C) to firmware
          final cmd =
              FirmwareBinaryProtocol.createNrfJamSetModeCommand(modeData.mode);
          await nrf.sendCommand!(cmd);
          // Update cached dwell for the live slider
          final cachedCfg = nrf.nrfJamModeConfigs[modeData.mode];
          setState(() {
            _liveDwellMs = cachedCfg?['dwellTimeMs'] ?? 0;
          });
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryAccent.withValues(alpha: 0.1)
              : Colors.transparent,
          border: Border.all(
            color:
                isSelected ? AppColors.primaryAccent : AppColors.borderDefault,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            // Mode icon
            Icon(
              _modeIcon(modeData.mode),
              color:
                  isSelected ? AppColors.primaryAccent : AppColors.disabledText,
              size: 20,
            ),
            const SizedBox(width: 8),
            // Radio button
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              color:
                  isSelected ? AppColors.primaryAccent : AppColors.disabledText,
              size: 16,
            ),
            const SizedBox(width: 8),
            // Label and subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(modeData.label,
                      style: TextStyle(
                          color: AppColors.primaryText,
                          fontWeight: FontWeight.w500,
                          fontSize: 13)),
                  Text(modeData.shortDesc,
                      style: TextStyle(
                          color: AppColors.secondaryText, fontSize: 11)),
                ],
              ),
            ),
            // Settings gear icon
            _ModeActionButton(
              icon: Icons.settings,
              tooltip: 'Settings',
              onPressed: () => _showModeSettingsDialog(modeData.mode, nrf),
            ),
            const SizedBox(width: 4),
            // Info icon
            _ModeActionButton(
              icon: Icons.info_outline,
              tooltip: 'Info',
              onPressed: () => _showModeInfoDialog(modeData.mode, nrf),
            ),
          ],
        ),
      ),
    );
  }

  // ── Mode Settings Dialog (cmd 0x43) ──────────────────────────

  Future<void> _showModeSettingsDialog(int mode, NrfProvider nrf) async {
    // Request config from firmware first
    await _requestModeConfig(mode);
    // Wait briefly for the response notification
    await Future.delayed(const Duration(milliseconds: 400));

    if (!mounted) return;

    final cachedCfg = nrf.nrfJamModeConfigs[mode];
    int pa = cachedCfg?['paLevel'] ?? 3;
    int dr = cachedCfg?['dataRate'] ?? 1;
    int dwell = cachedCfg?['dwellTimeMs'] ?? 0;
    bool flood = cachedCfg?['useFlooding'] ?? false;
    int bursts = cachedCfg?['floodBursts'] ?? 3;
    final modeLabel = NrfJamModeUiData.allModes[mode].label;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surfaceElevated,
              title: Row(
                children: [
                  Icon(_modeIcon(mode),
                      color: AppColors.primaryAccent, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('$modeLabel Settings',
                        style: TextStyle(
                            color: AppColors.primaryText, fontSize: 16)),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // PA Level
                    Text('PA Level (Transmit Power)',
                        style: TextStyle(
                            color: AppColors.secondaryText, fontSize: 12)),
                    const SizedBox(height: 4),
                    _buildDropdown<int>(
                      value: pa,
                      items: [
                        _dropItem(0, 'MIN (-18 dBm)'),
                        _dropItem(1, 'LOW (-12 dBm)'),
                        _dropItem(2, 'HIGH (-6 dBm)'),
                        _dropItem(3, 'MAX (0 / +20 PA)'),
                      ],
                      onChanged: (v) => setDialogState(() => pa = v ?? pa),
                    ),
                    const SizedBox(height: 12),

                    // Data Rate
                    Text('Data Rate',
                        style: TextStyle(
                            color: AppColors.secondaryText, fontSize: 12)),
                    const SizedBox(height: 4),
                    _buildDropdown<int>(
                      value: dr,
                      items: [
                        _dropItem(0, '1 Mbps'),
                        _dropItem(1, '2 Mbps'),
                        _dropItem(2, '250 Kbps'),
                      ],
                      onChanged: (v) => setDialogState(() => dr = v ?? dr),
                    ),
                    const SizedBox(height: 12),

                    // Dwell Time
                    Text(
                        dwell == 0
                            ? 'Dwell Time: TURBO (0 ms)'
                            : 'Dwell Time: $dwell ms',
                        style: TextStyle(
                            color: AppColors.secondaryText, fontSize: 12)),
                    Slider(
                      value: dwell.toDouble(),
                      min: 0,
                      max: 200,
                      divisions: 200,
                      activeColor: AppColors.primaryAccent,
                      onChanged: (v) => setDialogState(() => dwell = v.round()),
                    ),
                    const SizedBox(height: 12),

                    // Strategy toggle
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Data Flooding',
                            style: TextStyle(
                                color: AppColors.secondaryText, fontSize: 12)),
                        Switch(
                          value: flood,
                          activeTrackColor:
                              AppColors.primaryAccent.withValues(alpha: 0.5),
                          activeThumbColor: AppColors.primaryAccent,
                          onChanged: (v) => setDialogState(() => flood = v),
                        ),
                      ],
                    ),
                    Text(
                      flood
                          ? 'Flooding: sends burst packets (good for WiFi, BLE, Zigbee)'
                          : 'Constant Carrier (CW): holds carrier wave (good for FHSS, BT)',
                      style: TextStyle(
                          color: AppColors.disabledText, fontSize: 10),
                    ),
                    const SizedBox(height: 12),

                    // Flood bursts (only visible when flooding)
                    if (flood) ...[
                      Text('Flood Bursts per hop: $bursts',
                          style: TextStyle(
                              color: AppColors.secondaryText, fontSize: 12)),
                      Slider(
                        value: bursts.toDouble(),
                        min: 1,
                        max: 10,
                        divisions: 9,
                        activeColor: AppColors.primaryAccent,
                        onChanged: (v) =>
                            setDialogState(() => bursts = v.round()),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel',
                      style: TextStyle(color: AppColors.secondaryText)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryAccent,
                    foregroundColor: AppColors.primaryBackground,
                  ),
                  onPressed: () {
                    _setModeConfig(mode, pa, dr, dwell, flood, bursts);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Mode Info Dialog (cmd 0x44) ──────────────────────────────

  Future<void> _showModeInfoDialog(int mode, NrfProvider nrf) async {
    // Request info from firmware
    await _requestModeInfo(mode);
    await Future.delayed(const Duration(milliseconds: 400));

    if (!mounted) return;

    final cached = nrf.nrfJamModeInfos[mode];
    final ui = NrfJamModeUiData.allModes[mode];
    final name = cached?['name'] ?? ui.label;
    final desc = cached?['description'] ?? ui.shortDesc;
    final freqStart = cached?['freqStartMHz'] ?? 2400;
    final freqEnd = cached?['freqEndMHz'] ?? 2525;
    final chCount = cached?['channelCount'] ?? 0;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: Row(
          children: [
            Icon(_modeIcon(mode), color: AppColors.primaryAccent, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  style: TextStyle(color: AppColors.primaryText, fontSize: 16)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(desc,
                style: TextStyle(color: AppColors.secondaryText, fontSize: 13)),
            const SizedBox(height: 16),
            _infoRow('Frequency Range', '$freqStart – $freqEnd MHz'),
            _infoRow('Channels', '$chCount'),
            _infoRow('Mode Index', '$mode'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text('Close', style: TextStyle(color: AppColors.primaryAccent)),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(color: AppColors.disabledText, fontSize: 12)),
          Text(value,
              style: TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  // ── Dropdown helper ─────────────────────────────────────────

  DropdownMenuItem<T> _dropItem<T>(T value, String label) {
    return DropdownMenuItem<T>(
      value: value,
      child: Text(label,
          style: TextStyle(color: AppColors.primaryText, fontSize: 13)),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.primaryBackground,
        border: Border.all(color: AppColors.borderDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isExpanded: true,
          dropdownColor: AppColors.surfaceElevated,
          iconEnabledColor: AppColors.primaryAccent,
        ),
      ),
    );
  }

  Widget _buildSliderRow(String label, int value, int min, int max,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(label,
              style: TextStyle(color: AppColors.secondaryText, fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            activeColor: AppColors.primaryAccent,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 30,
          child: Text('$value',
              style: TextStyle(color: AppColors.primaryText, fontSize: 12)),
        ),
      ],
    );
  }

  // ── Shared Widgets ──────────────────────────────────────────

  Widget _buildSectionCard(
      {required String title, required IconData icon, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        border: Border.all(color: AppColors.borderDefault),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                Icon(icon, color: AppColors.primaryAccent, size: 18),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        color: AppColors.primaryAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
              ],
            ),
          ),
          Divider(color: AppColors.borderDefault, height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: child,
          ),
        ],
      ),
    );
  }
}

// ── Small icon button for settings / info on each mode row ──────

class _ModeActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _ModeActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: AppColors.secondaryText),
        ),
      ),
    );
  }
}

// ── Spectrum bar-chart painter ────────────────────────────────────

class _SpectrumPainter extends CustomPainter {
  final List<int> levels;
  _SpectrumPainter(this.levels);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;

    final barWidth = size.width / levels.length;
    // EMA max output is 100 (hit_pct capped at 100, EMA converges to it).
    // Using 100.0 so a fully saturated channel fills the entire height.
    const maxLevel = 100.0;

    for (int i = 0; i < levels.length; i++) {
      final level = levels[i].toDouble().clamp(0.0, maxLevel);
      final barHeight = (level / maxLevel) * size.height;
      final x = i * barWidth;

      // Gradient color depending on energy level
      final t = level / maxLevel;
      final color = Color.lerp(
        AppColors.primaryAccent.withValues(alpha: 0.4),
        AppColors.primaryAccent,
        t,
      )!;

      canvas.drawRect(
        Rect.fromLTWH(x, size.height - barHeight, barWidth - 1, barHeight),
        Paint()..color = color,
      );

      // Grid lines every 10 channels
      if (i % 10 == 0) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = AppColors.borderDefault.withValues(alpha: 0.5)
            ..strokeWidth = 0.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    // Avoid unnecessary repaints when levels haven't changed
    if (identical(levels, oldDelegate.levels)) return false;
    if (levels.length != oldDelegate.levels.length) return true;
    for (int i = 0; i < levels.length; i++) {
      if (levels[i] != oldDelegate.levels[i]) return true;
    }
    return false;
  }
}
