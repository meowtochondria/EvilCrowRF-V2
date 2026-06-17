import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/bruter_protocol.dart';
import '../providers/bruter_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';

/// BruterProtocol + bruterProtocols list extracted to
/// lib/models/bruter_protocol.dart (M4 of refactor.md).


/// bruterCategories getter removed — use getBruterCategories() from
/// lib/models/bruter_protocol.dart (M4 of refactor.md).
/// Brute force attack screen
class BruteScreen extends StatefulWidget {
  const BruteScreen({super.key});

  @override
  State<BruteScreen> createState() => _BruteScreenState();
}

/// Map from standard protocol menuId to its De Bruijn equivalent menuId.
/// NOTE: This map is kept for reference only. In De Bruijn mode, the app now
/// sends a custom 0xFD command with the protocol's own Te, ratio, bits, and
/// frequency — ensuring correct per-protocol timing and frequency.
/// The hardcoded De Bruijn menus (35-39) remain available as standalone entries.
// ignore: unused_element
const Map<int, int> _standardToDeBruijnMap = {
  // CAME, NiceFlo, FAAC, BFT, Clemsa, GateTX, Phox, PhoenixV2, Prastel,
  // Doitrand, Nero, Magellen, Ansonic, EV1527 12b, Honeywell, StarLine,
  // Tedsen, Airforce → DeBruijn Generic 433 (menu 35)
  1: 35, 3: 35, 8: 35, 9: 35, 10: 35, 11: 35, 12: 35,
  14: 35, 15: 35, 16: 35, 17: 35, 18: 35, 19: 35,
  21: 35, 22: 35, 30: 35, 31: 35, 32: 35, 34: 35,
  // Chamberlain, LiftMaster → DeBruijn Generic 315 (menu 36)
  4: 36, 7: 36,
  // Holtek → DeBruijn Holtek (menu 37)
  6: 37,
  // Linear, Firefly → DeBruijn Linear (menu 38)
  5: 38, 23: 38,
  // Hörmann, Marantec, Berner → DeBruijn Generic 433 (closest match at 868 via universal)
  25: 35, 26: 35, 27: 35,
};

class _BruteScreenState extends State<BruteScreen> {
  String _selectedCategory = 'All';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _completionShown = false;

  /// When true, compatible protocols launch in De Bruijn mode (~90x faster)
  bool _useDeBruijnMode = false;

