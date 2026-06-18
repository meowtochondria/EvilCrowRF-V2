import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/subghz_provider.dart';
import '../../services/cc1101/cc1101_values.dart';
import '../../services/logger_service.dart';
import '../../services/signal_processing/signal_data.dart';
import '../../theme/app_colors.dart';
import '../../widgets/record_screen_widgets.dart';

/// "Record settings" card for a single CC1101 module — the main config
/// panel of [RecordScreen]. Combines:
///   - a frequency picker with on-the-fly "search detected frequencies"
///     integration (calls [onStartFrequencySearch] / [onStopFrequencySearch]),
///   - simple-mode preset selector,
///   - advanced-mode sliders (bandwidth, data rate, modulation, deviation),
///   - the advanced-mode toggle bar.
///
/// Extracted from `record_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
///
/// The widget owns its own TextEditingControllers (one set per instance).
/// The parent never reads them — instead, the widget calls [onConfigChanged]
/// whenever a field is edited. Callers should pass a stable [Key] (e.g.
/// `ValueKey('record_panel_$moduleIndex')`) so the controllers survive
/// list rebuilds.
class RecordConfigPanel extends StatefulWidget {
  final int moduleIndex;
  final RecordConfig config;
  final bool isBusy;
  final bool isFrequencySearching;

  /// Called whenever the user edits any field. The parent should persist
  /// the new [RecordConfig] to its own state.
  final ValueChanged<RecordConfig> onConfigChanged;

  final VoidCallback onStartFrequencySearch;
  final VoidCallback onStopFrequencySearch;

  /// When true, the advanced controls are expanded by default. Tapping
  /// the advanced toggle bar will toggle this state and notify the parent
  /// via [onAdvancedExpansionChanged].
  final bool advancedExpanded;
  final ValueChanged<bool> onAdvancedExpansionChanged;

  const RecordConfigPanel({
    super.key,
    required this.moduleIndex,
    required this.config,
    required this.isBusy,
    required this.isFrequencySearching,
    required this.onConfigChanged,
    required this.onStartFrequencySearch,
    required this.onStopFrequencySearch,
    required this.advancedExpanded,
    required this.onAdvancedExpansionChanged,
  });

  @override
  State<RecordConfigPanel> createState() => _RecordConfigPanelState();
}

class _RecordConfigPanelState extends State<RecordConfigPanel> {
  // ── Local controllers ──
  late final TextEditingController _frequencyController;
  late final TextEditingController _dataRateController;
  late final TextEditingController _deviationController;
  late final TextEditingController _bandwidthController;

  // ── Local UI state ──
  /// Timestamp of the most recent auto-detected frequency. Drives the
  /// 3-second "check_circle" indicator on the frequency field.
  DateTime? _lastDetectionTime;

  @override
  void initState() {
    super.initState();
    _frequencyController = TextEditingController(text: '433.92');
    _dataRateController = TextEditingController();
    _deviationController = TextEditingController();
    _bandwidthController = TextEditingController();
  }

  @override
  void didUpdateWidget(covariant RecordConfigPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync the free-form text fields with the latest config values whenever
    // the parent updates the config from elsewhere (e.g. detected-frequency
    // callback, advanced-mode toggle). We only assign if the displayed
    // text would actually change, to avoid clobbering an in-progress edit.
    _syncIfChanged(_bandwidthController, widget.config.rxBandwidth);
    _syncIfChanged(_dataRateController, widget.config.dataRate);
    _syncIfChanged(_deviationController, widget.config.deviation);
  }

  void _syncIfChanged(TextEditingController c, double? value) {
    final text = value?.toStringAsFixed(2) ?? '';
    if (c.text != text) c.text = text;
  }

  @override
  void dispose() {
    _frequencyController.dispose();
    _dataRateController.dispose();
    _deviationController.dispose();
    _bandwidthController.dispose();
    super.dispose();
  }

  /// Return the closest CC1101 frequency string for [freq], or null.
  static String? _findClosestFrequencyString(double freq) {
    if (CC1101Values.frequencies.isEmpty) return null;
    String? closest;
    double minDifference = double.infinity;
    for (final freqString in CC1101Values.frequencies) {
      final f = double.tryParse(freqString);
      if (f == null) continue;
      final difference = (f - freq).abs();
      if (difference < minDifference) {
        minDifference = difference;
        closest = freqString;
      }
    }
    return closest;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Section title ──
            Text(
              l10n.recordSettings,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryText,
                  ),
            ),
            const SizedBox(height: 12),

