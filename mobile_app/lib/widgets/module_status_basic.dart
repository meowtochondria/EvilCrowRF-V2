/// CC1101 module-status cards extracted from `module_status_widget.dart`
/// as part of Milestone 4 (M4) of `docs/refactor.md`.
///
/// Renders the header (free heap) and one card per CC1101 module showing
/// the current mode, parsed config (frequency / data rate / etc.), and a
/// settings-error fallback when the device reports a malformed settings
/// string.
library;

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/cc1101/cc1101_calculator.dart';
import '../theme/app_colors.dart';

/// Public widget that renders the basic CC1101 module status list.
///
/// Intentionally free of nRF24 / SD card concerns — those live in
/// `module_status_expanded.dart` and are composed by
/// `module_status_widget.dart`.
class ModuleStatusBasic extends StatelessWidget {
  final List<Map<String, dynamic>> cc1101Modules;
  final Map<String, dynamic>? deviceInfo;

  const ModuleStatusBasic({
    super.key,
    required this.cc1101Modules,
    this.deviceInfo,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 12),
            ...cc1101Modules.asMap().entries.map((entry) {
              final index = entry.key;
              final module = entry.value;
              return _buildModuleCard(context, index, module);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final freeHeap = deviceInfo?['freeHeap'] ?? 0;

    return Row(
      children: [
        Icon(
          Icons.memory,
          size: 20,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Text(
          AppLocalizations.of(context)!.deviceStatus,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: AppColors.primaryText,
              ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '${(freeHeap / 1024).toStringAsFixed(1)} KB',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
          ),
        ),
      ],
    );
  }

  Widget _buildModuleCard(
      BuildContext context, int index, Map<String, dynamic> module) {
    final moduleId = module['id'] ?? index;
    final mode = module['mode'] ?? 'Unknown';
    final settings = module['settings'] ?? '';

    // Parse module settings
    CC1101Config? config;
    try {
      if (settings.isNotEmpty) {
        config = parseSettingsFromString(settings);
      }
    } catch (e) {
      // If parsing failed, show error
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Module header
          Row(
            children: [
              Icon(
                Icons.settings_input_antenna,
                size: 18,
                color: _getModeColor(context, mode),
              ),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context)!.subGhzModule(moduleId + 1),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    ),
              ),
              const Spacer(),
              _buildModeChip(context, mode),
            ],
          ),

          if (config != null) ...[
            const SizedBox(height: 8),
            _buildConfigInfo(context, config),
          ] else if (settings.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildSettingsError(context, settings),
          ],
        ],
      ),
    );
  }

  Widget _buildModeChip(BuildContext context, String mode) {
    final color = _getModeColor(context, mode);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        mode,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildConfigInfo(BuildContext context, CC1101Config config) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.primaryBackground,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoItem(
            context,
            Icons.radio,
            '${config.frequency.toStringAsFixed(2)} MHz',
            l10n.frequency,
          ),
          _buildInfoItem(
            context,
            Icons.waves,
            '${config.dataRate.toStringAsFixed(2)} kBaud',
            l10n.dataRate,
          ),
          _buildInfoItem(
            context,
            Icons.tune,
            _modulationName(context, config.modulation),
            l10n.modulation,
          ),
          if (config.bandwidth > 0)
            _buildInfoItem(
              context,
              Icons.equalizer,
              '${config.bandwidth.toStringAsFixed(0)} kHz',
              l10n.bandwidth,
            ),
        ],
      ),
    );
  }

  Widget _buildInfoItem(
      BuildContext context, IconData icon, String value, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.secondaryText),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: const TextStyle(
              color: AppColors.secondaryText,
              fontSize: 12,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.primaryText,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsError(BuildContext context, String settings) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber,
                size: 14,
                color: AppColors.error,
              ),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context)!.invalidSettingsFormat,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            settings,
            style: const TextStyle(
              color: AppColors.secondaryText,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _modulationName(BuildContext context, int modulation) {
    final l10n = AppLocalizations.of(context)!;
    switch (modulation) {
      case 0:
        return l10n.modulationFsk2;
      case 1:
        return l10n.modulationGfsk;
      case 2:
        return l10n.modulationAskOok;
      case 3:
        return l10n.modulationFsk4;
      case 4:
        return l10n.modulationMsk;
      default:
        return 'Unknown';
    }
  }

  Color _getModeColor(BuildContext context, String mode) {
    return AppColors.getModuleStatusColor(mode);
  }
}
