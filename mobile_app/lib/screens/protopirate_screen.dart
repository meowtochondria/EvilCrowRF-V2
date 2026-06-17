import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/protopirate_result.dart';
import '../providers/nrf_provider.dart';
import '../providers/notification_provider.dart';
import '../theme/app_colors.dart';
import '../providers/connection_state_provider.dart';
import 'protopirate/protopirate_result_card.dart';

/// Accent color for the ProtoPirate module (cyan / teal).
/// _ppAccentDim was removed (M4 of refactor.md) — it was unused in
/// protopirate_screen.dart and was never imported.
const Color _ppAccent = AppColors.ppAccent;

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
    return Consumer<NrfProvider>(
      builder: (context, nrf, _) {
        final isDecoding = nrf.ppDecoding;
        final results = nrf.ppResults;
        final l10n = AppLocalizations.of(context)!;

        return Column(
          children: [
            // Control panel
            _buildControlPanel(context, nrf, isDecoding, l10n),

            // Status indicator
            if (isDecoding) _buildDecodingBanner(context, nrf, l10n),

            // Results header
            if (results.isNotEmpty)
              _buildResultsHeader(context, nrf, results, l10n),

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

  Widget _buildControlPanel(BuildContext context, NrfProvider nrf,
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
                  color: context.read<ConnectionStateProvider>().isConnected
                      ? AppColors.success
                      : AppColors.error,
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
                    onPressed:
                        context.read<ConnectionStateProvider>().isConnected
                            ? () => _toggleDecode(context, nrf, isDecoding)
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
                  onPressed:
                      (context.read<ConnectionStateProvider>().isConnected &&
                              !isDecoding)
                          ? () => _showLoadSubDialog(context, nrf)
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
      BuildContext context, NrfProvider nrf, AppLocalizations l10n) {
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
                        nrf.ppModule >= 0 ? nrf.ppModule : _selectedModule,
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
                    if (nrf.ppSignalCount > 0)
                      Text(
                        l10n.ppSignalsAnalyzed(nrf.ppSignalCount),
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

  Widget _buildResultsHeader(BuildContext context, NrfProvider nrf,
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
              nrf.ppClearResults();
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
        return ResultCard(result: result, index: index);
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
                ProtoBadge('Suzuki'),
                ProtoBadge('Subaru'),
                ProtoBadge('Kia'),
                ProtoBadge('Fiat'),
                ProtoBadge('Ford'),
                ProtoBadge('StarLine'),
                ProtoBadge('Scher-Khan'),
                ProtoBadge('VAG'),
                ProtoBadge('PSA'),
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
      BuildContext context, NrfProvider nrf, bool isDecoding) async {
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    try {
      if (isDecoding) {
        await nrf.ppStopDecode();
        notifications.showInfo(l10n.ppStopped);
      } else {
        final freq = _frequencyPresets[_selectedFreqIndex].mhz;
        await nrf.ppStartDecode(_selectedModule, freq);
        notifications.showSuccess(l10n.ppStarted(_selectedModule));
      }
    } catch (e) {
      notifications.showError(l10n.ppError(e.toString()));
    }
  }

  /// Show file browser dialog — queries SD card for .sub files and allows selection.
  /// Falls back to manual path entry via a secondary button.
  Future<void> _showLoadSubDialog(BuildContext context, NrfProvider nrf) async {
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);

    try {
      await nrf.ppListSubFiles('/');
    } catch (e) {
      notifications.showError('Failed to list files: $e');
      return;
    }
    if (!context.mounted) return;

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return Consumer<NrfProvider>(
          builder: (_, nrf, __) {
            final files = nrf.ppFileList;
            final received = nrf.ppFileListReceived;

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
                    _showManualPathDialog(context, nrf);
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
        await nrf.ppLoadSubFile(selected);
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
      BuildContext context, NrfProvider nrf) async {
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
        await nrf.ppLoadSubFile(result);
        notifications.showSuccess('Analyzing: $result');
      } catch (e) {
        notifications.showError('Load failed: $e');
      }
    }
  }
}
