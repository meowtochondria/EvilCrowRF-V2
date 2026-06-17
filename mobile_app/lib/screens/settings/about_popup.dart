import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';

/// Developer card data model.
/// To add a new developer, create a [DevProfile] and add it to `_devProfiles`
/// in [AboutPopupState]. See docs/session/ for detailed instructions.
class DevProfile {
  final String name;
  final String role;
  final String githubUrl;
  final String? donateUrl;
  final String? avatarAsset; // Optional: path under assets/images/
  final IconData fallbackIcon;

  const DevProfile({
    required this.name,
    required this.role,
    required this.githubUrl,
    this.donateUrl,
    this.avatarAsset,
    this.fallbackIcon = Icons.person,
  });
}

/// Contributor credit entry for the Special Thanks card.
class _ContributorCredit {
  final String name;
  final String description;
  final String githubUrl;
  final Color nameColor;

  const _ContributorCredit({
    required this.name,
    required this.description,
    required this.githubUrl,
    required this.nameColor,
  });
}

/// "About EvilCrow RF" popup — animated developer showcase.
///
/// Public so it can be invoked from the settings screen via
/// [showAboutDialog].
class AboutPopup extends StatefulWidget {
  const AboutPopup({super.key});

  @override
  State<AboutPopup> createState() => _AboutPopupState();

  /// Convenience entry point used from [SettingsScreen]. Opens a fullscreen
  /// semi-transparent dialog hosting the [AboutPopup].
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierColor: AppColors.primaryBackground.withOpacity(0.7),
      builder: (context) => const AboutPopup(),
    );
  }
}