  List<BruterProtocol> get _filteredProtocols {
    var list = bruterProtocols.toList();

    // In De Bruijn mode, hide the dedicated De Bruijn entries and show
    // only standard protocols that are compatible (auto-mapped to DB).
    // In Standard mode, show all protocols including De Bruijn entries.
    if (_useDeBruijnMode) {
      list = list.where((p) => !p.isDeBruijn && p.deBruijnCompatible).toList();
    }

    if (_selectedCategory != 'All') {
      list = list.where((p) => p.category == _selectedCategory).toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list
          .where((p) =>
              p.name.toLowerCase().contains(q) ||
              p.category.toLowerCase().contains(q) ||
              p.frequencyLabel.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<BruterProvider, SettingsProvider>(
      builder: (context, bruterProvider, settingsProvider, child) {
        final isRunning = bruterProvider.isBruterRunning;
        final activeProto = bruterProvider.bruterActiveProtocol;
        final delayMs = settingsProvider.bruterDelayMs;

        // Show completion notification
        if (bruterProvider.lastBruterCompletionStatus >= 0 &&
            !_completionShown) {
          _completionShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final status = bruterProvider.lastBruterCompletionStatus;
            final menuId = bruterProvider.lastBruterCompletionMenuId;
            final protoName = bruterProtocols
                    .where((p) => p.menuId == menuId)
                    .map((p) => p.name)
                    .firstOrNull ??
                'Unknown';

            final notificationProvider =
                Provider.of<NotificationProvider>(context, listen: false);
            final l10n = AppLocalizations.of(context)!;
            if (status == 0) {
              notificationProvider
                  .showSuccess(l10n.bruteForceCompleted(protoName));
            } else if (status == 1) {
              notificationProvider
                  .showInfo(l10n.bruteForceCancelled(protoName));
            } else {
              notificationProvider
                  .showError(l10n.bruteForceErrorMsg(protoName));
            }
            bruterProvider.clearBruterCompletion();
            _completionShown = false;
          });
        } else if (bruterProvider.lastBruterCompletionStatus < 0) {
          _completionShown = false;
        }

        return Column(
          children: [
            // Unified attack banner (running OR paused state)
            if (isRunning || bruterProvider.bruterSavedStateAvailable)
              _buildAttackBanner(
                  context, bruterProvider, isRunning, activeProto),

            // Category filter chips
            _buildCategoryFilter(),

            // Search bar
            _buildSearchBar(),

            // Standard / De Bruijn mode toggle
            _buildModeToggle(),

            // Protocol list
            Expanded(
              child: _filteredProtocols.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      itemCount: _filteredProtocols.length,
                      itemBuilder: (context, index) {
                        final protocol = _filteredProtocols[index];
                        final isActive =
                            isRunning && activeProto == protocol.menuId;
                        return _buildProtocolCard(context, bruterProvider,
                            protocol, isActive, isRunning, delayMs);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Unified banner for running, paused, and resumable attack states
  Widget _buildAttackBanner(BuildContext context, BruterProvider bruterProvider,
      bool isRunning, int activeProto) {
    final bool isPaused =
        !isRunning && bruterProvider.bruterSavedStateAvailable;

    // Determine protocol name and progress values
    final int displayMenuId =
        isPaused ? bruterProvider.bruterSavedMenuId : activeProto;
    final activeName = bruterProtocols
            .where((p) => p.menuId == displayMenuId)
            .map((p) => p.name)
            .firstOrNull ??
        'Protocol $displayMenuId';

    final isDeBruijn = displayMenuId >= 35 && displayMenuId <= 40;
    final unitLabel = isDeBruijn ? 'bits' : 'codes';
    final rateLabel = isDeBruijn ? 'b/s' : 'c/s';

    final int currentCode = isPaused
        ? bruterProvider.bruterSavedCurrentCode
        : bruterProvider.bruterCurrentCode;
    final int totalCodes = isPaused
        ? bruterProvider.bruterSavedTotalCodes
        : bruterProvider.bruterTotalCodes;
    final int percentage = isPaused
        ? bruterProvider.bruterSavedPercentage
        : bruterProvider.bruterPercentage;
    final int codesPerSec = isPaused ? 0 : bruterProvider.bruterCodesPerSec;

    // Calculate ETA (only when running)
    String etaStr = '';
    if (isRunning && codesPerSec > 0 && totalCodes > currentCode) {
      final remainingCodes = totalCodes - currentCode;
      final remainingSecs = remainingCodes / codesPerSec;
      if (remainingSecs < 60) {
        etaStr = '< 1 min';
      } else if (remainingSecs < 3600) {
        etaStr = '~${(remainingSecs / 60).round()} min';
      } else {
        etaStr = '~${(remainingSecs / 3600).round()} hrs';
      }
    }

    // Colors based on state
    final Color bannerColor =
        isPaused ? AppColors.statusBlue : AppColors.warning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        color: bannerColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bannerColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isRunning)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(bannerColor),
                  ),
                )
              else
                Icon(Icons.pause_circle_outline, size: 20, color: bannerColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPaused
                          ? AppLocalizations.of(context)!
                              .pausedProtocol(activeName)
                          : AppLocalizations.of(context)!
                              .bruteForceRunning(activeName),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: bannerColor,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (totalCodes > 0)
                      Text(
                        '$currentCode / $totalCodes $unitLabel ($percentage%)'
                        '${codesPerSec > 0 ? ' · $codesPerSec $rateLabel' : ''}'
                        '${etaStr.isNotEmpty ? ' · ETA: $etaStr' : ''}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: bannerColor.withValues(alpha: 0.8),
                              fontSize: 11,
                            ),
                      ),
                  ],
                ),
              ),
              // PAUSE / RESUME toggle button
              ElevatedButton.icon(
                onPressed: isPaused
                    ? () => _resumeAttack(context, bruterProvider)
                    : () => _pauseAttack(context, bruterProvider),
                icon: Icon(isPaused ? Icons.play_arrow : Icons.pause, size: 18),
                label: Text(isPaused
                    ? AppLocalizations.of(context)!.bruteResume
                    : AppLocalizations.of(context)!.brutePause),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isPaused ? AppColors.statusBlue : AppColors.warning,
                  foregroundColor: AppColors.onBright,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _cancelAttack(context, bruterProvider),
                icon: const Icon(Icons.stop, size: 18),
                label: Text(AppLocalizations.of(context)!.bruteStop),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.onButton,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: totalCodes > 0 ? currentCode / totalCodes : null,
              backgroundColor: bannerColor.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(bannerColor),
              minHeight: 6,
            ),
          ),
          if (isPaused) ...[
            const SizedBox(height: 4),
            Text(
              AppLocalizations.of(context)!.resumeInfo,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: bannerColor.withValues(alpha: 0.6),
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryFilter() {
    final categories = ['All', ...getBruterCategories()];
    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          final cat = categories[index];
          final isSelected = cat == _selectedCategory;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: Text(cat),
              selected: isSelected,
              onSelected: (_) {
                setState(() => _selectedCategory = cat);
              },
              selectedColor: AppColors.primaryAccent.withValues(alpha: 0.2),
              checkmarkColor: AppColors.primaryAccent,
              labelStyle: TextStyle(
                color: isSelected
                    ? AppColors.primaryAccent
                    : AppColors.secondaryText,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
              side: BorderSide(
                color: isSelected
                    ? AppColors.primaryAccent
                    : AppColors.borderDefault,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              visualDensity: VisualDensity.compact,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: AppLocalizations.of(context)!.searchProtocols,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        style: const TextStyle(fontSize: 13),
        onChanged: (value) => setState(() => _searchQuery = value),
      ),
    );
  }

  Widget _buildModeToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.speed, size: 16, color: AppColors.secondaryText),
          const SizedBox(width: 6),
          Text(
            AppLocalizations.of(context)!.attackMode,
            style: TextStyle(color: AppColors.secondaryText, fontSize: 12),
          ),
          const SizedBox(width: 8),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment<bool>(
                value: false,
                label: Text(AppLocalizations.of(context)!.standardMode,
                    style: const TextStyle(fontSize: 11)),
                icon: const Icon(Icons.linear_scale, size: 14),
              ),
              ButtonSegment<bool>(
                  value: true,
                  label: Text(AppLocalizations.of(context)!.deBruijnMode,
                      style: const TextStyle(fontSize: 11)),
                  icon: const Icon(Icons.bolt,
                      size: 14, color: AppColors.deBruijnAccent)),
            ],
            selected: {_useDeBruijnMode},
            onSelectionChanged: (selected) {
              setState(() => _useDeBruijnMode = selected.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: WidgetStateProperty.all(
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              ),
            ),
          ),
          if (_useDeBruijnMode) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: AppLocalizations.of(context)!.deBruijnTooltip,
              child:
                  Icon(Icons.info_outline, size: 14, color: AppColors.success),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 48, color: AppColors.disabledText),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context)!.noProtocolsFound,
            style: TextStyle(color: AppColors.secondaryText),
          ),
        ],
      ),
    );
  }

  Widget _buildProtocolCard(
    BuildContext context,
    BruterProvider bruterProvider,
    BruterProtocol protocol,
    bool isActive,
    bool isAnyRunning,
    int delayMs,
  ) {
    // Vivid yellow tint for DeBruijn protocol cards
    final bool isDeBruijnCard = protocol.isDeBruijn && !isActive;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: isActive
          ? AppColors.warning.withValues(alpha: 0.08)
          : isDeBruijnCard
              ? AppColors.deBruijnAccent.withValues(alpha: 0.10)
              : AppColors.secondaryBackground,
      shape: isDeBruijnCard
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: const BorderSide(color: Color(0xAAFFE600), width: 1.0),
            )
          : null,
      child: InkWell(
        onTap: isAnyRunning
            ? null
            : () => _confirmAndStart(context, bruterProvider, protocol),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // Protocol icon
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isActive
                      ? AppColors.warning.withValues(alpha: 0.2)
                      : protocol.isDeBruijn
                          ? AppColors.deBruijnAccent.withValues(alpha: 0.18)
                          : AppColors.primaryAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  protocol.icon,
                  size: 20,
                  color: isActive
                      ? AppColors.warning
                      : protocol.isDeBruijn
                          ? const Color(
                              0xFFFFE600) // Bright yellow for DeBruijn protocols
                          : AppColors.primaryAccent,
                ),
              ),
              const SizedBox(width: 12),

              // Protocol info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            protocol.name,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: isActive
                                      ? AppColors.warning
                                      : protocol.isDeBruijn
                                          ? const Color(
                                              0xFFFFE600) // Bright yellow for DeBruijn
                                          : AppColors.primaryText,
                                ),
                          ),
                        ),
                        // Frequency badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _getFrequencyColor(protocol.frequencyMhz)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            protocol.frequencyLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: _getFrequencyColor(protocol.frequencyMhz),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${protocol.bits}-bit ${protocol.encoding} · ${protocol.estimatedTimeWithDelay(delayMs)}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppColors.secondaryText,
                                      fontSize: 11,
                                    ),
                          ),
                        ),
                        // De Bruijn compatibility badge for standard protocols
                        if (!protocol.isDeBruijn && protocol.deBruijnCompatible)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              AppLocalizations.of(context)!.deBruijnCompatible,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              // Action indicator
              if (isActive)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.warning),
                  ),
                )
              else if (!isAnyRunning)
                Icon(
                  Icons.play_arrow,
                  size: 20,
                  color: AppColors.primaryAccent.withValues(alpha: 0.5),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getFrequencyColor(double mhz) {
    if (mhz >= 868) return AppColors.statusDeepPurple;
    if (mhz >= 433) return AppColors.primaryAccent;
    if (mhz >= 315) return AppColors.statusTeal;
    return AppColors.statusOrange;
  }

  Future<void> _confirmAndStart(
    BuildContext context,
    BruterProvider bruterProvider,
    BruterProtocol protocol,
  ) async {
    final settingsProvider =
        Provider.of<SettingsProvider>(context, listen: false);
    final delayMs = settingsProvider.bruterDelayMs;

    // Determine if we should use custom De Bruijn (per-protocol timing/freq)
    // instead of hardcoded De Bruijn menus which have fixed frequencies.
    bool useCustomDeBruijn = false;
    int actualMenuId = protocol.menuId;
    String modeSuffix = '';
    if (_useDeBruijnMode &&
        !protocol.isDeBruijn &&
        protocol.deBruijnCompatible) {
      useCustomDeBruijn = true;
      modeSuffix = ' (DeBruijn)';
    }

    final estTime = protocol.estimatedTimeWithDelay(delayMs);

    // Show confirmation dialog with protocol details
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            AppLocalizations.of(context)!.startBruteForceSuffix(modeSuffix)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(AppLocalizations.of(context)!.protocol,
                '${protocol.name}$modeSuffix'),
            _infoRow(AppLocalizations.of(context)!.frequency,
                protocol.frequencyLabel),
            _infoRow(AppLocalizations.of(context)!.keySpace,
                '${protocol.bits}-bit ${protocol.encoding}'),
            if (modeSuffix.isNotEmpty)
              _infoRow(AppLocalizations.of(context)!.modeLabel,
                  AppLocalizations.of(context)!.deBruijnFaster),
            _infoRow(AppLocalizations.of(context)!.delay, '$delayMs ms'),
            _infoRow(AppLocalizations.of(context)!.estTime, estTime),
            const SizedBox(height: 12),
            if (protocol.bits >= 24)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber,
                        color: AppColors.warning, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!
                            .largeKeyspaceWarning(protocol.bits, estTime),
                        style:
                            TextStyle(color: AppColors.warning, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.deviceWillTransmit,
              style: TextStyle(color: AppColors.secondaryText, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: Text(AppLocalizations.of(context)!.start),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      if (useCustomDeBruijn) {
        // Send custom De Bruijn command with per-protocol timing and frequency
        await bruterProvider.sendCustomDeBruijnCommand(
          bits: protocol.bits,
          te: protocol.te,
          ratio: protocol.ratio,
          frequencyMhz: protocol.frequencyMhz,
        );
      } else {
        await bruterProvider.sendBruterCommand(actualMenuId);
      }

      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider.showSuccess(
          AppLocalizations.of(context)!
              .bruteForceStarted('${protocol.name}$modeSuffix'),
        );
      }
    } catch (e) {
      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showError(AppLocalizations.of(context)!.failedToStart('$e'));
      }
    }
  }

  Future<void> _pauseAttack(
      BuildContext context, BruterProvider bruterProvider) async {
    try {
      await bruterProvider.sendBruterPauseCommand();

      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showInfo(AppLocalizations.of(context)!.bruteForcePausing);
      }
    } catch (e) {
      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showError(AppLocalizations.of(context)!.failedToPause('$e'));
      }
    }
  }

  Future<void> _resumeAttack(
      BuildContext context, BruterProvider bruterProvider) async {
    try {
      await bruterProvider.sendBruterResumeCommand();

      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showSuccess(AppLocalizations.of(context)!.bruteForceResumed);
      }
    } catch (e) {
      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showError(AppLocalizations.of(context)!.failedToResume('$e'));
      }
    }
  }

  Future<void> _cancelAttack(
      BuildContext context, BruterProvider bruterProvider) async {
    try {
      await bruterProvider.sendBruterCancelCommand();

      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showSuccess(AppLocalizations.of(context)!.bruteForceStopped);
      }
    } catch (e) {
      if (context.mounted) {
        final notificationProvider =
            Provider.of<NotificationProvider>(context, listen: false);
        notificationProvider
            .showError(AppLocalizations.of(context)!.failedToStop('$e'));
      }
    }
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.secondaryText,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.primaryText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
