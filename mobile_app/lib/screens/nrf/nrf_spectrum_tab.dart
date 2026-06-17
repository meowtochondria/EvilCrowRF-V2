import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// "Spectrum" tab of [NrfScreen] — shows a 126-bar NRF24 channel power
/// histogram with frequency / channel labels along the axes.
///
/// Extracted from `nrf_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
class NrfSpectrumTab extends StatelessWidget {
  final bool running;
  final List<int> levels;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const NrfSpectrumTab({
    super.key,
    required this.running,
    required this.levels,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: running ? onStop : onStart,
                  icon: Icon(running ? Icons.stop : Icons.play_arrow),
                  label: Text(running ? 'Stop' : 'Start Analyzer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        running ? AppColors.error : AppColors.primaryAccent,
                    foregroundColor: running
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
                painter: _SpectrumPainter(levels),
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
}

/// Bar-chart painter for the spectrum analyzer.
///
/// EMA max output is 100 (hit_pct capped at 100, EMA converges to it).
/// Using 100.0 so a fully saturated channel fills the entire height.
class _SpectrumPainter extends CustomPainter {
  final List<int> levels;
  _SpectrumPainter(this.levels);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;

    final barWidth = size.width / levels.length;
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
