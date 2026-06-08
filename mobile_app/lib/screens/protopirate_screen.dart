import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/protopirate_result.dart';
import '../providers/ble_provider.dart';
import '../providers/notification_provider.dart';
import '../theme/app_colors.dart';

/// Accent color for the ProtoPirate module (cyan / teal)
const Color _ppAccent = AppColors.ppAccent;
const Color _ppAccentDim = AppColors.ppAccentDim;

/// Preset frequencies for automotive key fob protocols
const List<_FreqPreset> _frequencyPresets = [
  _FreqPreset(label: '433.92 MHz', mhz: 433.92, region: 'EU / Asia'),
  _FreqPreset(label: '315.00 MHz', mhz: 315.00, region: 'US / Japan'),
  _FreqPreset(label: '868.35 MHz', mhz: 868.35, region: 'EU 868'),
  _FreqPreset(label: '303.87 MHz', mhz: 303.87, region: 'US alt'),
];

class _FreqPreset {
  final String label;
  final double mhz;
  final String region;
  const _FreqPreset(
      {required this.label, required this.mhz, required this.region});
}

/// ProtoPirate screen — automotive key fob protocol decoder
class ProtoPirateScreen extends StatefulWidget {
  const ProtoPirateScreen({super.key});

  @override
  State<ProtoPirateScreen> createState() => _ProtoPirateScreenState();
}

