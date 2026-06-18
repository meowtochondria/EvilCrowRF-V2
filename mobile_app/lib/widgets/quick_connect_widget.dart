import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../connection/ble_connection_provider.dart';
import '../providers/connection_state_provider.dart';
import '../providers/wifi_provider.dart';
import '../services/connection_history_service.dart';
import '../services/logger_service.dart';
import '../theme/app_colors.dart';

class QuickConnectWidget extends StatefulWidget {
  const QuickConnectWidget({super.key});

  @override
  State<QuickConnectWidget> createState() => _QuickConnectWidgetState();
}

class _QuickConnectWidgetState extends State<QuickConnectWidget> {
  final _wifiHostController = TextEditingController();
  final _wifiIpController = TextEditingController();
  bool _ipFieldValid = false;
  String _ipFieldError = '';

  @override
  void initState() {
    super.initState();
    // Listen for IP text changes so Connect button updates reactively
    _wifiIpController.addListener(_onIpTextChanged);

    // F3/F4: prepopulate the IP field with the last successfully connected
    // host (or the live `deviceHost` if already connected via WiFi).
    _prepopulateFromHistory();
  }

  Future<void> _prepopulateFromHistory() async {
    final lastHost = await ConnectionHistoryService.getLastWifiHost();
    if (lastHost != null && lastHost.isNotEmpty && mounted) {
      // Only set if user hasn't typed anything yet.
      if (_wifiIpController.text.isEmpty) {
        setState(() {
          _wifiIpController.text = lastHost;
        });
        _onIpTextChanged();
      }
    }
  }

  /// Validate the IP/FQDN field value.
  /// Returns true if the text is a valid IPv4/IPv6 address or hostname.
  ///
  /// Uses standard Dart library:
  /// - `InternetAddress.tryParse()` from dart:io for IP addresses
  /// - `Uri.tryParse()` from dart:core for hostname/FQDN validation
  bool _isValidHost(String text) {
    if (text.isEmpty) {
      _ipFieldError = '';
      return false;
    }

    // ── IP address (IPv4 or IPv6) via dart:io ─────────────────
    if (InternetAddress.tryParse(text) != null) {
      _ipFieldError = '';
      return true;
    }

    // ── Hostname / FQDN via Uri ───────────────────────────────
    // Construct a dummy URI and check that the host part is valid
    // and matches the original text (no scheme/port injection).
    try {
      final uri = Uri.tryParse('http://$text');
      if (uri != null &&
          uri.host.isNotEmpty &&
          uri.host == text &&
          uri.path.isEmpty &&
          !text.startsWith('.') &&
          !text.endsWith('.') &&
          !text.contains('..') &&
          text.length <= 253) {
        _ipFieldError = '';
        return true;
      }
    } catch (_) {}

    _ipFieldError = 'Enter a valid IP address or hostname';
    return false;
  }

