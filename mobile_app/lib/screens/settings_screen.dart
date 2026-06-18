import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../l10n/app_localizations.dart';
import '../providers/ble_provider.dart';
import '../providers/connection_state_provider.dart';
import '../providers/device_info_provider.dart';
import '../providers/wifi_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/firmware_protocol.dart';
import '../services/update_service.dart';
import '../services/device_preferences_service.dart';
import '../theme/app_colors.dart';
import '../providers/files_provider.dart';
import 'debug_screen.dart';
import 'files_screen.dart';
import 'ota_screen.dart';
import 'settings/about_popup.dart';
import 'settings/subghz_clone_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// True after we sync HW button config from device once.
  bool _hwConfigSynced = false;

  /// Debounce timer for nRF slider auto-send.
  Timer? _nrfDebounceTimer;

  /// Controllers for AP name/password fields.
  final _apNameController = TextEditingController();
  final _apPasswordController = TextEditingController();

  /// Sync controllers from device state when AP config arrives on connect.
  /// Only populates if controllers are currently empty (user has not typed yet).
  void _syncApControllersFromDevice(DeviceInfoProvider deviceInfo) {
    if (_apNameController.text.isEmpty && deviceInfo.wifiApName.isNotEmpty) {
      _apNameController.text = deviceInfo.wifiApName;
    }
    if (_apPasswordController.text.isEmpty &&
        deviceInfo.wifiApPassword.isNotEmpty) {
      _apPasswordController.text = deviceInfo.wifiApPassword;
    }
  }

  @override
  void dispose() {
    _nrfDebounceTimer?.cancel();
    _apNameController.dispose();
    _apPasswordController.dispose();
    super.dispose();
  }

  /// Navigates to DebugScreen.
  void _onDebugTap(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const DebugScreen()),
    );
  }

  /// Map CC1101 TX power dBm to a user-friendly label.
  String _powerLabel(int dBm) {
    if (dBm <= -30) return '-30 dBm (Min)';
    if (dBm >= 10) return '+10 dBm (Max)';
    return '${dBm > 0 ? '+' : ''}$dBm dBm';
  }

  /// CC1101 discrete power levels in dBm.
  static const List<int> _powerLevels = [-30, -20, -15, -10, 0, 5, 7, 10];

  /// Snap a value to the nearest CC1101 power level.
  int _snapToPowerLevel(double value) {
    int closest = _powerLevels[0];
    double minDist = (value - closest).abs().toDouble();
    for (final lvl in _powerLevels) {
      final dist = (value - lvl).abs().toDouble();
      if (dist < minDist) {
        minDist = dist;
        closest = lvl;
      }
    }
    return closest;
  }

  void _showAboutDialog(BuildContext context) {
    AboutPopup.show(context);
  }

  /// Check for app updates on GitHub and show dialog
  Future<void> _checkAppUpdate(BuildContext context) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;

      // Show loading
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.onButton),
                ),
                const SizedBox(width: 12),
                Text(AppLocalizations.of(context)!.checkingForAppUpdates),
              ],
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      final update = await UpdateService.checkAppUpdate(currentVersion);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (update == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(AppLocalizations.of(context)!.appUpToDate(currentVersion)),
            backgroundColor: AppColors.success,
          ),
        );
        return;
      }

      // Show update available dialog
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.system_update_alt,
                  color: AppColors.primaryAccent),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.appUpdateAvailable,
                  style: const TextStyle(
                      color: AppColors.primaryText, fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  AppLocalizations.of(context)!
                      .currentVersionLabel(currentVersion),
                  style: const TextStyle(
                      color: AppColors.secondaryText, fontSize: 13)),
              Text(
                  AppLocalizations.of(context)!
                      .latestVersionLabel(update.version),
                  style: const TextStyle(
                      color: AppColors.success,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(AppLocalizations.of(context)!.changelogLabel,
                  style: const TextStyle(
                      color: AppColors.primaryText,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                child: SingleChildScrollView(
                  child: Text(update.changelog,
                      style: const TextStyle(
                          color: AppColors.secondaryText, fontSize: 12)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.of(context)!.later),
            ),
            if (update.apkUrl != null)
              ElevatedButton.icon(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  _downloadAndInstallApk(context, update);
                },
                icon: const Icon(Icons.download, size: 16),
                label: Text(AppLocalizations.of(context)!.downloadAndInstall),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryAccent,
                  foregroundColor: AppColors.primaryBackground,
                ),
              ),
          ],
        ),
      );
    } on UpdateServiceException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  AppLocalizations.of(context)!.updateCheckFailed(e.message)),
              backgroundColor: AppColors.error),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  /// Download APK and trigger install
  Future<void> _downloadAndInstallApk(
      BuildContext context, AppUpdate update) async {
    if (update.apkUrl == null) return;
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Downloading APK...'),
            duration: Duration(seconds: 30)),
      );
      final apkPath = await UpdateService.downloadApk(update.apkUrl!);
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        // Open the APK for install
        final result = await Process.run('am', [
          'start',
          '-a',
          'android.intent.action.VIEW',
          '-d',
          'file://$apkPath',
          '-t',
          'application/vnd.android.package-archive'
        ]);
        if (result.exitCode != 0) {
          // Fallback: try using content URI
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(AppLocalizations.of(context)!
                    .apkSavedPleaseInstall(apkPath)),
                duration: const Duration(seconds: 5)),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Download failed: $e'),
              backgroundColor: AppColors.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Compact header
          Container(
            height: 48,
            color: AppColors.secondaryBackground,
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              children: [
                const Icon(Icons.settings, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)!.settings,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryText,
                        ),
                  ),
                ),
                // App Update check button
                IconButton(
                  icon: const Icon(Icons.system_update_alt,
                      size: 22, color: AppColors.warning),
                  tooltip: AppLocalizations.of(context)!.checkAppUpdate,
                  onPressed: () => _checkAppUpdate(context),
                ),
                // About button
                IconButton(
                  icon: const Icon(Icons.info_outline,
                      size: 22, color: AppColors.primaryAccent),
                  tooltip: AppLocalizations.of(context)!.about,
                  onPressed: () => _showAboutDialog(context),
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: Consumer3<ConnectionStateProvider, DeviceInfoProvider,
                BleProvider>(
              builder:
                  (context, connectionState, deviceInfo, bleProvider, child) {
                // Sync AP fields from device when config arrives on connect
                _syncApControllersFromDevice(deviceInfo);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ===== SDR MODE (prominent toggle) =====
                      _buildSdrModeSection(
                          context, deviceInfo, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== App Settings (Expandable, collapsed) =====
                      _buildAppSettingsSection(
                          context, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== RF Settings (Expandable, collapsed) =====
                      _buildRFSettingsSection(
                          context, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== HW Buttons (Expandable, collapsed) =====
                      _buildHwButtonsSection(
                          context, deviceInfo, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== nRF24 Settings (Expandable, collapsed) =====
                      _buildNrfSettingsSection(
                          context, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== Firmware Update (Expandable, collapsed) =====
                      _buildFirmwareUpdateSection(
                          context, deviceInfo, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== Connection (WiFi + Bluetooth) =====
                      _buildConnectionSection(
                          context, deviceInfo, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== Others (Expandable, collapsed) =====
                      _buildOthersSection(
                          context, deviceInfo, connectionState, bleProvider),
                      const SizedBox(height: 12),

                      // ===== Device Management (factory reset, format SD) =====
                      _buildDeviceManagementSection(
                          context, connectionState, bleProvider),
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

  /// Build SDR MODE toggle section — prominent card at the top of Settings.
  /// When SDR mode is active, other CC1101 operations (record, TX, detect,
  /// jam) are blocked on the firmware side. The app disables SubGhz controls.
  Widget _buildSdrModeSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    final isActive = deviceInfo.sdrModeActive;
    final isConnected = connectionState.isConnected;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActive ? AppColors.warning : AppColors.borderDefault,
          width: isActive ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.radar,
                  color: isActive ? AppColors.warning : AppColors.primaryAccent,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context)!.sdrMode,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isActive
                              ? AppColors.warning
                              : AppColors.primaryText,
                          fontSize: 18,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isActive
                            ? AppLocalizations.of(context)!
                                .sdrModeActiveSubtitle
                            : AppLocalizations.of(context)!
                                .sdrModeInactiveSubtitle,
                        style: TextStyle(
                          color: isActive
                              ? AppColors.warning
                              : AppColors.secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: isActive,
                  onChanged: isConnected
                      ? (value) async {
                          final cmd = value
                              ? FirmwareBinaryProtocol.createSdrEnableCommand()
                              : FirmwareBinaryProtocol
                                  .createSdrDisableCommand();
                          await bleProvider.sendBinaryCommand(cmd);
                          // Status update will arrive via MSG_SDR_STATUS (0xC4)
                        }
                      : null,
                  activeColor: AppColors.warning,
                  activeTrackColor: AppColors.warning.withValues(alpha: 0.4),
                ),
              ],
            ),
            if (isActive) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: AppColors.warning, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Freq: ${deviceInfo.sdrFrequencyMHz.toStringAsFixed(2)} MHz  •  '
                        'Mod: ${_modLabel(deviceInfo.sdrModulation)}\n'
                        '${AppLocalizations.of(context)!.sdrConnectViaUsb}',
                        style: TextStyle(
                          color: AppColors.warning,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Map CC1101 modulation ID to display label.
  String _modLabel(int mod) {
    switch (mod) {
      case 0:
        return '2-FSK';
      case 1:
        return 'GFSK';
      case 2:
        return 'ASK/OOK';
      case 3:
        return '4-FSK';
      case 4:
        return 'MSK';
      default:
        return 'Unknown';
    }
  }

  /// Build App Settings expandable section (language, cache, permissions, debug).
  Widget _buildAppSettingsSection(
    BuildContext context,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading:
              const Icon(Icons.phone_android, color: AppColors.primaryAccent),
          title: Text(
            AppLocalizations.of(context)!.appSettings,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.appSettingsSubtitle,
            style:
                const TextStyle(color: AppColors.secondaryText, fontSize: 12),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Language Selection
                  Consumer<LocaleProvider>(
                    builder: (context, localeProvider, child) {
                      final l10n = AppLocalizations.of(context)!;
                      return Card(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: ListTile(
                          leading: const Icon(Icons.language),
                          title: Text(l10n.language),
                          subtitle: Text(_getLanguageDisplayName(
                              localeProvider.locale.languageCode, l10n)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showLanguageDialog(
                              context, localeProvider, l10n),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // Action Buttons
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () =>
                            context.read<FilesProvider>().clearFileCache(),
                        icon: const Icon(Icons.folder_delete),
                        label:
                            Text(AppLocalizations.of(context)!.clearFileCache),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.recording,
                          foregroundColor: AppColors.primaryBackground,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: () =>
                            _showClearDeviceCacheDialog(context, bleProvider),
                        icon: const Icon(Icons.bluetooth_disabled),
                        label: Text(
                            AppLocalizations.of(context)!.clearDeviceCache),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.info,
                          foregroundColor: AppColors.primaryBackground,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: connectionState.isConnected
                            ? () => bleProvider.rebootDevice()
                            : null,
                        icon: const Icon(Icons.restart_alt),
                        label: Text(AppLocalizations.of(context)!.rebootDevice),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.warning,
                          foregroundColor: AppColors.primaryBackground,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build the RF Settings expandable section with Bruteforce + Radio sub-sections.
  Widget _buildRFSettingsSection(
    BuildContext context,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.radio, color: AppColors.primaryAccent),
          title: Text(
            AppLocalizations.of(context)!.rfSettings,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.rfSettingsSubtitle,
            style: const TextStyle(
              color: AppColors.secondaryText,
              fontSize: 12,
            ),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),

            // --- Bruteforce Settings ---
            _buildSubSectionHeader(
                Icons.flash_on,
                AppLocalizations.of(context)!.bruteforceSettings,
                AppColors.warning),
            _buildBruteforceSettings(context, bleProvider),

            const SizedBox(height: 8),
            const Divider(color: AppColors.divider, indent: 16, endIndent: 16),

            // --- Radio Settings ---
            _buildSubSectionHeader(
                Icons.cell_tower,
                AppLocalizations.of(context)!.radioSettings,
                AppColors.primaryAccent),
            _buildRadioSettings(context, bleProvider),

            const SizedBox(height: 8),
            const Divider(color: AppColors.divider, indent: 16, endIndent: 16),

            // --- Scanner Settings ---
            _buildSubSectionHeader(
                Icons.search,
                AppLocalizations.of(context)!.scannerSettings,
                AppColors.searching),
            _buildScannerSettings(context, bleProvider),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSubSectionHeader(IconData icon, String title, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: color,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBruteforceSettings(
      BuildContext context, BleProvider bleProvider) {
    return Consumer<SettingsProvider>(
      builder: (context, settingsProvider, child) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Inter-frame delay
              Row(
                children: [
                  const Icon(Icons.timer,
                      size: 18, color: AppColors.secondaryText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context)!
                              .interFrameDelay(settingsProvider.bruterDelayMs),
                          style: const TextStyle(
                            color: AppColors.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          AppLocalizations.of(context)!
                              .delayBetweenTransmissions,
                          style: const TextStyle(
                              color: AppColors.secondaryText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: settingsProvider.bruterDelayMs.toDouble(),
                min: 1,
                max: 100,
                divisions: 99,
                label: '${settingsProvider.bruterDelayMs} ms',
                activeColor: AppColors.warning,
                onChanged: (value) {
                  settingsProvider.sendSettingsToDevice(
                      bruterDelay: value.round());
                },
              ),
              Wrap(
                spacing: 8,
                children: [5, 10, 20, 50].map((ms) {
                  final isSelected = settingsProvider.bruterDelayMs == ms;
                  return ChoiceChip(
                    label: Text('${ms}ms'),
                    selected: isSelected,
                    onSelected: (_) {
                      settingsProvider.sendSettingsToDevice(bruterDelay: ms);
                    },
                    selectedColor: AppColors.warning.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: isSelected
                          ? AppColors.warning
                          : AppColors.secondaryText,
                      fontSize: 12,
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 12),

              // Repeats per code
              Row(
                children: [
                  const Icon(Icons.repeat,
                      size: 18, color: AppColors.secondaryText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context)!
                              .repeatsCount(settingsProvider.bruterRepeats),
                          style: const TextStyle(
                            color: AppColors.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          AppLocalizations.of(context)!.transmissionsPerCode,
                          style: const TextStyle(
                              color: AppColors.secondaryText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: settingsProvider.bruterRepeats.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '${settingsProvider.bruterRepeats}x',
                activeColor: AppColors.warning,
                onChanged: (value) {
                  settingsProvider.sendSettingsToDevice(
                      bruterRepeats: value.round());
                },
              ),

              const SizedBox(height: 8),

              // Bruter TX power
              Row(
                children: [
                  const Icon(Icons.power,
                      size: 18, color: AppColors.secondaryText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context)!
                              .txPowerLevel(settingsProvider.bruterPower),
                          style: const TextStyle(
                            color: AppColors.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          AppLocalizations.of(context)!.bruterTxPowerDesc,
                          style: const TextStyle(
                              color: AppColors.secondaryText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: settingsProvider.bruterPower.toDouble(),
                min: 0,
                max: 7,
                divisions: 7,
                label: 'Level ${settingsProvider.bruterPower}',
                activeColor: AppColors.warning,
                onChanged: (value) {
                  settingsProvider.sendSettingsToDevice(
                      bruterPower: value.round());
                },
              ),

              const SizedBox(height: 12),

              // Bruter module selection
              Row(
                children: [
                  const Icon(Icons.memory,
                      size: 18, color: AppColors.secondaryText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TX Module: ${settingsProvider.bruterModule == 0 ? "Module 1" : "Module 2"}',
                          style: const TextStyle(
                            color: AppColors.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          'CC1101 module used for brute force',
                          style: const TextStyle(
                              color: AppColors.secondaryText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment<int>(
                    value: 0,
                    label: Text('Module 1', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.looks_one, size: 16),
                  ),
                  ButtonSegment<int>(
                    value: 1,
                    label: Text('Module 2', style: TextStyle(fontSize: 12)),
                    icon: Icon(Icons.looks_two, size: 16),
                  ),
                ],
                selected: {settingsProvider.bruterModule},
                onSelectionChanged: (selected) {
                  final mod = selected.first;
                  settingsProvider.setBruterModule(mod);
                },
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRadioSettings(BuildContext context, BleProvider bleProvider) {
    return Consumer<SettingsProvider>(
      builder: (context, settingsProvider, child) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Module 1 TX Power
              _buildModulePowerSlider(
                label: 'CC1101 Module 1',
                currentValue: settingsProvider.radioPowerMod1,
                moduleColor: AppColors.primaryAccent,
                onChanged: (value) {
                  final snapped = _snapToPowerLevel(value);
                  settingsProvider.sendSettingsToDevice(
                      radioPowerMod1: snapped);
                },
              ),

              const SizedBox(height: 8),

              // Module 2 TX Power
              _buildModulePowerSlider(
                label: 'CC1101 Module 2',
                currentValue: settingsProvider.radioPowerMod2,
                moduleColor: AppColors.success,
                onChanged: (value) {
                  final snapped = _snapToPowerLevel(value);
                  settingsProvider.sendSettingsToDevice(
                      radioPowerMod2: snapped);
                },
              ),

              const SizedBox(height: 8),

              // Info card
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 16, color: AppColors.secondaryText),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.txPowerInfoDesc,
                        style: const TextStyle(
                            color: AppColors.secondaryText, fontSize: 11),
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

  Widget _buildModulePowerSlider({
    required String label,
    required int currentValue,
    required Color moduleColor,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: moduleColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$label: ${_powerLabel(currentValue)}',
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: moduleColor,
            thumbColor: moduleColor,
            inactiveTrackColor: moduleColor.withValues(alpha: 0.2),
            overlayColor: moduleColor.withValues(alpha: 0.1),
          ),
          child: Slider(
            value: currentValue.toDouble(),
            min: -30,
            max: 10,
            divisions: 40,
            label: _powerLabel(currentValue),
            onChanged: onChanged,
          ),
        ),
        // Power level chips
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: _powerLevels.map((lvl) {
            final isSelected = currentValue == lvl;
            return ChoiceChip(
              label: Text('${lvl > 0 ? '+' : ''}$lvl'),
              selected: isSelected,
              onSelected: (_) => onChanged(lvl.toDouble()),
              selectedColor: moduleColor.withValues(alpha: 0.2),
              labelStyle: TextStyle(
                color: isSelected ? moduleColor : AppColors.secondaryText,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
              visualDensity: VisualDensity.compact,
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildScannerSettings(BuildContext context, BleProvider bleProvider) {
    return Consumer<SettingsProvider>(
      builder: (context, settingsProvider, child) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── RSSI threshold ──
              Row(
                children: [
                  const Icon(Icons.signal_cellular_alt,
                      size: 18, color: AppColors.secondaryText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context)!
                              .rssiThreshold(settingsProvider.scannerRssi),
                          style: const TextStyle(
                            color: AppColors.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          AppLocalizations.of(context)!.minSignalStrengthDesc,
                          style: const TextStyle(
                              color: AppColors.secondaryText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: settingsProvider.scannerRssi.toDouble(),
                min: -100.0,
                max: -30.0,
                divisions: 70,
                label: '${settingsProvider.scannerRssi} dBm',
                activeColor: AppColors.warning,
                onChanged: (value) {
                  settingsProvider.sendSettingsToDevice(
                      scannerRssi: value.round());
                },
              ),
              Wrap(
                spacing: 8,
                children: [-90, -80, -70, -60, -50].map((rssi) {
                  final isSelected = settingsProvider.scannerRssi == rssi;
                  return ChoiceChip(
                    label: Text('${rssi}dBm'),
                    selected: isSelected,
                    onSelected: (_) {
                      settingsProvider.sendSettingsToDevice(scannerRssi: rssi);
                    },
                    selectedColor: AppColors.searching.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: isSelected
                          ? AppColors.searching
                          : AppColors.secondaryText,
                      fontSize: 11,
                    ),
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Build nRF24 Settings expandable section.
  Widget _buildNrfSettingsSection(
    BuildContext context,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.wifi_tethering, color: AppColors.nrfAccent),
          title: Text(
            AppLocalizations.of(context)!.nrf24Settings,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.nrf24SettingsSubtitle,
            style:
                const TextStyle(color: AppColors.secondaryText, fontSize: 12),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),
            Consumer<SettingsProvider>(
              builder: (context, settingsProvider, child) {
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Info card
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline,
                                size: 16, color: AppColors.secondaryText),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context)!.nrf24ConfigDesc,
                                style: const TextStyle(
                                    color: AppColors.secondaryText,
                                    fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // PA Level
                      Row(
                        children: [
                          const Icon(Icons.power_settings_new,
                              size: 18, color: AppColors.secondaryText),
                          const SizedBox(width: 8),
                          Text(
                            AppLocalizations.of(context)!.paLevel(
                                _nrfPaLabel(settingsProvider.nrfPaLevel)),
                            style: const TextStyle(
                              color: AppColors.primaryText,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        AppLocalizations.of(context)!.transmissionPowerDesc,
                        style: const TextStyle(
                            color: AppColors.secondaryText, fontSize: 11),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [0, 1, 2, 3].map((lvl) {
                          final isSelected = settingsProvider.nrfPaLevel == lvl;
                          return ChoiceChip(
                            label: Text(_nrfPaLabel(lvl)),
                            selected: isSelected,
                            onSelected: (_) {
                              settingsProvider.setNrfPaLevel(lvl);
                              _sendNrfSettings(
                                  context, bleProvider, settingsProvider);
                            },
                            selectedColor:
                                AppColors.nrfAccent.withValues(alpha: 0.2),
                            labelStyle: TextStyle(
                              color: isSelected
                                  ? AppColors.nrfAccent
                                  : AppColors.secondaryText,
                              fontSize: 11,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                            visualDensity: VisualDensity.compact,
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 16),

                      // Data Rate
                      Row(
                        children: [
                          const Icon(Icons.speed,
                              size: 18, color: AppColors.secondaryText),
                          const SizedBox(width: 8),
                          Text(
                            AppLocalizations.of(context)!.nrfDataRate(
                                _nrfDataRateLabel(
                                    settingsProvider.nrfDataRate)),
                            style: const TextStyle(
                              color: AppColors.primaryText,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        AppLocalizations.of(context)!.radioDataRateDesc,
                        style: const TextStyle(
                            color: AppColors.secondaryText, fontSize: 11),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [0, 1, 2].map((dr) {
                          final isSelected = settingsProvider.nrfDataRate == dr;
                          return ChoiceChip(
                            label: Text(_nrfDataRateLabel(dr)),
                            selected: isSelected,
                            onSelected: (_) {
                              settingsProvider.setNrfDataRate(dr);
                              _sendNrfSettings(
                                  context, bleProvider, settingsProvider);
                            },
                            selectedColor:
                                AppColors.nrfAccent.withValues(alpha: 0.2),
                            labelStyle: TextStyle(
                              color: isSelected
                                  ? AppColors.nrfAccent
                                  : AppColors.secondaryText,
                              fontSize: 11,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                            visualDensity: VisualDensity.compact,
                          );
                        }).toList(),
                      ),

                      const SizedBox(height: 16),

                      // Channel
                      Row(
                        children: [
                          const Icon(Icons.tune,
                              size: 18, color: AppColors.secondaryText),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppLocalizations.of(context)!.defaultChannel(
                                      settingsProvider.nrfChannel),
                                  style: const TextStyle(
                                    color: AppColors.primaryText,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  '${2400 + settingsProvider.nrfChannel} MHz (0-125)',
                                  style: const TextStyle(
                                      color: AppColors.secondaryText,
                                      fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: settingsProvider.nrfChannel.toDouble(),
                        min: 0,
                        max: 125,
                        divisions: 125,
                        label:
                            'Ch ${settingsProvider.nrfChannel} (${2400 + settingsProvider.nrfChannel} MHz)',
                        activeColor: AppColors.nrfAccent,
                        onChanged: (value) {
                          settingsProvider.setNrfChannel(value.round());
                          _debouncedSendNrfSettings(
                              context, bleProvider, settingsProvider);
                        },
                      ),

                      const SizedBox(height: 12),

                      // Auto-Retransmit
                      Row(
                        children: [
                          const Icon(Icons.repeat,
                              size: 18, color: AppColors.secondaryText),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppLocalizations.of(context)!.autoRetransmit(
                                      settingsProvider.nrfAutoRetransmit),
                                  style: const TextStyle(
                                    color: AppColors.primaryText,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  AppLocalizations.of(context)!
                                      .retransmitCountDesc,
                                  style: const TextStyle(
                                      color: AppColors.secondaryText,
                                      fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: settingsProvider.nrfAutoRetransmit.toDouble(),
                        min: 0,
                        max: 15,
                        divisions: 15,
                        label: '${settingsProvider.nrfAutoRetransmit}x',
                        activeColor: AppColors.nrfAccent,
                        onChanged: (value) {
                          settingsProvider.setNrfAutoRetransmit(value.round());
                          _debouncedSendNrfSettings(
                              context, bleProvider, settingsProvider);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _nrfPaLabel(int level) {
    switch (level) {
      case 0:
        return 'MIN (-18dBm)';
      case 1:
        return 'LOW (-12dBm)';
      case 2:
        return 'HIGH (-6dBm)';
      case 3:
        return 'MAX (0dBm)';
      default:
        return 'Unknown';
    }
  }

  String _nrfDataRateLabel(int rate) {
    switch (rate) {
      case 0:
        return '1 Mbps';
      case 1:
        return '2 Mbps';
      case 2:
        return '250 Kbps';
      default:
        return 'Unknown';
    }
  }

  /// Debounced auto-send for nRF slider changes (500ms).
  void _debouncedSendNrfSettings(BuildContext context, BleProvider bleProvider,
      SettingsProvider settingsProvider) {
    _nrfDebounceTimer?.cancel();
    _nrfDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _sendNrfSettings(context, bleProvider, settingsProvider);
    });
  }

  void _sendNrfSettings(BuildContext context, BleProvider bleProvider,
      SettingsProvider settingsProvider) async {
    if (!context.read<ConnectionStateProvider>().isConnected) return;
    try {
      // Send NRF settings as a settings sync command
      // Using MSG_SETTINGS_UPDATE (0xC1) with extended NRF payload
      final cmd = FirmwareBinaryProtocol.createNrfSettingsCommand(
        settingsProvider.nrfPaLevel,
        settingsProvider.nrfDataRate,
        settingsProvider.nrfChannel,
        settingsProvider.nrfAutoRetransmit,
      );
      await bleProvider.sendBinaryCommand(cmd);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.nrf24SettingsSent),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!
                .failedToSendNrf24Settings(e.toString())),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  /// Build Firmware Update expandable section.
  /// Currently only shows a "Check FW Version" button that queries the device.
  Widget _buildFirmwareUpdateSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.system_update, color: AppColors.warning),
          title: Text(
            AppLocalizations.of(context)!.firmwareUpdate,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            deviceInfo.firmwareVersion.isNotEmpty
                ? AppLocalizations.of(context)!
                    .deviceFwVersion(deviceInfo.firmwareVersion)
                : AppLocalizations.of(context)!.notConnected,
            style: TextStyle(
              color: deviceInfo.firmwareVersion.isNotEmpty
                  ? AppColors.success
                  : AppColors.secondaryText,
              fontSize: 12,
            ),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info text
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.borderDefault),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 18, color: AppColors.secondaryText),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            AppLocalizations.of(context)!.updateFirmwareDesc,
                            style: const TextStyle(
                                color: AppColors.secondaryText, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // FW version display
                  if (deviceInfo.firmwareVersion.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: AppColors.success.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.memory,
                              size: 20, color: AppColors.success),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocalizations.of(context)!.currentFirmware,
                                style: const TextStyle(
                                  color: AppColors.secondaryText,
                                  fontSize: 11,
                                ),
                              ),
                              Text(
                                'v${deviceInfo.firmwareVersion}',
                                style: const TextStyle(
                                  color: AppColors.success,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 12),

                  // Check button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: connectionState.isConnected
                          ? () => _checkFirmwareVersion(context, bleProvider)
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: Text(AppLocalizations.of(context)!.checkFwVersion),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.warning,
                        foregroundColor: AppColors.primaryBackground,
                        disabledBackgroundColor:
                            AppColors.warning.withValues(alpha: 0.3),
                        disabledForegroundColor: AppColors.disabledText,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // OTA Update button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const OtaScreen()),
                        );
                      },
                      icon: const Icon(Icons.system_update),
                      label: Text(AppLocalizations.of(context)!.otaUpdate),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryAccent,
                        foregroundColor: AppColors.primaryBackground,
                      ),
                    ),
                  ),
                  if (!connectionState.isConnected)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        AppLocalizations.of(context)!.connectToADeviceFirst,
                        style: const TextStyle(
                            color: AppColors.secondaryText, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build Others section (FlipperZero SubGHz DB cloning, etc.)
  Widget _buildOthersSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.miscellaneous_services,
              color: AppColors.primaryAccent),
          title: const Text(
            'Others',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            'Additional tools and utilities',
            style: TextStyle(
              color: AppColors.secondaryText,
              fontSize: 12,
            ),
          ),
          initiallyExpanded: false,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // FlipperZero SubGHz DB Cloning
                  _buildSubGhzDbCloneButton(
                      context, deviceInfo, connectionState, bleProvider),
                  const SizedBox(height: 16),
                  // Debug logs
                  _buildDebugButton(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build the Debug log navigation button.
  Widget _buildDebugButton(BuildContext context) {
    return Card(
      color: AppColors.secondaryBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        leading: const Icon(Icons.bug_report, color: AppColors.warning),
        title: Text(
          AppLocalizations.of(context)!.debug,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            color: AppColors.primaryText,
          ),
        ),
        subtitle: const Text(
          'View debug logs and telemetry',
          style: TextStyle(color: AppColors.secondaryText, fontSize: 12),
        ),
        trailing:
            const Icon(Icons.chevron_right, color: AppColors.secondaryText),
        onTap: () => _onDebugTap(context),
      ),
    );
  }

  Widget _buildSubGhzDbCloneButton(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      color: AppColors.secondaryBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_download,
                    size: 22, color: AppColors.statusOrange),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'FlipperZero SubGHz Database',
                        style: TextStyle(
                          color: AppColors.primaryText,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Download .sub files from Zero-Sploit repo and save to device SDCard in "SUB Files" folder',
                        style: TextStyle(
                          color: AppColors.secondaryText,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: connectionState.isConnected
                    ? () => _startSubGhzDbCloning(context, bleProvider)
                    : null,
                icon: const Icon(Icons.download, size: 18),
                label: Text('Clone SubGHz DB to SDCard'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.statusOrange,
                  foregroundColor: AppColors.onBright,
                  disabledBackgroundColor:
                      AppColors.greyLight.withValues(alpha: 0.3),
                ),
              ),
            ),
            if (!connectionState.isConnected)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Connect to device first',
                  style: TextStyle(
                    color: AppColors.error,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _startSubGhzDbCloning(
      BuildContext context, BleProvider bleProvider) async {
    // Show confirmation dialog first
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.cloud_download, color: AppColors.statusOrange),
            const SizedBox(width: 8),
            Text('Clone SubGHz Database'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will:'),
            const SizedBox(height: 8),
            _cloneInfoRow('1.', 'Download FlipperZero SubGHz DB from GitHub'),
            _cloneInfoRow('2.', 'Extract .sub files keeping folder structure'),
            _cloneInfoRow('3.', 'Create "SUB Files" folder on device SDCard'),
            _cloneInfoRow('4.', 'Upload all .sub files to the device'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: AppColors.warning, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This may take several minutes. Files are uploaded one at a time via BLE to avoid conflicts.',
                      style: TextStyle(color: AppColors.warning, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.download, size: 18),
            label: Text('Start'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.statusOrange,
              foregroundColor: AppColors.onBright,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    // Show progress dialog
    _showSubGhzCloneProgress(context, bleProvider);
  }

  Widget _cloneInfoRow(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(number,
                style: TextStyle(
                    color: AppColors.primaryAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ),
          Expanded(
            child: Text(text,
                style: TextStyle(color: AppColors.primaryText, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  void _showSubGhzCloneProgress(BuildContext context, BleProvider bleProvider) {
    SubGhzCloneDialog.show(context, bleProvider);
  }

  /// Build the Connection section with WiFi and Bluetooth sub-sections.
  Widget _buildConnectionSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Column(
      children: [
        // ── WiFi expandable section ──
        _buildWifiSection(context, deviceInfo, connectionState, bleProvider),
        const SizedBox(height: 12),
        // ── Bluetooth expandable section ──
        _buildBluetoothSection(
            context, deviceInfo, connectionState, bleProvider),
      ],
    );
  }

  // ── Build the WiFi expandable section with connection settings and Access Point.
  Widget _buildWifiSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Consumer<WifiProvider>(
      builder: (context, wifiProvider, child) {
        // Re-read connectionState inside Consumer so the save/apply callbacks
        // see the current value.
        return Card(
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: const Icon(Icons.wifi, color: AppColors.primaryAccent),
              title: const Text(
                'WiFi',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryText,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                wifiProvider.isConnected
                    ? 'Connected to ${wifiProvider.deviceHost}'
                    : 'Connection & Access Point settings',
                style: TextStyle(
                  color: wifiProvider.isConnected
                      ? AppColors.success
                      : AppColors.secondaryText,
                  fontSize: 12,
                ),
              ),
              initiallyExpanded: false,
              children: [
                const Divider(color: AppColors.divider, height: 1),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── WiFi Connection content ──
                      _buildWifiConnectionContent(context),

                      const SizedBox(height: 16),
                      // ── OR separator ──
                      Row(
                        children: [
                          const Expanded(
                              child: Divider(color: AppColors.divider)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'OR',
                              style: TextStyle(
                                color: AppColors.disabledText,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                          const Expanded(
                              child: Divider(color: AppColors.divider)),
                        ],
                      ),

                      const SizedBox(height: 12),
                      _buildAccessPointContent(
                          context, wifiProvider, bleProvider),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAccessPointContent(BuildContext context,
      WifiProvider wifiProvider, BleProvider bleProvider) {
    void _showApplyResultDialog(bool sent) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.secondaryBackground,
          title: Row(
            children: [
              Icon(
                sent ? Icons.wifi : Icons.error,
                color: sent ? AppColors.success : AppColors.error,
                size: 24,
              ),
              const SizedBox(width: 10),
              Text(
                sent ? 'WiFi Credentials Sent' : 'Failed to Send',
                style: TextStyle(
                  color: sent ? AppColors.success : AppColors.error,
                ),
              ),
            ],
          ),
          content: Text(
            sent
                ? 'The device is now attempting to connect to the WiFi network. '
                    'If the connection was lost, enter the device\'s new IP address '
                    'or FQDN in the field above and tap Connect.'
                : 'Could not send the WiFi credentials to the device. '
                    'Make sure the device is still connected.',
            style: const TextStyle(color: AppColors.primaryText, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK',
                  style: TextStyle(color: AppColors.secondaryText)),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Access Point Name (SSID)',
          style: TextStyle(
            color: AppColors.primaryText,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Name of the access point the device will broadcast for configuration.',
          style: TextStyle(color: AppColors.secondaryText, fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _apNameController,
          decoration: InputDecoration(
            hintText: 'e.g. EvilCrow_RF2-AP',
            prefixIcon: const Icon(Icons.wifi_tethering, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          style: Theme.of(context).textTheme.bodyMedium,
          maxLength: 32,
        ),
        const SizedBox(height: 12),
        const Text(
          'Access Point Password',
          style: TextStyle(
            color: AppColors.primaryText,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Optional password for the access point. Leave empty for open AP.',
          style: TextStyle(color: AppColors.secondaryText, fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _apPasswordController,
          decoration: InputDecoration(
            hintText: 'Leave empty for no password',
            prefixIcon: const Icon(Icons.lock, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          style: Theme.of(context).textTheme.bodyMedium,
          obscureText: true,
          maxLength: 64,
        ),
        const SizedBox(height: 12),

        // Save button — enabled when fields are non-empty
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _apNameController,
          builder: (context, _, __) {
            final hasName = _apNameController.text.trim().isNotEmpty;
            return SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: hasName
                    ? () async {
                        if (!context
                            .read<ConnectionStateProvider>()
                            .isConnected) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'No device connected. Connect via WiFi or BLE first.'),
                              backgroundColor: AppColors.error,
                            ),
                          );
                          return;
                        }
                        final name = _apNameController.text.trim();
                        bool success;
                        if (context
                                .read<ConnectionStateProvider>()
                                .connectedTransport ==
                            'ble') {
                          success = await bleProvider.setWifiApConfig(
                            name,
                            _apPasswordController.text.trim(),
                          );
                        } else {
                          final cmd = FirmwareBinaryProtocol
                              .createSetWifiApConfigCommand(
                            name,
                            _apPasswordController.text.trim(),
                          );
                          success = await wifiProvider.sendCommand(cmd);
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(success
                                  ? 'Access Point credentials saved'
                                  : 'Failed to save Access Point credentials'),
                              backgroundColor:
                                  success ? AppColors.success : AppColors.error,
                            ),
                          );
                        }
                      }
                    : null,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save Access Point'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.warning,
                  foregroundColor: AppColors.onBright,
                  disabledBackgroundColor:
                      AppColors.warning.withValues(alpha: 0.3),
                ),
              ),
            );
          },
        ),

        const SizedBox(height: 16),

        // Apply button — enabled when name is non-empty
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _apNameController,
          builder: (context, _, __) {
            final hasName = _apNameController.text.trim().isNotEmpty;
            return SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: hasName
                    ? () async {
                        if (!context
                            .read<ConnectionStateProvider>()
                            .isConnected) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'No device connected. Connect via WiFi or BLE first.'),
                              backgroundColor: AppColors.error,
                            ),
                          );
                          return;
                        }
                        final ssid = _apNameController.text.trim();
                        final password = _apPasswordController.text.trim();
                        bool sent = false;
                        if (context
                                .read<ConnectionStateProvider>()
                                .connectedTransport ==
                            'wifi') {
                          sent = await wifiProvider.applyWifiConfig(
                              ssid, password);
                        } else {
                          final cmd =
                              FirmwareBinaryProtocol.createApplyWifiCommand(
                                  ssid, password);
                          sent = await bleProvider
                              .sendBinaryCommand(cmd)
                              .then((_) => true)
                              .catchError((_) => false);
                        }
                        if (context.mounted) {
                          _showApplyResultDialog(sent);
                        }
                      }
                    : null,
                icon: const Icon(Icons.wifi_find, size: 18),
                label: const Text('Apply'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: AppColors.onBright,
                  disabledBackgroundColor:
                      AppColors.success.withValues(alpha: 0.3),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// Build the Bluetooth expandable section with device name settings.
  Widget _buildBluetoothSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.bluetooth, color: AppColors.info),
          title: const Text(
            'Bluetooth',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            connectionState.isConnected
                ? 'Device: ${deviceInfo.deviceName}'
                : 'Bluetooth device settings',
            style: TextStyle(
              color: connectionState.isConnected
                  ? AppColors.success
                  : AppColors.secondaryText,
              fontSize: 12,
            ),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Device Name ──
                  const Text(
                    'BLE Device Name',
                    style: TextStyle(
                      color: AppColors.primaryText,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Change the Bluetooth name of your device. Takes effect after reboot.',
                    style:
                        TextStyle(color: AppColors.secondaryText, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.borderDefault),
                          ),
                          child: Text(
                            deviceInfo.deviceName,
                            style: const TextStyle(
                              color: AppColors.primaryText,
                              fontSize: 14,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: connectionState.isConnected
                            ? () => _showChangeNameDialog(context, bleProvider)
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryAccent,
                          foregroundColor: AppColors.primaryBackground,
                          disabledBackgroundColor:
                              AppColors.primaryAccent.withValues(alpha: 0.3),
                        ),
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build Device Management section (Format SD, Factory Reset).
  Widget _buildDeviceManagementSection(
    BuildContext context,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.build_circle, color: AppColors.info),
          title: const Text(
            'Device Management',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            connectionState.isConnected
                ? 'Format SD, Factory Reset'
                : 'Not connected',
            style: TextStyle(
              color: connectionState.isConnected
                  ? AppColors.success
                  : AppColors.secondaryText,
              fontSize: 12,
            ),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Format SD Card ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.warning.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.sd_card_alert,
                                size: 18, color: AppColors.warning),
                            SizedBox(width: 8),
                            Text(
                              'Format SD Card',
                              style: TextStyle(
                                color: AppColors.warning,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Delete all files and folders from the SD card and re-create the default directory structure. This cannot be undone.',
                          style: TextStyle(
                              color: AppColors.secondaryText, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: connectionState.isConnected
                                ? () =>
                                    _showFormatSDDialog(context, bleProvider)
                                : null,
                            icon: const Icon(Icons.sd_card),
                            label: const Text('Format SD Card'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.warning,
                              foregroundColor: AppColors.onBright,
                              disabledBackgroundColor:
                                  AppColors.warning.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── Factory Reset ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.warning_amber,
                                size: 18, color: AppColors.error),
                            SizedBox(width: 8),
                            Text(
                              'Factory Reset',
                              style: TextStyle(
                                color: AppColors.error,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Erase all settings and data from the device flash memory and reboot with factory defaults. This cannot be undone.',
                          style: TextStyle(
                              color: AppColors.secondaryText, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: connectionState.isConnected
                                ? () => _showFactoryResetDialog(
                                    context, bleProvider)
                                : null,
                            icon: const Icon(Icons.delete_forever),
                            label: const Text('Factory Reset'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.error,
                              foregroundColor: AppColors.onButton,
                              disabledBackgroundColor:
                                  AppColors.error.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (!connectionState.isConnected)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Connect to a device first',
                        style: TextStyle(
                            color: AppColors.secondaryText, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build the WiFi connection controls inside Device Management.
  Widget _buildWifiConnectionContent(BuildContext context) {
    return Consumer<WifiProvider>(
      builder: (context, wifiProvider, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            Row(
              children: [
                if (wifiProvider.isConnected)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Connected',
                      style: TextStyle(
                        color: AppColors.success,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // mDNS hostname field
            const Text(
              'mDNS Hostname',
              style: TextStyle(
                color: AppColors.primaryText,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'e.g. evilcrow',
                      prefixIcon: const Icon(Icons.devices, size: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      isDense: true,
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                    enabled:
                        !wifiProvider.isConnected && !wifiProvider.isConnecting,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: wifiProvider.isConnected || wifiProvider.isScanning
                      ? null
                      : () => wifiProvider.startDiscovery(),
                  child: wifiProvider.isScanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Search'),
                ),
              ],
            ),

            const SizedBox(height: 16),
            // ── OR separator ──
            Row(
              children: [
                const Expanded(child: Divider(color: AppColors.divider)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'OR',
                    style: TextStyle(
                      color: AppColors.disabledText,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const Expanded(child: Divider(color: AppColors.divider)),
              ],
            ),

            // IP/FQDN field
            const Text(
              'IP Address / FQDN',
              style: TextStyle(
                color: AppColors.primaryText,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '192.168.1.100 or evilcrow.local',
                      prefixIcon: const Icon(Icons.language, size: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      isDense: true,
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                    enabled:
                        !wifiProvider.isConnected && !wifiProvider.isConnecting,
                  ),
                ),
                const SizedBox(width: 8),
                if (wifiProvider.isConnected)
                  ElevatedButton(
                    onPressed: () => wifiProvider.disconnect(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: AppColors.primaryBackground,
                    ),
                    child: const Text('Disconnect'),
                  ),
              ],
            ),

            const SizedBox(height: 16),

            // Discovered devices
            if (wifiProvider.discoveredDevices.isNotEmpty) ...[
              const Text(
                'Discovered Devices',
                style: TextStyle(
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              ...wifiProvider.discoveredDevices.map(
                (device) => Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.borderDefault),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi, color: AppColors.info, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                            Text(
                              device.host,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: AppColors.secondaryText),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: wifiProvider.isConnected
                            ? null
                            : () => wifiProvider.connect(device.host),
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Error message
            if (wifiProvider.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                wifiProvider.lastError!,
                style: const TextStyle(color: AppColors.error, fontSize: 12),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Show dialog to change BLE device name.
  void _showChangeNameDialog(BuildContext context, BleProvider bleProvider) {
    final controller = TextEditingController(
        text: context.read<DeviceInfoProvider>().deviceName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.secondaryBackground,
        title: const Text('Change BLE Name',
            style: TextStyle(color: AppColors.primaryText)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter a new name (1-20 characters). Device will need a reboot for the change to take effect.',
              style: TextStyle(color: AppColors.secondaryText, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLength: 20,
              style: const TextStyle(color: AppColors.primaryText),
              decoration: InputDecoration(
                hintText: 'EvilCrow_RF2',
                hintStyle: const TextStyle(color: AppColors.disabledText),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.borderDefault),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.secondaryText)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty || name.length > 20) return;
              Navigator.of(ctx).pop();
              final success = await bleProvider.setDeviceName(name);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success
                        ? 'Device name set to "$name". Reboot to apply.'
                        : 'Failed to set device name.'),
                    backgroundColor:
                        success ? AppColors.success : AppColors.error,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryAccent,
              foregroundColor: AppColors.primaryBackground,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Show factory reset confirmation dialog with Yes/No.
  void _showFactoryResetDialog(BuildContext context, BleProvider bleProvider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.secondaryBackground,
        title: const Row(
          children: [
            Icon(Icons.warning, color: AppColors.error, size: 24),
            SizedBox(width: 10),
            Text('Factory Reset', style: TextStyle(color: AppColors.error)),
          ],
        ),
        content: const Text(
          'Are you sure you want to erase ALL settings and data?\n\n'
          'This will:\n'
          '  - Delete all configuration\n'
          '  - Reset BLE name to default\n'
          '  - Remove all flag files\n'
          '  - Reboot the device\n\n'
          'This action cannot be undone.',
          style: TextStyle(color: AppColors.primaryText, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('No',
                style: TextStyle(color: AppColors.secondaryText, fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final success = await bleProvider.factoryReset();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success
                        ? 'Factory reset initiated. Device will reboot.'
                        : 'Failed to send factory reset command.'),
                    backgroundColor:
                        success ? AppColors.warning : AppColors.error,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.onButton,
            ),
            child: const Text('Yes, Reset', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  /// Show Format SD Card confirmation dialog, then a non-dismissible
  /// progress dialog that auto-closes when the firmware sends the result.
  void _showFormatSDDialog(BuildContext context, BleProvider bleProvider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.secondaryBackground,
        title: const Row(
          children: [
            Icon(Icons.sd_card_alert, color: AppColors.warning, size: 24),
            SizedBox(width: 10),
            Text('Format SD Card', style: TextStyle(color: AppColors.warning)),
          ],
        ),
        content: const Text(
          'Are you sure you want to delete ALL files from the SD card?\n\n'
          'This will:\n'
          '  - Delete all recordings, signals, and presets\n'
          '  - Delete all uploaded .sub files\n'
          '  - Re-create the default directory structure\n\n'
          'This action cannot be undone.',
          style: TextStyle(color: AppColors.primaryText, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('No',
                style: TextStyle(color: AppColors.secondaryText, fontSize: 16)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final sent = await bleProvider.formatSDCard();
              if (!context.mounted) return;
              if (!sent) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Failed to send format SD command.'),
                    backgroundColor: AppColors.error,
                  ),
                );
                return;
              }
              // Show non-dismissible progress dialog; auto-closes on result
              _showSDFormatProgressDialog(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: AppColors.onButton,
            ),
            child: const Text('Yes, Format', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  /// Non-dismissible progress dialog that listens to BleProvider.isFormattingSD
  /// and closes automatically when the firmware result arrives.
  void _showSDFormatProgressDialog(BuildContext context) {
    bool closed = false;
    bool timeoutStarted = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Consumer<BleProvider>(
          builder: (context, ble, _) {
            // Close as soon as formatting is done, regardless of whether
            // intermediate progress messages were received (BLE can drop them).
            if (!ble.isFormattingSD && !closed) {
              closed = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(ble.sdFormatSuccess
                          ? 'SD card formatted successfully.'
                          : 'SD card format failed.'),
                      backgroundColor: ble.sdFormatSuccess
                          ? AppColors.success
                          : AppColors.error,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              });
            }

            // Safety timeout — only start ONCE
            if (ble.isFormattingSD && !timeoutStarted) {
              timeoutStarted = true;
              Future.delayed(const Duration(seconds: 30), () {
                if (ctx.mounted && !closed) {
                  closed = true;
                  Navigator.of(ctx).pop();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('Format timeout: No response from device.'),
                        backgroundColor: AppColors.error,
                        duration: Duration(seconds: 4),
                      ),
                    );
                  }
                }
              });
            }

            return AlertDialog(
              backgroundColor: AppColors.secondaryBackground,
              title: const Row(
                children: [
                  Icon(Icons.sd_card, color: AppColors.warning, size: 24),
                  SizedBox(width: 10),
                  Text('Formatting...',
                      style: TextStyle(color: AppColors.warning)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    ble.sdFormatProgress.isNotEmpty
                        ? ble.sdFormatProgress
                        : 'Formatting SD card, please wait.',
                    style: const TextStyle(color: AppColors.primaryText),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Do not disconnect the device.',
                    style:
                        TextStyle(color: AppColors.secondaryText, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Build HW Buttons configuration section.
  Widget _buildHwButtonsSection(
    BuildContext context,
    DeviceInfoProvider deviceInfo,
    ConnectionStateProvider connectionState,
    BleProvider bleProvider,
  ) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.touch_app, color: AppColors.info),
          title: Text(
            AppLocalizations.of(context)!.hwButtons,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryText,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.configureHwButtonActions,
            style:
                const TextStyle(color: AppColors.secondaryText, fontSize: 12),
          ),
          initiallyExpanded: false,
          children: [
            const Divider(color: AppColors.divider, height: 1),
            Consumer<SettingsProvider>(
              builder: (context, settingsProvider, child) {
                // Reset sync flag on disconnect so we re-sync next time
                if (_hwConfigSynced && !connectionState.isConnected) {
                  _hwConfigSynced = false;
                }
                // Sync HW button config from device once, when 0xC8 arrives
                if (!_hwConfigSynced && deviceInfo.deviceBtn1Action >= 0) {
                  _hwConfigSynced = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    settingsProvider.syncButtonsFromDevice(
                      btn1Action: deviceInfo.deviceBtn1Action,
                      btn2Action: deviceInfo.deviceBtn2Action,
                      btn1PathType: deviceInfo.deviceBtn1PathType,
                      btn2PathType: deviceInfo.deviceBtn2PathType,
                    );
                  });
                }
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Info card
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline,
                                size: 16, color: AppColors.secondaryText),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context)!.hwButtonsDesc,
                                style: const TextStyle(
                                    color: AppColors.secondaryText,
                                    fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Button 1
                      _buildButtonConfig(
                        label: AppLocalizations.of(context)!.button1Gpio34,
                        action: settingsProvider.button1Action,
                        color: AppColors.primaryAccent,
                        replayPath: settingsProvider.button1ReplayPath,
                        onPickReplayFile: () async {
                          await _pickReplaySubFile(
                              context, settingsProvider, 1);
                          if (!context.mounted) return;
                          _sendButtonConfig(
                              context, bleProvider, settingsProvider);
                        },
                        onChanged: (action) {
                          settingsProvider.setButton1Action(action);
                          _sendButtonConfig(
                              context, bleProvider, settingsProvider);
                        },
                      ),

                      const SizedBox(height: 16),

                      // Button 2
                      _buildButtonConfig(
                        label: AppLocalizations.of(context)!.button2Gpio35,
                        action: settingsProvider.button2Action,
                        color: AppColors.warning,
                        replayPath: settingsProvider.button2ReplayPath,
                        onPickReplayFile: () async {
                          await _pickReplaySubFile(
                              context, settingsProvider, 2);
                          if (!context.mounted) return;
                          _sendButtonConfig(
                              context, bleProvider, settingsProvider);
                        },
                        onChanged: (action) {
                          settingsProvider.setButton2Action(action);
                          _sendButtonConfig(
                              context, bleProvider, settingsProvider);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButtonConfig({
    required String label,
    required HwButtonAction action,
    required Color color,
    required String? replayPath,
    required VoidCallback onPickReplayFile,
    required ValueChanged<HwButtonAction> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: HwButtonAction.values.map((a) {
            final isSelected = action == a;
            return GestureDetector(
              onTap: () => onChanged(a),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected
                      ? color.withValues(alpha: 0.2)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected ? color : AppColors.borderDefault,
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(a.icon,
                        size: 14,
                        color: isSelected ? color : AppColors.secondaryText),
                    const SizedBox(width: 4),
                    Text(
                      a.label,
                      style: TextStyle(
                        color: isSelected ? color : AppColors.secondaryText,
                        fontSize: 11,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        if (action == HwButtonAction.replayLast) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  replayPath == null || replayPath.isEmpty
                      ? 'No .sub file selected'
                      : replayPath.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.secondaryText, fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onPickReplayFile,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Select .sub'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _pickReplaySubFile(
    BuildContext context,
    SettingsProvider settingsProvider,
    int buttonId,
  ) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => const FilesScreen(
          pickMode: true,
          allowedExtensions: {'sub'},
        ),
      ),
    );

    if (result == null) return;

    final path = result['path']?.toString();
    final pathType = (result['pathType'] as int?) ?? 1;
    if (path == null || path.isEmpty) return;

    if (buttonId == 1) {
      await settingsProvider.setButton1ReplayFile(path, pathType);
    } else {
      await settingsProvider.setButton2ReplayFile(path, pathType);
    }
  }

  void _sendButtonConfig(BuildContext context, BleProvider bleProvider,
      SettingsProvider settingsProvider) async {
    try {
      final cmd1 = FirmwareBinaryProtocol.createHwButtonConfigCommand(
        1,
        settingsProvider.button1Action.index,
        replayPathType:
            settingsProvider.button1Action == HwButtonAction.replayLast
                ? settingsProvider.button1ReplayPathType
                : null,
        replayPath: settingsProvider.button1Action == HwButtonAction.replayLast
            ? settingsProvider.button1ReplayPath
            : null,
      );
      await bleProvider.sendBinaryCommand(cmd1);

      final cmd2 = FirmwareBinaryProtocol.createHwButtonConfigCommand(
        2,
        settingsProvider.button2Action.index,
        replayPathType:
            settingsProvider.button2Action == HwButtonAction.replayLast
                ? settingsProvider.button2ReplayPathType
                : null,
        replayPath: settingsProvider.button2Action == HwButtonAction.replayLast
            ? settingsProvider.button2ReplayPath
            : null,
      );
      await bleProvider.sendBinaryCommand(cmd2);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.buttonConfigSent),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                AppLocalizations.of(context)!.failedToSendConfig(e.toString())),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  /// Request firmware version from device and show popup.
  void _checkFirmwareVersion(BuildContext context, BleProvider bleProvider) {
    // The FW sends version on getState; request state refresh
    bleProvider.sendGetStateCommand();

    // Show current info (may already be populated from initial connect)
    final version = context.read<DeviceInfoProvider>().firmwareVersion;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.memory, color: AppColors.primaryAccent),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context)!.firmwareInfo,
                  style: const TextStyle(color: AppColors.primaryText)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (version.isNotEmpty) ...[
                Text(
                  AppLocalizations.of(context)!.versionLabel(version),
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocalizations.of(context)!.fwVersionDetails(
                      context.read<DeviceInfoProvider>().fwMajor,
                      context.read<DeviceInfoProvider>().fwMinor,
                      context.read<DeviceInfoProvider>().fwPatch),
                  style: const TextStyle(
                      color: AppColors.secondaryText, fontSize: 12),
                ),
              ] else
                Text(
                  AppLocalizations.of(context)!.waitingForDeviceResponse,
                  style: const TextStyle(color: AppColors.primaryText),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  AppLocalizations.of(context)!.tapOtaUpdateDesc,
                  style: const TextStyle(
                      color: AppColors.secondaryText, fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OtaScreen()),
                );
              },
              child: Text(AppLocalizations.of(context)!.otaUpdate),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.of(context)!.ok),
            ),
          ],
        );
      },
    );
  }

  String _getLanguageDisplayName(String languageCode, AppLocalizations l10n) {
    switch (languageCode) {
      case 'en':
        return l10n.english;
      case 'ru':
        return l10n.russian;
      default:
        return l10n.systemDefault;
    }
  }

  void _showLanguageDialog(BuildContext context, LocaleProvider localeProvider,
      AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final currentLocale = localeProvider.locale;
        return AlertDialog(
          title: Text(
            l10n.selectLanguage,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          content: RadioGroup<String>(
            groupValue: currentLocale.languageCode,
            onChanged: (value) {
              if (value == null) return;
              localeProvider.setLocale(Locale(value));
              Navigator.of(dialogContext).pop();
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  title: Text(
                    l10n.english,
                    style: const TextStyle(color: AppColors.primaryText),
                  ),
                  value: 'en',
                ),
                RadioListTile<String>(
                  title: Text(
                    l10n.russian,
                    style: const TextStyle(color: AppColors.primaryText),
                  ),
                  value: 'ru',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
          ],
        );
      },
    );
  }

  void _showClearDeviceCacheDialog(
      BuildContext context, BleProvider bleProvider) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            l10n.clearDeviceCache,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          content: Text(
            l10n.clearDeviceCacheDescription,
            style: const TextStyle(color: AppColors.primaryText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () async {
                await DevicePreferencesService().clearDeviceId();
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.clearDeviceCache)),
                );
              },
              child: Text(l10n.delete),
            ),
          ],
        );
      },
    );
  }
}

// ============================================================================
// About Popup extracted to screens/settings/about_popup.dart (M4 of refactor.md)
// ============================================================================

/// SubGhzCloneDialog extracted to screens/settings/subghz_clone_dialog.dart (M4).
