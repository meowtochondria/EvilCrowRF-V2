import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/file_parsers/base_file_parser.dart';
import '../../theme/app_colors.dart';

/// "Parsed" tab of [FileViewerScreen] — shows the structured signal data
/// extracted from the .sub file by the parser.
///
/// Extracted from `file_viewer_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
class FileViewerParsedTab extends StatelessWidget {
  final FileParseResult? parseResult;

  const FileViewerParsedTab({super.key, required this.parseResult});

  @override
  Widget build(BuildContext context) {
    if (parseResult == null || !parseResult!.success) {
      final firstError = parseResult?.errors.isNotEmpty == true
          ? parseResult!.errors.first
          : null;
      return _ParseError(error: firstError);
    }

    final signalData = parseResult!.signalData!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main signal parameters
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context)!.signalParameters,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryText,
                        ),
                  ),
                  const SizedBox(height: 12),
                  if (signalData.frequency != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.frequency,
                      value: '${signalData.frequency!.toStringAsFixed(3)} MHz',
                    ),
                  if (signalData.modulation != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.modulation,
                      value: signalData.modulation!,
                    ),
                  if (signalData.dataRate != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.dataRate,
                      value: '${signalData.dataRate!.toStringAsFixed(2)} kBaud',
                    ),
                  if (signalData.deviation != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.deviation,
                      value: '${signalData.deviation!.toStringAsFixed(2)} kHz',
                    ),
                  if (signalData.rxBandwidth != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.rxBandwidth,
                      value:
                          '${signalData.rxBandwidth!.toStringAsFixed(1)} kHz',
                    ),
                  if (signalData.protocol != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.protocol,
                      value: signalData.protocol!,
                    ),
                  if (signalData.preset != null)
                    _InfoRow(
                      label: AppLocalizations.of(context)!.preset,
                      value: signalData.preset!,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Raw bit-level stats
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Raw Signal',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryText,
                        ),
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    label: AppLocalizations.of(context)!.samplesCount,
                    value: '${signalData.samplesCount ?? 0}',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-state shown when the parser returned an error or has not run yet.
class _ParseError extends StatelessWidget {
  final String? error;
  const _ParseError({this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: 64,
            color: AppColors.secondaryText,
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.failedToParseFile,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.secondaryText,
                ),
          ),
          const SizedBox(height: 8),
          if (error != null)
            Text(
              error!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.secondaryText,
                  ),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }
}

/// Single key/value row inside a Card. Shared between parsed tab and any
/// future detail views.
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.secondaryText,
                fontSize: 12,
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal UI-side mirror of `ParseResult` removed — the widget now takes
/// a `FileParseResult` directly so callers don't need to build an adapter.