            // ── Frequency row with search button ──
            Row(
              children: [
                Expanded(
                  child: _buildFrequencyField(context),
                ),
                const SizedBox(width: 8),
                _FrequencySearchButton(
                  isSearching: widget.isFrequencySearching,
                  onStart: widget.onStartFrequencySearch,
                  onStop: widget.onStopFrequencySearch,
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ── Simple-mode preset selector (always shown) ──
            _buildPresetSelector(context),

            const SizedBox(height: 12),

            // ── Advanced controls (visible only when advancedMode is on
            //     AND the user has expanded the panel) ──
            if (widget.config.advancedMode && widget.advancedExpanded) ...[
              const SizedBox(height: 4),
              _buildBandwidth(context),
              const SizedBox(height: 16),
              _buildDataRate(context),
              const SizedBox(height: 16),
              _buildModulation(context),
              // Deviation is only valid for FM modulations
              if (_isFmModulation(widget.config.modulation)) ...[
                const SizedBox(height: 16),
                _buildDeviation(context),
              ],
            ],

            // ── Advanced-mode toggle bar (always visible) ──
            const SizedBox(height: 12),
            _AdvancedModeToggle(
              advancedMode: widget.config.advancedMode,
              expanded: widget.advancedExpanded,
              onTap: () {
                if (!widget.config.advancedMode) {
                  // Enable advanced mode and expand
                  widget.onConfigChanged(
                      widget.config.copyWith(advancedMode: true));
                  widget.onAdvancedExpansionChanged(true);
                } else {
                  // Already in advanced mode — just toggle expansion
                  widget.onAdvancedExpansionChanged(!widget.advancedExpanded);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// ── Frequency dropdown with auto-detect integration ──
  Widget _buildFrequencyField(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        // Find current frequency string from list, or use config frequency
        String? currentFrequencyString =
            _findClosestFrequencyString(widget.config.frequency);
        String currentFrequency = currentFrequencyString ??
            widget.config.frequency.toStringAsFixed(2);

        // Get signals for this module, sorted by timestamp (newest first)
        final moduleSignals = subGhz.detectedSignals
            .where((signal) => signal.module == widget.moduleIndex)
            .where((signal) => signal.timestamp
                .isAfter(DateTime.now().subtract(const Duration(seconds: 30))))
            .toList();

        moduleSignals.sort((a, b) => b.timestamp.compareTo(a.timestamp));

        final isSearching =
            subGhz.isFrequencySearching[widget.moduleIndex] ?? false;

        if (moduleSignals.isNotEmpty && !isSearching) {
          final latestSignal = moduleSignals.first;
          final detectedFreq = double.tryParse(latestSignal.frequency);
          if (detectedFreq != null && detectedFreq > 0) {
            final closestFreqString = _findClosestFrequencyString(detectedFreq);
            if (closestFreqString != null) {
              currentFrequency = closestFreqString;
              final closestFreq = double.parse(closestFreqString);

              if ((closestFreq - widget.config.frequency).abs() > 0.001) {
                _lastDetectionTime = DateTime.now();
                Future.delayed(const Duration(seconds: 3), () {
                  if (mounted) setState(() {});
                });
                Future.microtask(() {
                  if (mounted) {
                    widget.onConfigChanged(
                        widget.config.copyWith(frequency: closestFreq));
                    AppLogger.debug(
                        'Updated frequency to ${closestFreq}MHz for module ${widget.moduleIndex}');
                  }
                });
              }
            }
          }
        }

        bool shouldShowIcon = false;
        if (moduleSignals.isNotEmpty) {
          final lastDetectionTime = _lastDetectionTime;
          if (lastDetectionTime != null) {
            final secondsSinceDetection =
                DateTime.now().difference(lastDetectionTime).inSeconds;
            shouldShowIcon = secondsSinceDetection < 3;
          } else {
            shouldShowIcon = true;
            _lastDetectionTime = DateTime.now();
          }
        }

        if (!CC1101Values.frequencies.contains(currentFrequency)) {
          final closest = _findClosestFrequencyString(widget.config.frequency);
          if (closest != null) {
            currentFrequency = closest;
          } else if (CC1101Values.frequencies.isNotEmpty) {
            currentFrequency = CC1101Values.frequencies.first;
          }
        }

        final latestSignalKey = moduleSignals.isNotEmpty
            ? '${moduleSignals.first.frequency}_${moduleSignals.first.timestamp.millisecondsSinceEpoch}'
            : '${widget.config.frequency}';

        return DropdownButtonFormField<String>(
          key: ValueKey('freq_dropdown_${widget.moduleIndex}_$latestSignalKey'),
          initialValue: currentFrequency,
          onChanged: (!widget.isBusy && !isSearching)
              ? (value) {
                  if (value != null) {
                    final frequency = double.tryParse(value);
                    if (frequency != null) {
                      widget.onConfigChanged(
                          widget.config.copyWith(frequency: frequency));
                    }
                  }
                }
              : null,
          decoration: InputDecoration(
            labelText:
                '${AppLocalizations.of(context)!.frequency} (${AppLocalizations.of(context)!.mhz})',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.graphic_eq),
            suffixIcon: shouldShowIcon
                ? const Icon(
                    Icons.check_circle,
                    color: AppColors.success,
                    size: 16,
                  )
                : null,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          isDense: true,
          items: CC1101Values.frequencies.map((freq) {
            return DropdownMenuItem<String>(
              value: freq,
              child: Text(
                freq,
                style: const TextStyle(color: AppColors.secondaryText),
              ),
            );
          }).toList(),
          dropdownColor: AppColors.secondaryBackground,
          style: const TextStyle(color: AppColors.primaryText),
        );
      },
    );
  }

  // ── Simple-mode preset selector ──
  Widget _buildPresetSelector(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        final isSearching =
            subGhz.isFrequencySearching[widget.moduleIndex] ?? false;
        return PresetSelector(
          value: widget.config.preset,
          onChanged: (widget.isBusy || isSearching)
              ? null
              : (value) {
                  if (value != null) {
                    widget
                        .onConfigChanged(widget.config.copyWith(preset: value));
                  }
                },
        );
      },
    );
  }

  // ── Advanced-mode fields ──
  Widget _buildBandwidth(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        final isSearching =
            subGhz.isFrequencySearching[widget.moduleIndex] ?? false;
        return BandwidthSelector(
          controller: _bandwidthController,
          value: widget.config.rxBandwidth,
          onChanged: (widget.isBusy || isSearching)
              ? null
              : (value) {
                  if (value != null) {
                    widget.onConfigChanged(
                        widget.config.copyWith(rxBandwidth: value));
                  }
                },
        );
      },
    );
  }

