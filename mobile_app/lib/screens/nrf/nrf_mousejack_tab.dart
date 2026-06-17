import 'package:flutter/material.dart';
import '../../models/nrf_target.dart';
import '../../theme/app_colors.dart';
import '../../widgets/nrf_section_card.dart';

/// "MouseJack" tab of [NrfScreen] — scans for wireless keyboard / mouse
/// receivers and injects keystrokes or DuckyScript payloads.
///
/// Extracted from `nrf_screen.dart` as part of Milestone 4 (M4) of
/// `docs/refactor.md`.
///
/// The widget owns its own UI state (target selection, hide-unknown toggle,
/// text controllers). Device-side state (targets, scanning/attacking flags)
/// is read from [targets] / [scanning] / [attacking] passed in by the
/// parent, which is responsible for triggering the device commands via
/// the provided callbacks.
class NrfMouseJackTab extends StatefulWidget {
  final List<Map<String, dynamic>> targets;
  final bool scanning;
  final bool attacking;
  final VoidCallback onStartScan;
  final VoidCallback onStopScan;
  final VoidCallback onRefresh;
  final void Function(int targetIndex, String text) onAttackString;
  final void Function(int targetIndex, String path) onAttackDucky;
  final VoidCallback onStopAttack;

  const NrfMouseJackTab({
    super.key,
    required this.targets,
    required this.scanning,
    required this.attacking,
    required this.onStartScan,
    required this.onStopScan,
    required this.onRefresh,
    required this.onAttackString,
    required this.onAttackDucky,
    required this.onStopAttack,
  });

  @override
  State<NrfMouseJackTab> createState() => _NrfMouseJackTabState();
}

class _NrfMouseJackTabState extends State<NrfMouseJackTab> {
  bool _hideUnknown = false;
  int _selectedTargetIndex = -1;
  final TextEditingController _stringController = TextEditingController();
  final TextEditingController _duckyPathController = TextEditingController();

  @override
  void dispose() {
    _stringController.dispose();
    _duckyPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allTargets = widget.targets;
    final targets = _hideUnknown
        ? allTargets.where((t) {
            final code = t['deviceType'] ?? 0;
            return NrfTarget.typeFromCode(code) != 'Unknown';
          }).toList()
        : allTargets;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scan controls
          NrfSectionCard(
            title: 'Scan',
            icon: Icons.radar,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: widget.scanning
                            ? widget.onStopScan
                            : widget.onStartScan,
                        icon: Icon(
                            widget.scanning ? Icons.stop : Icons.play_arrow),
                        label:
                            Text(widget.scanning ? 'Stop Scan' : 'Start Scan'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: widget.scanning
                              ? AppColors.error
                              : AppColors.primaryAccent,
                          foregroundColor: widget.scanning
                              ? AppColors.onButton
                              : AppColors.primaryBackground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: widget.onRefresh,
                      icon: const Icon(Icons.refresh,
                          color: AppColors.primaryAccent),
                      tooltip: 'Refresh targets',
                    ),
                  ],
                ),
                // Hide Unknown toggle
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        height: 24,
                        width: 36,
                        child: Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: _hideUnknown,
                            onChanged: (v) => setState(() {
                              _hideUnknown = v;
                              _selectedTargetIndex = -1;
                            }),
                            activeTrackColor:
                                AppColors.primaryAccent.withValues(alpha: 0.5),
                            activeThumbColor: AppColors.primaryAccent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('Hide Unknown',
                          style: TextStyle(
                              color: AppColors.secondaryText, fontSize: 12)),
                      if (_hideUnknown && allTargets.length != targets.length)
                        Text(
                          '  (${allTargets.length - targets.length} hidden)',
                          style: TextStyle(
                              color: AppColors.disabledText, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                if (widget.scanning)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(
                      color: AppColors.primaryAccent,
                      backgroundColor:
                          AppColors.primaryAccent.withValues(alpha: 0.2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Targets list
          NrfSectionCard(
            title: 'Targets (${targets.length})',
            icon: Icons.devices,
            child: targets.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('No devices found yet',
                        style: TextStyle(
                            color: AppColors.disabledText, fontSize: 13)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: targets.length,
                    itemBuilder: (ctx, idx) => _buildTargetTile(idx, targets),
                  ),
          ),
          const SizedBox(height: 12),

          // Attack controls (visible when target selected)
          if (_selectedTargetIndex >= 0 &&
              _selectedTargetIndex < targets.length)
            _buildAttackSection(),
        ],
      ),
    );
  }

  Widget _buildTargetTile(int index, List<Map<String, dynamic>> targets) {
    final t = targets[index];
    final typeName = NrfTarget.typeFromCode(t['deviceType'] ?? 0);
    final channel = t['channel'] ?? 0;
    final address = t['address'] as List? ?? [];
    final addressHex = address
        .map((b) => (b as int).toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
    final isSelected = _selectedTargetIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTargetIndex = index),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryAccent.withValues(alpha: 0.1)
              : AppColors.surfaceElevated,
          border: Border.all(
            color:
                isSelected ? AppColors.primaryAccent : AppColors.borderDefault,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              typeName == 'Microsoft' || typeName == 'MS Encrypted'
                  ? Icons.window
                  : typeName == 'Logitech'
                      ? Icons.keyboard
                      : Icons.device_unknown,
              color: AppColors.primaryAccent,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(typeName,
                      style: TextStyle(
                          color: AppColors.primaryText,
                          fontWeight: FontWeight.bold)),
                  Text('CH: $channel  Addr: $addressHex',
                      style: TextStyle(
                          color: AppColors.secondaryText, fontSize: 12)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: AppColors.primaryAccent),
          ],
        ),
      ),
    );
  }

  Widget _buildAttackSection() {
    return NrfSectionCard(
      title: 'Attack',
      icon: Icons.bolt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // String injection
          Text('Inject Text',
              style: TextStyle(
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                  fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _stringController,
                  style: const TextStyle(color: AppColors.primaryText),
                  decoration: InputDecoration(
                    hintText: 'Text to inject...',
                    hintStyle: TextStyle(color: AppColors.disabledText),
                    filled: true,
                    fillColor: AppColors.primaryBackground,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: AppColors.borderDefault),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: widget.attacking
                    ? null
                    : () => widget.onAttackString(
                        _selectedTargetIndex, _stringController.text),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryAccent,
                    foregroundColor: AppColors.primaryBackground),
                child: const Text('Send'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // DuckyScript
          Text('DuckyScript',
              style: TextStyle(
                  color: AppColors.primaryText,
                  fontWeight: FontWeight.w500,
                  fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _duckyPathController,
                  style: const TextStyle(color: AppColors.primaryText),
                  decoration: InputDecoration(
                    hintText: '/DATA/DUCKY/payload.txt',
                    hintStyle: TextStyle(color: AppColors.disabledText),
                    filled: true,
                    fillColor: AppColors.primaryBackground,
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: AppColors.borderDefault),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: widget.attacking
                    ? null
                    : () => widget.onAttackDucky(
                        _selectedTargetIndex, _duckyPathController.text),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: AppColors.primaryBackground),
                child: const Text('Run'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Stop button
          if (widget.attacking)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: widget.onStopAttack,
                icon: const Icon(Icons.stop),
                label: const Text('Stop Attack'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: AppColors.onButton),
              ),
            ),
        ],
      ),
    );
  }
}
