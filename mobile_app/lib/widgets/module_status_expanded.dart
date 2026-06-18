/// nRF24 + SD card status cards extracted from `module_status_widget.dart`
/// as part of Milestone 4 (M4) of `docs/refactor.md`.
///
/// Renders the secondary status widgets shown below the CC1101 module cards
/// in the home tab. Composed by `module_status_widget.dart`.
library;

import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Combined "expanded" module-status section: nRF24L01+ state and SD
/// card mount/free-space status. Receives the relevant flags as plain
/// parameters so it doesn't have to know about the providers.
class ModuleStatusExpanded extends StatelessWidget {
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

  const ModuleStatusExpanded({
    super.key,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildNrfCard(context),
        _buildSdCard(context),
      ],
    );
  }

  Widget _buildNrfCard(BuildContext context) {
    // Determine nRF state string and color
    final (stateStr, stateColor) = _resolveNrfState();

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.router,
            size: 18,
            color: stateColor,
          ),
          const SizedBox(width: 8),
          Text(
            'nRF24L01+',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: stateColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              stateStr,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: stateColor,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSdCard(BuildContext context) {
    final (iconColor, statusText) = sdMounted
        ? (AppColors.success, '${sdFreeMB} MB free / ${sdTotalMB} MB')
        : (AppColors.disabledText, 'Not Inserted');

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.sd_card,
            size: 18,
            color: iconColor,
          ),
          const SizedBox(width: 8),
          Text(
            'SD Card',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText,
                ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              statusText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: iconColor,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns the nRF state string + colour for the current flag set.
  (String, Color) _resolveNrfState() {
    if (!nrfPresent) return ('Not Present', AppColors.disabledText);
    if (!nrfInitialized) return ('Not Initialized', AppColors.warning);
    if (nrfJammerRunning) return ('Jamming', AppColors.error);
    if (nrfScanning) return ('Scanning', AppColors.info);
    if (nrfAttacking) return ('Attacking', const Color(0xFFFF9100));
    if (nrfSpectrumRunning) return ('Spectrum', AppColors.info);
    return ('Idle', AppColors.success);
  }
}