  Widget _buildDataRate(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        final isSearching =
            subGhz.isFrequencySearching[widget.moduleIndex] ?? false;
        return DataRateInputField(
          controller: _dataRateController,
          value: widget.config.dataRate,
          onChanged: (widget.isBusy || isSearching)
              ? null
              : (value) {
                  if (value != null) {
                    widget.onConfigChanged(
                        widget.config.copyWith(dataRate: value));
                  }
                },
        );
      },
    );
  }

  Widget _buildModulation(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        final isSearching =
            subGhz.isFrequencySearching[widget.moduleIndex] ?? false;
        return ModulationSelector(
          value: widget.config.modulation,
          onChanged: (widget.isBusy || isSearching)
              ? null
              : (value) {
                  if (value != null) {
                    widget.onConfigChanged(
                        widget.config.copyWith(modulation: value));
                  }
                },
        );
      },
    );
  }

  Widget _buildDeviation(BuildContext context) {
    return Consumer<SubGhzProvider>(
      builder: (context, subGhz, child) {
        final isSearching =
            subGhz.isFrequencySearching[widget.moduleIndex] ?? false;
        return DeviationInputField(
          controller: _deviationController,
          value: widget.config.deviation,
          onChanged: (widget.isBusy || isSearching)
              ? null
              : (value) {
                  if (value != null) {
                    widget.onConfigChanged(
                        widget.config.copyWith(deviation: value));
                  }
                },
        );
      },
    );
  }

  static bool _isFmModulation(String? mod) {
    return mod == '2-FSK' || mod == 'GFSK' || mod == '4-FSK' || mod == 'MSK';
  }
}

// ── Frequency search toggle button ──
class _FrequencySearchButton extends StatelessWidget {
  final bool isSearching;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _FrequencySearchButton({
    required this.isSearching,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: isSearching ? onStop : onStart,
      icon: Icon(
        isSearching ? Icons.stop : Icons.search,
        color: isSearching ? AppColors.error : null,
      ),
      tooltip: isSearching
          ? AppLocalizations.of(context)!.stopFrequencySearch
          : AppLocalizations.of(context)!.searchForFrequency,
      style: IconButton.styleFrom(
        backgroundColor:
            isSearching ? AppColors.error.withValues(alpha: 0.1) : null,
      ),
    );
  }
}

// ── Advanced-mode toggle bar (always visible at the bottom of the card) ──
class _AdvancedModeToggle extends StatelessWidget {
  final bool advancedMode;
  final bool expanded;
  final VoidCallback onTap;

  const _AdvancedModeToggle({
    required this.advancedMode,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 28,
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              (advancedMode && expanded)
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              size: 16,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.7),
            ),
            const SizedBox(width: 4),
            Text(
              (advancedMode && expanded)
                  ? AppLocalizations.of(context)!.presets
                  : AppLocalizations.of(context)!.advanced,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mirrors the existing `ModuleAction` enum from `record_screen.dart` so
/// callers don't need to import the parent file when constructing a
/// `RecordConfigPanel`.
enum ModuleAction { recording, jamming }
