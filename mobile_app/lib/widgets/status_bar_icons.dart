import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../providers/notification_provider.dart';
import '../theme/app_colors.dart';

/// A small status icon with an optional numeric label badge.
class StatusIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final String? label;

  const StatusIcon({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon, size: 20, color: color),
          if (label != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1),
                ),
                child: Text(
                  label!,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    color: color,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Memory (free heap) status icon.
class MemoryStatusIcon extends StatelessWidget {
  final int freeHeap;

  const MemoryStatusIcon({super.key, required this.freeHeap});

  @override
  Widget build(BuildContext context) {
    final freeKB = freeHeap / 1024;
    final color = freeKB > 50
        ? AppColors.success
        : freeKB > 30
            ? AppColors.primaryText
            : AppColors.error;
    final l10n = AppLocalizations.of(context)!;

    return Tooltip(
      message: l10n.freeHeap(freeKB.toStringAsFixed(1)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.memory, size: 18, color: color),
          const SizedBox(width: 2),
          Text(
            '${freeKB.toStringAsFixed(0)}K',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Battery status icon with percentage and charging indicator.
class BatteryStatusIcon extends StatelessWidget {
  final int percentage;
  final bool charging;
  final int voltage;

  const BatteryStatusIcon({
    super.key,
    required this.percentage,
    required this.charging,
    required this.voltage,
  });

  IconData _getBatteryIcon() {
    if (charging) return Icons.battery_charging_full;
    if (percentage >= 90) return Icons.battery_full;
    if (percentage >= 70) return Icons.battery_6_bar;
    if (percentage >= 50) return Icons.battery_5_bar;
    if (percentage >= 35) return Icons.battery_4_bar;
    if (percentage >= 20) return Icons.battery_3_bar;
    if (percentage >= 10) return Icons.battery_2_bar;
    if (percentage >= 5) return Icons.battery_1_bar;
    return Icons.battery_0_bar;
  }

  Color _getBatteryColor() {
    if (charging) return AppColors.info;
    if (percentage > 50) return AppColors.success;
    if (percentage > 20) return AppColors.warning;
    return AppColors.error;
  }

  @override
  Widget build(BuildContext context) {
    final color = _getBatteryColor();
    final volts = (voltage / 1000.0).toStringAsFixed(2);
    return Tooltip(
      message: AppLocalizations.of(context)!.batteryTooltip(percentage, volts,
          charging ? AppLocalizations.of(context)!.chargingIndicator : ''),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_getBatteryIcon(), size: 18, color: color),
          const SizedBox(width: 2),
          Text(
            '$percentage%',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// CPU temperature with optional core clock display.
class CpuStatusIcon extends StatelessWidget {
  final double? temperatureC;
  final int? core0Mhz;
  final int? core1Mhz;
  final bool showCoreClocks;

  const CpuStatusIcon({
    super.key,
    required this.temperatureC,
    required this.core0Mhz,
    required this.core1Mhz,
    required this.showCoreClocks,
  });

  Color _tempColor() {
    final temp = temperatureC;
    if (temp == null) return AppColors.primaryText;
    if (temp < 60.0) return AppColors.success;
    if (temp < 75.0) return AppColors.warning;
    return AppColors.error;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = _tempColor();
    final tempText = temperatureC == null
        ? l10n.cpuTempUnknown
        : '${temperatureC!.toStringAsFixed(0)}°C';
    final c0 = core0Mhz ?? 0;
    final c1 = core1Mhz ?? c0;

    String tooltip = l10n.cpuTooltip(tempText);
    if (showCoreClocks) {
      tooltip += ' | ${l10n.cpuCoreInfo(c0, c1)}';
    }

    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.thermostat, size: 18, color: color),
          const SizedBox(width: 2),
          Text(
            showCoreClocks ? l10n.cpuCoreInfo(c0, c1) : tempText,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A single notification history list item with timestamp.
class NotificationListItem extends StatelessWidget {
  final AppNotification notification;

  const NotificationListItem({super.key, required this.notification});

  @override
  Widget build(BuildContext context) {
    final timeAgo = _formatTimeAgo(context, notification.timestamp);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              notification.icon,
              size: 20,
              color: notification.color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.message,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                  maxLines: null,
                  softWrap: true,
                ),
                const SizedBox(height: 4),
                Text(
                  timeAgo,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.color
                        ?.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(BuildContext context, DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    final l10n = AppLocalizations.of(context)!;

    if (difference.inSeconds < 60) {
      return l10n.justNow;
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}${l10n.minutesAgo}';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}${l10n.hoursAgo}';
    } else {
      return '${difference.inDays}${l10n.daysAgo}';
    }
  }
}
