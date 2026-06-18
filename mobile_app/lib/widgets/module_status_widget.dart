import 'package:flutter/material.dart';
import 'module_status_basic.dart';
import 'module_status_expanded.dart';

/// Compact widget for displaying CC1101 module status, nRF24 state, and
/// SD card info. Composes [ModuleStatusBasic] (CC1101 cards) and
/// [ModuleStatusExpanded] (nRF + SD cards).
///
/// Split in Milestone 4 (M4) of `docs/refactor.md`: the header + CC1101
/// cards live in `module_status_basic.dart`, the nRF + SD cards live in
/// `module_status_expanded.dart`. This file is a thin facade that preserves
/// the original constructor API.
class ModuleStatusWidget extends StatelessWidget {
  final List<Map<String, dynamic>> cc1101Modules;
  final Map<String, dynamic>? deviceInfo;
  // nRF24 status
  final bool nrfPresent;
  final bool nrfInitialized;
  final bool nrfJammerRunning;
  final bool nrfScanning;
  final bool nrfAttacking;
  final bool nrfSpectrumRunning;
  // SD card status
  final bool sdMounted;
  final int sdTotalMB;
  final int sdFreeMB;

  const ModuleStatusWidget({
    super.key,
    required this.cc1101Modules,
    this.deviceInfo,
    this.nrfPresent = false,
    this.nrfInitialized = false,
    this.nrfJammerRunning = false,
    this.nrfScanning = false,
    this.nrfAttacking = false,
    this.nrfSpectrumRunning = false,
    this.sdMounted = false,
    this.sdTotalMB = 0,
    this.sdFreeMB = 0,
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
            ModuleStatusBasic(
              cc1101Modules: cc1101Modules,
              deviceInfo: deviceInfo,
            ),
            const SizedBox(height: 4),
            ModuleStatusExpanded(
              nrfPresent: nrfPresent,
              nrfInitialized: nrfInitialized,
              nrfJammerRunning: nrfJammerRunning,
              nrfScanning: nrfScanning,
              nrfAttacking: nrfAttacking,
              nrfSpectrumRunning: nrfSpectrumRunning,
              sdMounted: sdMounted,
              sdTotalMB: sdTotalMB,
              sdFreeMB: sdFreeMB,
            ),
          ],
        ),
      ),
    );
  }
}
