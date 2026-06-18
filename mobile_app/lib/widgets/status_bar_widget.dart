import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/ble_provider.dart';
import 'status_bar_icons.dart';
import '../providers/wifi_provider.dart';
import '../providers/notification_provider.dart';
import '../services/logger_service.dart';
import '../theme/app_colors.dart';
import 'quick_connect_widget.dart';
import 'module_status_widget.dart';

class StatusBarWidget extends StatefulWidget {
  const StatusBarWidget({super.key});

  @override
  State<StatusBarWidget> createState() => _StatusBarWidgetState();
}

class _StatusBarWidgetState extends State<StatusBarWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Compact status bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryBackground.withValues(alpha: 0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Left part: status icons (5-6 icons)
                  _buildStatusIcons(context),

                  // Separator
                  Container(
                    width: 1,
                    height: 24,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.3),
                  ),

                  // Right part: notification area
                  Expanded(
                    child: _buildNotificationArea(context),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Expanded content with background shading
        if (_isExpanded) ...[
          // Background dimming
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _isExpanded = false;
                });
              },
              child: Container(
                color: AppColors.primaryBackground.withValues(alpha: 0.5),
              ),
            ),
          ),
          // Content above dimming
          Positioned(
            top: 36,
            left: 0,
            right: 0,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryBackground.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Quick Connect Widget (device widget with disconnect button)
                    const QuickConnectWidget(),

                    const SizedBox(height: 12),

                    // Module Status Widget
                    Consumer<BleProvider>(
                      builder: (context, bleProvider, child) {
                        if (bleProvider.isConnected &&
                            bleProvider.cc1101Modules != null) {
                          return ModuleStatusWidget(
                            cc1101Modules: bleProvider.cc1101Modules!,
                            deviceInfo: {'freeHeap': bleProvider.freeHeap ?? 0},
                            nrfPresent: bleProvider.nrfPresent,
                            nrfInitialized: bleProvider.nrfInitialized,
                            nrfJammerRunning: bleProvider.nrfJammerRunning,
                            nrfScanning: bleProvider.nrfScanning,
                            nrfAttacking: bleProvider.nrfAttacking,
                            nrfSpectrumRunning: bleProvider.nrfSpectrumRunning,
                            sdMounted: bleProvider.sdMounted,
                            sdTotalMB: bleProvider.sdTotalMB,
                            sdFreeMB: bleProvider.sdFreeMB,
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatusIcons(BuildContext context) {
    return Consumer2<BleProvider, WifiProvider>(
      builder: (context, bleProvider, wifiProvider, _) {
        final bleConnected = bleProvider.isConnected;
        final wifiConnected = wifiProvider.isConnected;
        // F2 (refactor.md): when the *other* transport is connected, show the
        // disabled icon in a muted (non-error) color so the user is not
        // mislead into thinking something is wrong.
        final otherTransportConnected = bleConnected || wifiConnected;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. WiFi Connection Status
              StatusIcon(
                icon: wifiConnected ? Icons.wifi : Icons.wifi_off,
                color: wifiConnected
                    ? AppColors.success
                    : (otherTransportConnected
                        ? AppColors.disabledText
                        : const Color(0xFFEF5350).withValues(alpha: 0.5)),
                tooltip: wifiConnected
                    ? AppLocalizations.of(context)!.wifiConnected(
                        wifiProvider.deviceHost ??
                            AppLocalizations.of(context)!.unknown)
                    : AppLocalizations.of(context)!.wifiNotConnected,
              ),

              const SizedBox(width: 6),

              // 2. BLE Connection Status
              StatusIcon(
                icon: bleConnected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color: bleConnected
                    ? const Color(0xFF42A5F5)
                    : (otherTransportConnected
                        ? AppColors.disabledText
                        : const Color(0xFFEF5350).withValues(alpha: 0.5)),
                tooltip: bleConnected
                    ? AppLocalizations.of(context)!.connectedToDevice(
                        bleProvider.connectedDevice?.platformName ??
                            AppLocalizations.of(context)!.unknown)
                    : AppLocalizations.of(context)!.bleNotConnected,
              ),

              const SizedBox(width: 6),

              // 2. Module 0 Status
              if (bleProvider.isConnected &&
                  bleProvider.cc1101Modules != null &&
                  bleProvider.cc1101Modules!.isNotEmpty)
                StatusIcon(
                  icon: Icons.settings_input_antenna,
                  color: _getModuleColorFromMode(
                      bleProvider.cc1101Modules![0]['mode'] ?? 'Idle'),
                  tooltip:
                      '${AppLocalizations.of(context)!.subGhzModule(1)}: ${bleProvider.cc1101Modules![0]['mode'] ?? AppLocalizations.of(context)!.unknown}',
                  label: '1',
                ),

              const SizedBox(width: 6),

              // 3. Module 1 Status
              if (bleProvider.isConnected &&
                  bleProvider.cc1101Modules != null &&
                  bleProvider.cc1101Modules!.length > 1)
                StatusIcon(
                  icon: Icons.settings_input_antenna,
                  color: _getModuleColorFromMode(
                      bleProvider.cc1101Modules![1]['mode'] ?? 'Idle'),
                  tooltip:
                      '${AppLocalizations.of(context)!.subGhzModule(2)}: ${bleProvider.cc1101Modules![1]['mode'] ?? AppLocalizations.of(context)!.unknown}',
                  label: '2',
                ),

              const SizedBox(width: 6),

              // 4. NRF24 Module Status
              if (bleProvider.isConnected && bleProvider.nrfInitialized)
                StatusIcon(
                  icon: Icons.router,
                  color: _getNrfStatusColor(bleProvider),
                  tooltip: _getNrfStatusTooltip(bleProvider),
                  label: 'N',
                ),

              const SizedBox(width: 6),

              // 5. Battery Status (SD card moved to Device Status panel)
              if (bleProvider.isConnected && bleProvider.hasBatteryInfo)
                BatteryStatusIcon(
                  percentage: bleProvider.batteryPercent,
                  charging: bleProvider.batteryCharging,
                  voltage: bleProvider.batteryVoltage,
                ),

              const SizedBox(width: 6),

              // 7. Memory Status
              if (bleProvider.isConnected && bleProvider.freeHeap != null)
                MemoryStatusIcon(freeHeap: bleProvider.freeHeap!),

              const SizedBox(width: 6),

              // 8. CPU Temperature + (debug) core clock info
              if (bleProvider.isConnected)
                CpuStatusIcon(
                  temperatureC: bleProvider.cpuTempC,
                  core0Mhz: bleProvider.core0Mhz,
                  core1Mhz: bleProvider.core1Mhz,
                  showCoreClocks: true,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNotificationArea(BuildContext context) {
    return Consumer<NotificationProvider>(
      builder: (context, notificationProvider, _) {
        final notification = notificationProvider.currentNotification;
        final hasHistory = notificationProvider.notificationHistory.isNotEmpty;

        // Show either current notification or button to view history
        if (notification == null) {
          if (!hasHistory) {
            return const SizedBox(width: 1, height: 36);
          }
          // Show button to view history
          return InkWell(
            onTap: () => _showNotificationList(context, notificationProvider),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 16,
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${notificationProvider.notificationHistory.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return InkWell(
          onTap: () => _showNotificationList(context, notificationProvider),
          child: Container(
            alignment: Alignment.centerRight,
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              notification.message,
              style: TextStyle(
                fontSize: 12,
                color: notification.color,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      },
    );
  }

  void _showNotificationList(
      BuildContext context, NotificationProvider notificationProvider) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Consumer<NotificationProvider>(
          builder: (context, provider, _) {
            final hasHistory = provider.notificationHistory.isNotEmpty;
            AppLogger.debug(
                'Notification history length: ${provider.notificationHistory.length}, hasHistory: $hasHistory');
            return Scaffold(
              backgroundColor: Theme.of(context).colorScheme.surface,
              appBar: AppBar(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.notifications,
                      size: 24,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(AppLocalizations.of(context)!.notifications),
                  ],
                ),
                actions: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              body: !hasHistory
                  ? Center(
                      child: Text(
                        AppLocalizations.of(context)!.noNotifications,
                        style: TextStyle(
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color
                              ?.withValues(alpha: 0.5),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        if (hasHistory)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Theme.of(context).dividerColor,
                                  width: 1,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    provider.clearHistory();
                                    Navigator.pop(context);
                                  },
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18),
                                  label: Text(
                                      AppLocalizations.of(context)!.clearAll),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: provider.notificationHistory.length,
                            itemBuilder: (context, index) {
                              final notif = provider.notificationHistory[index];
                              return NotificationListItem(notification: notif);
                            },
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
        fullscreenDialog: false,
      ),
    );
  }

  Color _getModuleColorFromMode(String mode) {
    final statusLower = mode.toLowerCase();
    // For Idle use primaryText (like SD and Heap)
    if (statusLower == 'idle') {
      return AppColors.primaryText;
    }
    // For transmitting/sendsignal use green
    if (statusLower == 'sendsignal' || statusLower == 'transmitting') {
      return AppColors.success;
    }
    // For other statuses use standard function
    return AppColors.getModuleStatusColor(mode);
  }

  /// NRF24 status color: orange when busy, green-white when idle
  Color _getNrfStatusColor(BleProvider bleProvider) {
    if (bleProvider.nrfJammerRunning ||
        bleProvider.nrfScanning ||
        bleProvider.nrfAttacking ||
        bleProvider.nrfSpectrumRunning) {
      return const Color(0xFFFF9100); // Bright orange — very visible
    }
    return AppColors.primaryText; // Idle — same as SD card
  }

  /// NRF24 tooltip text describing current state
  String _getNrfStatusTooltip(BleProvider bleProvider) {
    final l10n = AppLocalizations.of(context)!;
    if (bleProvider.nrfJammerRunning) return l10n.nrf24Jamming;
    if (bleProvider.nrfScanning) return l10n.nrf24Scanning;
    if (bleProvider.nrfAttacking) return l10n.nrf24Attacking;
    if (bleProvider.nrfSpectrumRunning) return l10n.nrf24SpectrumActive;
    return l10n.nrf24Idle;
  }
}