  void _onIpTextChanged() {
    final text = _wifiIpController.text.trim();
    _isValidHost(text); // Updates _ipFieldError
    _ipFieldValid = text.isNotEmpty && _ipFieldError.isEmpty;
    // Trigger rebuild when IP text changes so Connect button updates
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wifiIpController.removeListener(_onIpTextChanged);
    _wifiHostController.dispose();
    _wifiIpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── BLE section ─────────────────────────────────────────────
        _buildBleSection(context),
        const SizedBox(height: 16),

        // ── WiFi section ────────────────────────────────────────────
        _buildWifiSection(context),
      ],
    );
  }

  // ── BLE Panel ─────────────────────────────────────────────────────

  Widget _buildBleSection(BuildContext context) {
    return Consumer<BleConnectionProvider>(
      builder: (context, bleConn, child) {
        final bool bleUnavailable = _isBleUnavailable(bleConn.statusMessage);

        return Opacity(
          opacity: bleUnavailable ? 0.4 : 1.0,
          child: AbsorbPointer(
            absorbing: bleUnavailable,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header row
                Row(
                  children: [
                    const Icon(Icons.bluetooth,
                        color: AppColors.info, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Bluetooth',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.primaryText,
                          ),
                    ),
                    if (bleConn.isConnected)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
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
                    if (bleUnavailable)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Unavailable',
                          style: TextStyle(
                            color: AppColors.error,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildBleDeviceList(context, bleConn),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _isBleUnavailable(String status) {
    return status.contains('BLE not available') ||
        status.contains('Bluetooth disabled') ||
        status.contains('Bluetooth not available');
  }

  Widget _buildBleDeviceList(
      BuildContext context, BleConnectionProvider bleConn) {
    if (bleConn.isConnected) {
      return Row(
        children: [
          const Icon(Icons.bluetooth_connected,
              size: 16, color: AppColors.success),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              AppLocalizations.of(context)!.connected(bleConn.savedDeviceName),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
          IconButton(
            onPressed: () => bleConn.disconnect(),
            icon: const Icon(Icons.bluetooth_disabled),
            iconSize: 20,
            tooltip: AppLocalizations.of(context)!.disconnect,
            style: IconButton.styleFrom(
              backgroundColor: AppColors.error.withValues(alpha: 0.1),
              foregroundColor: AppColors.error,
              minimumSize: const Size(40, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      );
    }

    if (bleConn.isScanning) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: null,
          icon: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: Text(AppLocalizations.of(context)!.connecting),
        ),
      );
    }

    if (bleConn.savedDeviceId != null) {
      return Column(
        children: [
          _buildBleDeviceTile(
            context,
            bleConn.savedDeviceName,
            bleConn.savedDeviceId!,
            () => bleConn.quickConnect(),
            () {
              bleConn.clearDeviceCache();
              bleConn.statusMessage = '';
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => bleConn.startScan(),
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(AppLocalizations.of(context)!.scanForNewDevices),
            ),
          ),
        ],
      );
    }

    // No saved devices — scan results
    final supported = bleConn.supportedScanResults;
    final bool isFallback = supported.isEmpty && bleConn.scanResults.isNotEmpty;
    final devices = isFallback ? bleConn.scanResults : supported;
    if (devices.isNotEmpty) {
      return Column(
        children: [
          Text(
            isFallback
                ? AppLocalizations.of(context)!.noSupportedDevicesShowAll
                : AppLocalizations.of(context)!
                    .foundSupportedDevicesCount(devices.length),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color:
                      isFallback ? AppColors.warning : AppColors.secondaryText,
                ),
          ),
          const SizedBox(height: 8),
          ...devices.map((result) =>
              _buildBleScanResultTile(context, bleConn, result, isFallback)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => bleConn.startScan(),
              icon: const Icon(Icons.refresh),
              label: Text(AppLocalizations.of(context)!.scanAgain),
            ),
          ),
        ],
      );
    }

    // Default: scan button
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => bleConn.startScan(),
        icon: const Icon(Icons.bluetooth_searching),
        label: Text(AppLocalizations.of(context)!.scanForDevices),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: AppColors.primaryBackground,
        ),
      ),
    );
  }

  Widget _buildBleDeviceTile(BuildContext context, String name, String id,
      VoidCallback onConnect, VoidCallback onForget) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.bluetooth, color: AppColors.info, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
                Text(id,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.secondaryText)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: onConnect,
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: AppColors.primaryBackground,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              minimumSize: const Size(0, 36),
            ),
            child: Text(AppLocalizations.of(context)!.connect),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 36,
            child: OutlinedButton(
              onPressed: onForget,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: const BorderSide(color: AppColors.error),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('Forget', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBleScanResultTile(BuildContext context,
      BleConnectionProvider bleConn, dynamic result, bool isFallback) {
    final deviceId = result.device.id.toString();
    final deviceName = result.device.name.isNotEmpty
        ? result.device.name
        : AppLocalizations.of(context)!.unknownDevice;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderDefault),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            isFallback ? Icons.bluetooth_searching : Icons.bluetooth,
            color: AppColors.info,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(deviceName,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
                Text(deviceId,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.secondaryText)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: () => _connectToBleDevice(bleConn, result.device),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: AppColors.primaryBackground,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              minimumSize: const Size(0, 36),
            ),
            child: Text(AppLocalizations.of(context)!.connect),
          ),
        ],
      ),
    );
  }

  Future<void> _connectToBleDevice(
      BleConnectionProvider bleConn, dynamic device) async {
    try {
      await bleConn.connectToDevice(device);
      await bleConn.saveKnownDevice(device.id.toString());
    } catch (e) {
      AppLogger.severe('Connection failed', e);
    }
  }

  // ── WiFi Panel ─────────────────────────────────────────────────────

  Widget _buildWifiSection(BuildContext context) {
    return Consumer2<WifiProvider, ConnectionStateProvider>(
      builder: (context, wifiProvider, connectionState, child) {
        // F4: when actively connected via WiFi, show the live host in the
        // IP field (read-only style) — disable the field so the user cannot
        // accidentally edit the active address.
        if (connectionState.isConnected &&
            connectionState.connectedTransport == 'wifi' &&
            (wifiProvider.deviceHost ?? '').isNotEmpty &&
            _wifiIpController.text != wifiProvider.deviceHost) {
          _wifiIpController.text = wifiProvider.deviceHost!;
          _onIpTextChanged();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header row
            Row(
              children: [
                const Icon(Icons.wifi, color: AppColors.info, size: 20),
                const SizedBox(width: 8),
                Text(
                  'WiFi',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText,
                      ),
                ),
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
            TextField(
              controller: _wifiHostController,
              decoration: InputDecoration(
                hintText: 'mDNS hostname — e.g. evilcrow',
                prefixIcon: const Icon(Icons.devices, size: 20),
                labelText: 'mDNS Hostname',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
              style: Theme.of(context).textTheme.bodyMedium,
              enabled: !wifiProvider.isConnected && !wifiProvider.isConnecting,
              readOnly: wifiProvider.isConnected,
            ),
            const SizedBox(height: 8),

            // IP/FQDN field
            TextField(
              controller: _wifiIpController,
              decoration: InputDecoration(
                hintText: 'IP or FQDN — 192.168.1.100 or evilcrow.local',
                prefixIcon: const Icon(Icons.language, size: 20),
                labelText: 'IP Address / FQDN',
                errorText: _ipFieldError.isNotEmpty ? _ipFieldError : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
              style: Theme.of(context).textTheme.bodyMedium,
              enabled: !wifiProvider.isConnected && !wifiProvider.isConnecting,
              readOnly: wifiProvider.isConnected,
            ),
            const SizedBox(height: 12),

            // Connect / disconnect buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: wifiProvider.isConnected
                        ? () => wifiProvider.disconnect()
                        : (_ipFieldValid && !wifiProvider.isConnecting)
                            ? () => _connectWifi(wifiProvider)
                            : null,
                    icon: wifiProvider.isConnecting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            wifiProvider.isConnected
                                ? Icons.wifi_off
                                : Icons.wifi,
                            size: 18),
                    label: Text(
                      wifiProvider.isConnecting
                          ? 'Connecting...'
                          : wifiProvider.isConnected
                              ? 'Disconnect'
                              : 'Connect',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: wifiProvider.isConnected
                          ? AppColors.error
                          : Theme.of(context).colorScheme.primary,
                      foregroundColor: AppColors.primaryBackground,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Scan for devices button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: wifiProvider.isConnected || wifiProvider.isScanning
                    ? null
                    : () => _scanWifi(context, wifiProvider),
                icon: wifiProvider.isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find, size: 18),
                label: Text(wifiProvider.isScanning
                    ? 'Scanning...'
                    : 'Scan for devices'),
              ),
            ),

            // Discovered devices
            if (wifiProvider.discoveredDevices.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Found ${wifiProvider.discoveredDevices.length} device(s)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.secondaryText,
                    ),
              ),
              const SizedBox(height: 8),
              ...wifiProvider.discoveredDevices.map((device) => Container(
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
                          onPressed: wifiProvider.isConnected ||
                                  wifiProvider.isConnecting
                              ? null
                              : () =>
                                  _connectWifi(wifiProvider, host: device.host),
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.primary,
                            foregroundColor: AppColors.primaryBackground,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            minimumSize: const Size(0, 32),
                          ),
                          child: const Text('Connect'),
                        ),
                      ],
                    ),
                  )),
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

  Future<void> _connectWifi(WifiProvider wifiProvider, {String? host}) async {
    final target = host ?? _wifiIpController.text.trim();
    if (target.isEmpty) return;
    await wifiProvider.connect(target);
  }

  Future<void> _scanWifi(
      BuildContext context, WifiProvider wifiProvider) async {
    await wifiProvider.startDiscovery();
  }
}