class _AboutPopupState extends State<AboutPopup>
    with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController(viewportFraction: 0.85);
  int _currentPage = 0;

  static const List<DevProfile> _devProfiles = [
    DevProfile(
      name: 'Senape3000',
      role: 'Creator & Developer',
      githubUrl: 'https://github.com/Senape3000',
      donateUrl: 'https://ko-fi.com/senape3000',
      avatarAsset: 'assets/images/Senape3000_LOGO_resize.png',
      fallbackIcon: Icons.code,
    ),
  ];

  static const List<_ContributorCredit> _contributors = [
    _ContributorCredit(
      name: 'joelsernamoreno',
      description:
          'Hardware design, original firmware, project idea & community',
      githubUrl: 'https://github.com/joelsernamoreno/EvilCrowRF-V2',
      nameColor: Color(0xFFFF6B6B),
    ),
    _ContributorCredit(
      name: 'tutejshy-bit',
      description: 'Original project, first app & firmware version',
      githubUrl: 'https://github.com/tutejshy-bit/tut-rf/',
      nameColor: Color(0xFF64B5F6),
    ),
    _ContributorCredit(
      name: 'realdaveblanch',
      description: 'Original Bruter & DeBruijn sequence features',
      githubUrl: 'https://github.com/realdaveblanch/EvilCrowRf-Bruter',
      nameColor: Color(0xFFFFD54F),
    ),
    _ContributorCredit(
      name: 'ProtoPirate',
      description:
          'Automotive key fob protocol research & reference implementation',
      githubUrl: 'https://protopirate.net/ProtoPirate/ProtoPirate',
      nameColor: Color(0xFF64B5F6),
    ),
  ];

  /// Total pages = dev profiles + 1 (contributors card)
  int get _totalPages => _devProfiles.length + 1;

  late AnimationController _shimmerController;
  String _appVersion = '...';

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _appVersion = 'v${info.version}');
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: 520,
        decoration: BoxDecoration(
          color: AppColors.secondaryBackground,
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: AppColors.primaryAccent.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryAccent.withValues(alpha: 0.15),
              blurRadius: 30,
              spreadRadius: 5,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Column(
                  children: [
                    // Animated title with shimmer
                    AnimatedBuilder(
                      animation: _shimmerController,
                      builder: (context, child) {
                        return ShaderMask(
                          shaderCallback: (bounds) {
                            return LinearGradient(
                              colors: const [
                                AppColors.primaryAccent,
                                AppColors.onButton,
                                AppColors.primaryAccent,
                              ],
                              stops: [
                                (_shimmerController.value - 0.3)
                                    .clamp(0.0, 1.0),
                                _shimmerController.value,
                                (_shimmerController.value + 0.3)
                                    .clamp(0.0, 1.0),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ).createShader(bounds);
                          },
                          child: const Text(
                            'EvilCrow RF V2',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: AppColors.onButton,
                              letterSpacing: 1.5,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppLocalizations.of(context)!.appTagline,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.secondaryText,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primaryAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color:
                                AppColors.primaryAccent.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        _appVersion,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.primaryAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Dev cards carousel (dev profiles + contributors card)
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _totalPages,
                  onPageChanged: (index) {
                    setState(() => _currentPage = index);
                  },
                  itemBuilder: (context, index) {
                    if (index < _devProfiles.length) {
                      return _buildDevCard(_devProfiles[index], index);
                    } else {
                      return _buildContributorsCard();
                    }
                  },
                ),
              ),

              // Page indicator dots
              Padding(
                padding: const EdgeInsets.only(bottom: 16, top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_totalPages, (index) {
                    final isActive = index == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: isActive ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppColors.primaryAccent
                            : AppColors.borderDefault,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build the Special Thanks / Contributors card with scrollable list.
  Widget _buildContributorsCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceElevated,
              const Color(0xFFFF6B6B).withValues(alpha: 0.03),
              const Color(0xFF64B5F6).withValues(alpha: 0.03),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: const Color(0xFFFF6B6B).withValues(alpha: 0.15)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            // Section title with shimmer
            AnimatedBuilder(
              animation: _shimmerController,
              builder: (context, child) {
                return ShaderMask(
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      colors: const [
                        Color(0xFFFF6B6B),
                        Color(0xFF64B5F6),
                        Color(0xFFFFD54F),
                        Color(0xFFFF6B6B),
                      ],
                      stops: [
                        (_shimmerController.value - 0.3).clamp(0.0, 1.0),
                        (_shimmerController.value - 0.1).clamp(0.0, 1.0),
                        (_shimmerController.value + 0.1).clamp(0.0, 1.0),
                        (_shimmerController.value + 0.3).clamp(0.0, 1.0),
                      ],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ).createShader(bounds);
                  },
                  child: Text(
                    AppLocalizations.of(context)!.specialThanks,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.onButton,
                      letterSpacing: 1.0,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Text(
              AppLocalizations.of(context)!.standingOnShoulders,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.secondaryText,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 8),
            const Divider(
                color: AppColors.divider, indent: 20, endIndent: 20, height: 1),
            // Scrollable contributor list
            Expanded(
              child: ListView.separated(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: _contributors.length,
                separatorBuilder: (_, __) => const Divider(
                  color: AppColors.divider,
                  height: 12,
                  indent: 8,
                  endIndent: 8,
                ),
                itemBuilder: (context, index) {
                  final c = _contributors[index];
                  return _buildContributorTile(c);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build a single contributor tile with glowing name.
  Widget _buildContributorTile(_ContributorCredit c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Glowing initial circle
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  c.nameColor.withValues(alpha: 0.3),
                  c.nameColor.withValues(alpha: 0.05),
                ],
              ),
              border: Border.all(color: c.nameColor.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(
                  color: c.nameColor.withValues(alpha: 0.25),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: Text(
                c.name[0].toUpperCase(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: c.nameColor,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Name + description
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Glowing name
                Text(
                  c.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: c.nameColor,
                    shadows: [
                      Shadow(
                          color: c.nameColor.withValues(alpha: 0.6),
                          blurRadius: 6),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  c.description,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.secondaryText,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // GitHub button
          IconButton(
            icon: Icon(Icons.code,
                size: 18, color: c.nameColor.withValues(alpha: 0.8)),
            tooltip: 'GitHub',
            onPressed: () => _launchUrl(c.githubUrl),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildDevCard(DevProfile dev, int index) {
    final cardColors = [
      AppColors.primaryAccent,
      AppColors.success,
      AppColors.warning,
    ];
    final accent = cardColors[index % cardColors.length];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceElevated,
              accent.withValues(alpha: 0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withValues(alpha: 0.2)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Avatar circle
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: 0.3),
                    accent.withValues(alpha: 0.1),
                  ],
                ),
                border:
                    Border.all(color: accent.withValues(alpha: 0.5), width: 2),
              ),
              child: dev.avatarAsset != null
                  ? ClipOval(
                      child: Image.asset(
                        dev.avatarAsset!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            _buildInitialAvatar(dev, accent),
                      ),
                    )
                  : _buildInitialAvatar(dev, accent),
            ),

            const SizedBox(height: 16),

            // Name
            Text(
              dev.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryText,
                letterSpacing: 0.5,
              ),
            ),

            const SizedBox(height: 4),

            // Role badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                dev.role,
                style: TextStyle(
                  fontSize: 12,
                  color: accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // GitHub link button
            OutlinedButton.icon(
              onPressed: () => _launchUrl(dev.githubUrl),
              icon: const Icon(Icons.code, size: 16),
              label: Text(AppLocalizations.of(context)!.githubProfile),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryText,
                side: BorderSide(color: accent.withValues(alpha: 0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),

            if (dev.donateUrl != null) ...[
              const SizedBox(height: 8),
              // Donate link button
              OutlinedButton.icon(
                onPressed: () => _launchUrl(dev.donateUrl!),
                icon: const Icon(Icons.favorite,
                    size: 16, color: Color(0xFFFF6B6B)),
                label: Text(AppLocalizations.of(context)!.donate),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF6B6B),
                  side: BorderSide(
                      color: const Color(0xFFFF6B6B).withValues(alpha: 0.4)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInitialAvatar(DevProfile dev, Color accent) {
    return Center(
      child: Text(
        dev.name.isNotEmpty ? dev.name[0].toUpperCase() : '?',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: accent,
        ),
      ),
    );
  }
}