class _ProtoPirateScreenState extends State<ProtoPirateScreen>
    with SingleTickerProviderStateMixin {
  int _selectedModule = 0;
  int _selectedFreqIndex = 0;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<BleProvider>(
      builder: (context, ble, _) {
        final isDecoding = ble.ppDecoding;
        final results = ble.ppResults;
        final l10n = AppLocalizations.of(context)!;

        return Column(
          children: [
            // Control panel
            _buildControlPanel(context, ble, isDecoding, l10n),

            // Status indicator
            if (isDecoding) _buildDecodingBanner(context, ble, l10n),

            // Results header
            if (results.isNotEmpty)
              _buildResultsHeader(context, ble, results, l10n),

            // Results list or empty state
            Expanded(
              child: results.isEmpty
                  ? _buildEmptyState(context, l10n, isDecoding)
                  : _buildResultsList(context, results),
            ),
          ],
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Control Panel — frequency, module, start/stop
  // ══════════════════════════════════════════════════════════════

  Widget _buildControlPanel(BuildContext context, BleProvider ble,
      bool isDecoding, AppLocalizations l10n) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.secondaryBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDecoding
              ? _ppAccent.withValues(alpha: 0.5)
              : AppColors.borderDefault,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Row(
            children: [
              const Icon(Icons.car_repair, size: 20, color: _ppAccent),
              const SizedBox(width: 8),
              Text(
                l10n.protoPirate,
                style: const TextStyle(
                  color: _ppAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              // Connection status dot
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ble.isConnected ? AppColors.success : AppColors.error,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Frequency selector chips
          Text(
            l10n.ppFrequency,
            style: const TextStyle(
              color: AppColors.secondaryText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List.generate(_frequencyPresets.length, (i) {
              final preset = _frequencyPresets[i];
              final selected = _selectedFreqIndex == i;
              return ChoiceChip(
                label: Text(preset.label),
                selected: selected,
                onSelected: isDecoding
                    ? null
                    : (val) => setState(() => _selectedFreqIndex = i),
                selectedColor: _ppAccent.withValues(alpha: 0.25),
                backgroundColor: AppColors.surfaceElevated,
                side: BorderSide(
                  color: selected ? _ppAccent : AppColors.borderDefault,
                ),
                labelStyle: TextStyle(
                  color: selected ? _ppAccent : AppColors.primaryText,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }),
          ),

          const SizedBox(height: 12),

          // Module selector + Start/Stop button row
          Row(
            children: [
              // Module toggle
              Text(
                '${l10n.ppModule}: ',
                style: const TextStyle(
                  color: AppColors.secondaryText,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _buildModuleChip(0, isDecoding),
              const SizedBox(width: 6),
              _buildModuleChip(1, isDecoding),

              const SizedBox(width: 12),

              // Start / Stop button — fills remaining row width
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: ElevatedButton.icon(
                    onPressed: ble.isConnected
                        ? () => _toggleDecode(context, ble, isDecoding)
                        : null,
                    icon: Icon(
                      isDecoding
                          ? Icons.stop_rounded
                          : Icons.play_arrow_rounded,
                      size: 20,
                    ),
                    label: Text(
                      isDecoding ? l10n.ppStopDecode : l10n.ppStartDecode,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDecoding
                          ? AppColors.error.withValues(alpha: 0.9)
                          : _ppAccent,
                      foregroundColor: AppColors.onButton,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
                ),
              ),

              // Load .sub file for diagnostic analysis
              const SizedBox(width: 6),
              SizedBox(
                height: 38,
                width: 38,
                child: IconButton(
                  onPressed: (ble.isConnected && !isDecoding)
                      ? () => _showLoadSubDialog(context, ble)
                      : null,
                  icon: const Icon(Icons.folder_open, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.surfaceElevated,
                    foregroundColor: _ppAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  tooltip: 'Load .sub',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModuleChip(int module, bool isDecoding) {
    final selected = _selectedModule == module;
    return GestureDetector(
      onTap: isDecoding ? null : () => setState(() => _selectedModule = module),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? _ppAccent.withValues(alpha: 0.2)
              : AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? _ppAccent : AppColors.borderDefault,
          ),
        ),
        child: Text(
          '#${module + 1}',
          style: TextStyle(
            color: selected ? _ppAccent : AppColors.secondaryText,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Decoding Banner (animated pulse when active)
  // ══════════════════════════════════════════════════════════════

  Widget _buildDecodingBanner(
      BuildContext context, BleProvider ble, AppLocalizations l10n) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final opacity = 0.6 + (_pulseController.value * 0.4);
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: _ppAccent.withValues(
                alpha: 0.08 + _pulseController.value * 0.07),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _ppAccent.withValues(
                  alpha: 0.3 + _pulseController.value * 0.2),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _ppAccent.withValues(alpha: opacity),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.ppDecodingOn(
                        ble.ppModule >= 0 ? ble.ppModule : _selectedModule,
                        _frequencyPresets[_selectedFreqIndex]
                            .mhz
                            .toStringAsFixed(2),
                      ),
                      style: TextStyle(
                        color: _ppAccent.withValues(alpha: opacity),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (ble.ppSignalCount > 0)
                      Text(
                        l10n.ppSignalsAnalyzed(ble.ppSignalCount),
                        style: TextStyle(
                          color: _ppAccent.withValues(alpha: opacity * 0.7),
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Results Header with count + clear
  // ══════════════════════════════════════════════════════════════

  Widget _buildResultsHeader(BuildContext context, BleProvider ble,
      List<ProtoPirateResult> results, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.wifi_tethering,
              size: 14, color: _ppAccent.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          Text(
            l10n.ppResultCount(results.length),
            style: TextStyle(
              color: _ppAccent.withValues(alpha: 0.8),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          // Clear results button
          InkWell(
            onTap: () {
              ble.ppClearResults();
              Provider.of<NotificationProvider>(context, listen: false)
                  .showInfo(l10n.ppHistoryCleared);
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline,
                      size: 14,
                      color: AppColors.secondaryText.withValues(alpha: 0.7)),
                  const SizedBox(width: 4),
                  Text(
                    l10n.ppClearResults,
                    style: TextStyle(
                      color: AppColors.secondaryText.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Results List
  // ══════════════════════════════════════════════════════════════

  Widget _buildResultsList(
      BuildContext context, List<ProtoPirateResult> results) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return _ResultCard(result: result, index: index);
      },
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Empty State
  // ══════════════════════════════════════════════════════════════

  Widget _buildEmptyState(
      BuildContext context, AppLocalizations l10n, bool isDecoding) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isDecoding ? Icons.wifi_tethering : Icons.car_crash_outlined,
              size: 64,
              color: isDecoding
                  ? _ppAccent.withValues(alpha: 0.4)
                  : _ppAccent.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.ppNoResults,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isDecoding ? l10n.ppListeningHint : l10n.ppNoResultsHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDecoding
                    ? _ppAccent.withValues(alpha: 0.7)
                    : AppColors.secondaryText.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 24),
            // Supported protocols badge list
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: const [
                _ProtoBadge('Suzuki'),
                _ProtoBadge('Subaru'),
                _ProtoBadge('Kia'),
                _ProtoBadge('Fiat'),
                _ProtoBadge('Ford'),
                _ProtoBadge('StarLine'),
                _ProtoBadge('Scher-Khan'),
                _ProtoBadge('VAG'),
                _ProtoBadge('PSA'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Actions
  // ══════════════════════════════════════════════════════════════

  Future<void> _toggleDecode(
      BuildContext context, BleProvider ble, bool isDecoding) async {
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    try {
      if (isDecoding) {
        await ble.ppStopDecode();
        notifications.showInfo(l10n.ppStopped);
      } else {
        final freq = _frequencyPresets[_selectedFreqIndex].mhz;
        await ble.ppStartDecode(module: _selectedModule, frequency: freq);
        notifications.showSuccess(l10n.ppStarted(_selectedModule));
      }
    } catch (e) {
      notifications.showError(l10n.ppError(e.toString()));
    }
  }

  /// Show file browser dialog — queries SD card for .sub files and allows selection.
  /// Falls back to manual path entry via a secondary button.
  Future<void> _showLoadSubDialog(BuildContext context, BleProvider ble) async {
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);

    try {
      await ble.ppListSubFiles('/');
    } catch (e) {
      notifications.showError('Failed to list files: $e');
      return;
    }
    if (!context.mounted) return;

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return Consumer<BleProvider>(
          builder: (_, bleProv, __) {
            final files = bleProv.ppFileList;
            final received = bleProv.ppFileListReceived;

            Widget body;
            if (!received) {
              // Still waiting for firmware response
              body = const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: _ppAccent),
                    SizedBox(height: 12),
                    Text('Loading files from SD…',
                        style: TextStyle(
                            color: AppColors.secondaryText, fontSize: 12)),
                  ],
                ),
              );
            } else if (files.isEmpty) {
              body = Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_off,
                        size: 48,
                        color: AppColors.secondaryText.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    const Text('No .sub files found on SD card',
                        style: TextStyle(
                            color: AppColors.secondaryText, fontSize: 13)),
                  ],
                ),
              );
            } else {
              body = ListView.builder(
                itemCount: files.length,
                itemBuilder: (_, i) {
                  final file = files[i];
                  final path = file['path'] as String? ?? '';
                  final size = file['size'] as int? ?? 0;
                  final sizeStr = size < 1024
                      ? '$size B'
                      : '${(size / 1024).toStringAsFixed(1)} KB';
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.description,
                        color: _ppAccent, size: 18),
                    title: Text(
                      path.split('/').last,
                      style: const TextStyle(
                          color: AppColors.primaryText,
                          fontSize: 13,
                          fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      '$path  ·  $sizeStr',
                      style: TextStyle(
                          color: AppColors.secondaryText.withValues(alpha: 0.7),
                          fontSize: 10),
                    ),
                    onTap: () => Navigator.pop(ctx, path),
                  );
                },
              );
            }

            return AlertDialog(
              backgroundColor: AppColors.secondaryBackground,
              title: const Row(
                children: [
                  Icon(Icons.folder_open, color: _ppAccent, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text('Browse .sub files',
                        style: TextStyle(
                            color: AppColors.primaryText, fontSize: 16)),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 320,
                child: body,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _showManualPathDialog(context, ble);
                  },
                  child: const Text('Manual path…',
                      style: TextStyle(color: _ppAccent)),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected != null && selected.isNotEmpty) {
      try {
        await ble.ppLoadSubFile(selected);
        if (context.mounted) {
          notifications.showSuccess('Analyzing: $selected');
        }
      } catch (e) {
        notifications.showError('Load failed: $e');
      }
    }
  }

  /// Fallback dialog for entering a .sub file path manually
  Future<void> _showManualPathDialog(
      BuildContext context, BleProvider ble) async {
    final controller = TextEditingController(text: '/protopirate/');
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.secondaryBackground,
        title: const Text('Load .sub file',
            style: TextStyle(color: AppColors.primaryText, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the path of a .sub file on the SD card.',
              style: TextStyle(color: AppColors.secondaryText, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style:
                  const TextStyle(color: AppColors.primaryText, fontSize: 13),
              decoration: InputDecoration(
                hintText: '/protopirate/test.sub',
                hintStyle: TextStyle(
                    color: AppColors.secondaryText.withValues(alpha: 0.5)),
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: _ppAccent),
            child: const Text('Analyze',
                style: TextStyle(color: AppColors.onBright)),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        await ble.ppLoadSubFile(result);
        notifications.showSuccess('Analyzing: $result');
      } catch (e) {
        notifications.showError('Load failed: $e');
      }
    }
  }
}

// ════════════════════════════════════════════════════════════════
//  Result Card Widget
// ════════════════════════════════════════════════════════════════

class _ResultCard extends StatelessWidget {
  final ProtoPirateResult result;
  final int index;

  const _ResultCard({required this.result, required this.index});

  @override
  Widget build(BuildContext context) {
    // Alternate card tints for visual separation
    final isEven = index % 2 == 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color:
            isEven ? AppColors.secondaryBackground : AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: result.encrypted
              ? AppColors.encryptedOrange.withValues(alpha: 0.3)
              : _ppAccent.withValues(alpha: 0.15),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _showDetail(context),
          onLongPress: () => _copyToClipboard(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row: protocol name + badges
                Row(
                  children: [
                    // Protocol icon
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _ppAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.key, size: 16, color: _ppAccent),
                    ),
                    const SizedBox(width: 10),
                    // Protocol name and type
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.protocolName,
                            style: const TextStyle(
                              color: _ppAccent,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          if (result.type != null && result.type!.isNotEmpty)
                            Text(
                              result.type!,
                              style: TextStyle(
                                color: AppColors.secondaryText
                                    .withValues(alpha: 0.8),
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Badges
                    if (result.encrypted)
                      _buildBadge('ENC', AppColors.encryptedOrange),
                    if (result.encrypted) const SizedBox(width: 4),
                    _buildBadge(
                      result.crcValid ? 'CRC ✓' : 'CRC ✗',
                      result.crcValid ? AppColors.success : AppColors.error,
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                // Data fields grid
                _buildDataGrid(context),

                // Quick action icons row
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (result.canEmulate)
                      _actionIcon(
                        Icons.send,
                        'Emulate',
                        _ppAccent,
                        () => _emulateResult(context),
                      ),
                    _actionIcon(
                      Icons.save_alt,
                      'Save',
                      _ppAccent.withValues(alpha: 0.7),
                      () => _saveResult(context),
                    ),
                    _actionIcon(
                      Icons.copy,
                      'Copy',
                      AppColors.secondaryText.withValues(alpha: 0.6),
                      () => _copyToClipboard(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  /// Small action icon button for the card footer
  Widget _actionIcon(
      IconData icon, String tooltip, Color color, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Tooltip(
          message: tooltip,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }

  Widget _buildDataGrid(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DefaultTextStyle(
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      child: Table(
        columnWidths: const {
          0: FixedColumnWidth(70),
          1: FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          _dataRow(l10n.ppData, result.dataHex),
          if (result.serial != 0) _dataRow(l10n.ppSerial, result.serialHex),
          if (result.button != 0)
            _dataRow(l10n.ppButton, '${result.buttonName} (${result.button})'),
          if (result.counter != 0)
            _dataRow(l10n.ppCounter, result.counter.toString()),
        ],
      ),
    );
  }

  TableRow _dataRow(String label, String value) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.secondaryText.withValues(alpha: 0.8),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.primaryText,
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: result.summary));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: ${result.summary}'),
        duration: const Duration(seconds: 1),
        backgroundColor: _ppAccentDim,
      ),
    );
  }

  void _showDetail(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.secondaryBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.borderDefault,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Protocol title
                Row(
                  children: [
                    const Icon(Icons.key, color: _ppAccent, size: 24),
                    const SizedBox(width: 10),
                    Text(
                      result.protocolName,
                      style: const TextStyle(
                        color: _ppAccent,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (result.type != null && result.type!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 34, top: 2),
                    child: Text(
                      result.type!,
                      style: const TextStyle(
                        color: AppColors.secondaryText,
                        fontSize: 13,
                      ),
                    ),
                  ),

                const SizedBox(height: 16),
                const Divider(color: AppColors.divider),
                const SizedBox(height: 12),

                // All fields
                _detailRow(l10n.ppData, result.dataHex),
                if (result.data2 != 0)
                  _detailRow('Data2',
                      '0x${result.data2.toRadixString(16).toUpperCase()}'),
                _detailRow(l10n.ppSerial, result.serialHex),
                _detailRow(
                    l10n.ppButton, '${result.buttonName} (${result.button})'),
                _detailRow(l10n.ppCounter, result.counter.toString()),
                _detailRow('Bits', result.dataBits.toString()),
                _detailRow(l10n.ppEncrypted, result.encrypted ? 'Yes' : 'No'),
                _detailRow('CRC', result.crcValid ? 'Valid ✓' : 'Invalid ✗'),
                if (result.frequency > 0)
                  _detailRow(l10n.ppFrequency,
                      '${result.frequency.toStringAsFixed(2)} MHz'),

                const SizedBox(height: 16),

                // Action buttons row: Emulate, Save, Copy
                Row(
                  children: [
                    // Emulate button
                    if (result.canEmulate)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _emulateResult(context);
                            },
                            icon: const Icon(Icons.send, size: 16),
                            label: const Text('Emulate'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _ppAccent,
                              foregroundColor: AppColors.onBright,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Save button
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _saveResult(context);
                          },
                          icon: const Icon(Icons.save, size: 16),
                          label: const Text('Save'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.surfaceElevated,
                            foregroundColor: _ppAccent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: _ppAccent),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Copy button
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: result.summary));
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Data copied to clipboard'),
                                duration: Duration(seconds: 1),
                                backgroundColor: _ppAccentDim,
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _ppAccent,
                            side: const BorderSide(color: _ppAccent),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Emulate (TX) this decoded result via the device
  void _emulateResult(BuildContext context) {
    final ble = Provider.of<BleProvider>(context, listen: false);
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);

    // Show module selection dialog before emulating
    showDialog(
      context: context,
      builder: (ctx) {
        int module = 0;
        int repeat = 3;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.secondaryBackground,
              title: const Text('Emulate signal',
                  style: TextStyle(color: _ppAccent, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Protocol: ${result.protocolName}',
                      style: const TextStyle(
                          color: AppColors.primaryText, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Data: ${result.dataHex}',
                      style: const TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 11,
                          fontFamily: 'monospace')),
                  const SizedBox(height: 16),
                  // Module selector
                  const Text('CC1101 Module:',
                      style: TextStyle(
                          color: AppColors.secondaryText, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('#1'),
                        selected: module == 0,
                        onSelected: (v) => setDialogState(() => module = 0),
                        selectedColor: _ppAccent.withValues(alpha: 0.25),
                        labelStyle: TextStyle(
                            color:
                                module == 0 ? _ppAccent : AppColors.primaryText,
                            fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('#2'),
                        selected: module == 1,
                        onSelected: (v) => setDialogState(() => module = 1),
                        selectedColor: _ppAccent.withValues(alpha: 0.25),
                        labelStyle: TextStyle(
                            color:
                                module == 1 ? _ppAccent : AppColors.primaryText,
                            fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Repeat count
                  const Text('Repeat count:',
                      style: TextStyle(
                          color: AppColors.secondaryText, fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      for (final r in [1, 3, 5, 10])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text('$r'),
                            selected: repeat == r,
                            onSelected: (v) => setDialogState(() => repeat = r),
                            selectedColor: _ppAccent.withValues(alpha: 0.25),
                            labelStyle: TextStyle(
                                color: repeat == r
                                    ? _ppAccent
                                    : AppColors.primaryText,
                                fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    try {
                      await ble.ppEmulate(result,
                          module: module, repeat: repeat);
                      notifications.showSuccess(
                          'Emulating ${result.protocolName} on module #${module + 1}…');
                    } catch (e) {
                      notifications.showError('Emulate failed: $e');
                    }
                  },
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Transmit'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _ppAccent,
                    foregroundColor: AppColors.onBright,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Save this decoded result to SD card (/DATA/PROTOPIRATE/)
  void _saveResult(BuildContext context) async {
    final ble = Provider.of<BleProvider>(context, listen: false);
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);

    try {
      await ble.ppSaveCapture(result);
      notifications.showSuccess('Saving ${result.protocolName} to SD card…');
    } catch (e) {
      notifications.showError('Save failed: $e');
    }
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  Protocol Badge (used in empty state)
// ════════════════════════════════════════════════════════════════

class _ProtoBadge extends StatelessWidget {
  final String name;
  const _ProtoBadge(this.name);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _ppAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _ppAccent.withValues(alpha: 0.2)),
      ),
      child: Text(
        name,
        style: TextStyle(
          color: _ppAccent.withValues(alpha: 0.6),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
