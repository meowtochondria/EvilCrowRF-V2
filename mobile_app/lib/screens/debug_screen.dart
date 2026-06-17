import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ble_provider.dart';
import '../providers/connection_state_provider.dart';
import '../providers/log_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/files_provider.dart';
import '../providers/wifi_provider.dart';
import '../widgets/log_viewer_widget.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_colors.dart';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final TextEditingController _commandController = TextEditingController();

  @override
  void dispose() {
    _commandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBackground,
      body: Column(
        children: [
          // Compact header
          Container(
            height: 48, // Compact height
            color: AppColors.surfaceElevated,
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                // Back button (no AppBar so this screen needs an explicit one).
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back,
                      color: AppColors.primaryText),
                  tooltip: AppLocalizations.of(context)!.back,
                ),
                const Icon(Icons.bug_report,
                    size: 20, color: AppColors.primaryText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)!.debug,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryText,
                      fontSize: 16,
                    ),
                  ),
                ),
                // Notification bell — mirrors the home-screen status bar
                // so the user has a consistent way to reach the notification
                // history from any sub-screen.
                Consumer<NotificationProvider>(
                  builder: (context, notificationProvider, _) {
                    final count =
                        notificationProvider.notificationHistory.length;
                    return IconButton(
                      onPressed: () => _showNotificationHistory(context),
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.notifications_none,
                              color: AppColors.primaryText),
                          if (count > 0)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: AppColors.error,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                constraints: const BoxConstraints(minWidth: 16),
                                child: Text(
                                  count > 9 ? '9+' : '$count',
                                  style: const TextStyle(
                                    color: AppColors.onButton,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                      tooltip: AppLocalizations.of(context)!.notifications,
                    );
                  },
                ),
                Consumer<LogProvider>(
                  builder: (context, logProvider, child) {
                    return IconButton(
                      onPressed: () => logProvider.clearLogs(),
                      icon: const Icon(Icons.clear_all,
                          color: AppColors.primaryText),
                      tooltip: AppLocalizations.of(context)!.clearAllLogs,
                    );
                  },
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: Consumer2<ConnectionStateProvider, BleProvider>(
              builder: (context, connectionState, bleProvider, child) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Connection Status Card — shows both BLE and WiFi
                      // transports so the debug screen reflects the real
                      // connection state regardless of which transport the
                      // device is using.
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    connectionState.isConnected
                                        ? _iconForTransport(
                                            connectionState.connectedTransport)
                                        : Icons.cloud_off,
                                    color: connectionState.isConnected
                                        ? AppColors.success
                                        : AppColors.error,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    AppLocalizations.of(context)!
                                        .connectionStatus,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.primaryText,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Transport-specific status line
                              _buildTransportStatusLine(
                                  context, connectionState, bleProvider),
                              if (connectionState.isConnected) ...[
                                const SizedBox(height: 8),
                                _buildActiveDeviceLine(
                                    context, connectionState, bleProvider),
                              ],
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Command Input
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.sendCommand,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryText,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _commandController,
                                      decoration: InputDecoration(
                                        labelText: AppLocalizations.of(context)!
                                            .enterCommand,
                                        border: const OutlineInputBorder(),
                                        hintText: AppLocalizations.of(context)!
                                            .commandHint,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () {
                                            if (_commandController
                                                .text.isNotEmpty) {
                                              bleProvider.sendCommand(
                                                  _commandController.text);
                                              _commandController.clear();
                                            }
                                          }
                                        : null,
                                    child: bleProvider.isLoadingFiles
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : Text(
                                            AppLocalizations.of(context)!.send),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Debug Controls
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.debugControls,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryText,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Connection Controls
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: bleProvider.isConnected
                                        ? () => bleProvider.disconnect()
                                        : null,
                                    icon: const Icon(Icons.bluetooth_disabled),
                                    label: Text(AppLocalizations.of(context)!
                                        .disconnect),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.error,
                                      foregroundColor: AppColors.onButton,
                                    ),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        bleProvider.clearKnownDevice(),
                                    icon: const Icon(Icons.clear_all),
                                    label: Text(AppLocalizations.of(context)!
                                        .clearCachedDevice),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.statusOrange,
                                      foregroundColor: AppColors.onBright,
                                    ),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed: () => context
                                        .read<FilesProvider>()
                                        .clearFileCache(),
                                    icon: const Icon(Icons.folder_delete),
                                    label: Text(AppLocalizations.of(context)!
                                        .clearFileCache),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.statusOrange,
                                      foregroundColor: AppColors.onBright,
                                    ),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        bleProvider.requestPermissions(),
                                    icon: const Icon(Icons.security),
                                    label: Text(AppLocalizations.of(context)!
                                        .requestPermissions),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 16),

                              // Test Commands
                              Text(
                                AppLocalizations.of(context)!.testCommands,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () => bleProvider.sendCommand('SCAN')
                                        : null,
                                    child: const Text('SCAN'),
                                  ),
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () =>
                                            bleProvider.sendCommand('RECORD')
                                        : null,
                                    child: const Text('RECORD'),
                                  ),
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () => bleProvider.sendCommand('PLAY')
                                        : null,
                                    child: const Text('PLAY'),
                                  ),
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () => bleProvider.sendCommand('STOP')
                                        : null,
                                    child: const Text('STOP'),
                                  ),
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () =>
                                            bleProvider.sendCommand('REBOOT')
                                        : null,
                                    child: Text(AppLocalizations.of(context)!
                                        .rebootDevice),
                                  ),
                                  ElevatedButton(
                                    onPressed: bleProvider.isConnected &&
                                            !bleProvider.isLoadingFiles
                                        ? () => bleProvider.refreshFileList()
                                        : null,
                                    child: bleProvider.isLoadingFiles
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : Text(AppLocalizations.of(context)!
                                            .refreshFiles),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // CPU Temperature Offset (Debug)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.cpuTempOffset,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryText,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                AppLocalizations.of(context)!.cpuTempOffsetDesc,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: AppColors.greyDarker,
                                    ),
                              ),
                              const SizedBox(height: 12),
                              Consumer<SettingsProvider>(
                                builder: (context, settingsProvider, child) {
                                  final offset =
                                      settingsProvider.cpuTempOffsetDeciC;
                                  final offsetC = offset / 10.0;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${offsetC.toStringAsFixed(1)} C',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      Slider(
                                        value: offsetC.clamp(-50.0, 50.0),
                                        min: -50,
                                        max: 50,
                                        divisions: 200,
                                        label:
                                            '${offsetC.toStringAsFixed(1)} C',
                                        onChanged: (value) {
                                          final deciC = (value * 10).round();
                                          settingsProvider
                                              .setCpuTempOffsetDeciC(deciC);
                                        },
                                      ),
                                    ],
                                  );
                                },
                              ),
                              if (!bleProvider.isConnected)
                                Text(
                                  AppLocalizations.of(context)!
                                      .connectToDeviceToApply,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: AppColors.greyDark,
                                      ),
                                ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Logs Section
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.activityLogs,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.primaryText,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 16),
                              const SizedBox(
                                height: 300,
                                child: LogViewerWidget(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    if (status.contains('permissions denied') ||
        status.contains('not granted') ||
        status.contains('error')) {
      return AppColors.error;
    }
    if (status.contains('Connected')) return AppColors.success;
    if (status.contains('Scanning') || status.contains('Connecting')) {
      return AppColors.statusBlue;
    }
    return AppColors.greyDark;
  }

  /// Pick the appropriate connection icon for the active transport.
  static IconData _iconForTransport(String? transport) {
    switch (transport) {
      case 'ble':
        return Icons.bluetooth_connected;
      case 'wifi':
        return Icons.wifi;
      default:
        return Icons.cloud_off;
    }
  }

  /// Build a status line describing the BLE/WiFi state.
  ///
  /// Shows the active transport and a short descriptor (e.g. "BLE: Connected
  /// to EvilCrow_RF2", "WiFi: 192.168.4.1", or per-transport diagnostic
  /// messages when disconnected).
  Widget _buildTransportStatusLine(
    BuildContext context,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    final transport = connectionState.connectedTransport;
    final l10n = AppLocalizations.of(context)!;

    String line;
    Color color = AppColors.primaryText;

    if (transport == 'ble') {
      line = 'BLE: ${bleProvider.statusMessage}';
      color = _getStatusColor(bleProvider.statusMessage);
    } else if (transport == 'wifi') {
      final wifi = context.read<WifiProvider>();
      final host = wifi.deviceHost ?? '—';
      line = 'WiFi: connected to $host';
      color = AppColors.success;
    } else {
      // Disconnected: surface whatever the BLE provider last reported.
      line = bleProvider.statusMessage.isEmpty
          ? l10n.notConnectedToDevice
          : bleProvider.statusMessage;
      color = _getStatusColor(bleProvider.statusMessage);
    }

    return Text(
      line,
      style: TextStyle(color: color),
    );
  }

  /// Show the active device's identifier (BLE name + id, or WiFi host).
  Widget _buildActiveDeviceLine(
    BuildContext context,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final transport = connectionState.connectedTransport;

    if (transport == 'wifi') {
      final wifi = context.read<WifiProvider>();
      final host = wifi.deviceHost ?? '—';
      return Text(l10n.deviceLabel('WiFi: $host'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.deviceLabel(bleProvider.savedDeviceName)),
        Text(l10n.deviceIdLabel(bleProvider.savedDeviceId ?? 'Unknown')),
      ],
    );
  }

  /// Open the notification history (mirrors the home status bar behaviour).
  void _showNotificationHistory(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Consumer<NotificationProvider>(
          builder: (context, provider, _) {
            final hasHistory = provider.notificationHistory.isNotEmpty;
            return Scaffold(
              backgroundColor: Theme.of(context).colorScheme.surface,
              appBar: AppBar(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications,
                        size: 24, color: Theme.of(context).colorScheme.primary),
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
                              ?.withOpacity(0.5),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: provider.notificationHistory.length,
                      itemBuilder: (context, index) {
                        final entry = provider.notificationHistory[
                            provider.notificationHistory.length - 1 - index];
                        return ListTile(
                          leading: Icon(
                            entry.icon,
                            color: entry.color,
                          ),
                          title: Text(entry.message,
                              style: TextStyle(color: entry.color)),
                          subtitle: Text(_formatTimestamp(entry.timestamp)),
                        );
                      },
                    ),
            );
          },
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime ts) {
    final now = DateTime.now();
    final diff = now.difference(ts);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} '
        '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
  }
}
