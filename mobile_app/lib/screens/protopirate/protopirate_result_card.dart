/// ProtoPirate decoded result card. Extracted from
/// `protopirate_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/protopirate_result.dart';
import '../../providers/nrf_provider.dart';
import '../../providers/notification_provider.dart';
import '../../theme/app_colors.dart';

/// Accent color for the ProtoPirate module (cyan / teal)
const Color _ppAccent = AppColors.ppAccent;
const Color _ppAccentDim = AppColors.ppAccentDim;

class ResultCard extends StatelessWidget {
  final ProtoPirateResult result;
  final int index;

  const ResultCard({required this.result, required this.index});

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
    final nrf = context.read<NrfProvider>();
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
                      await nrf.ppEmulate(result,
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
    final nrf = context.read<NrfProvider>();
    final notifications =
        Provider.of<NotificationProvider>(context, listen: false);

    try {
      await nrf.ppSaveCapture(result);
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

class ProtoBadge extends StatelessWidget {
  final String name;
  const ProtoBadge(this.name);

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
