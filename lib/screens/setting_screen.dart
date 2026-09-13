import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_translations.dart';
import '../providers/locale_provider.dart';
import '../providers/theme_provider.dart';
import '../services/error_handler_service.dart';
import '../services/pro_service.dart';
import '../theme/colors.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  final ErrorHandlerService _errorHandler = ErrorHandlerService();
  final ProService _proService = ProService();

  bool _notificationsEnabled = true;
  bool _micDefault = true;
  bool _camDefault = true;

  bool _isPro = false;
  DateTime? _proExpiry;
  bool _loadingPro = true;

  String _videoQuality = 'HD (720p)';

  bool _dndEnabled = false;

  TimeOfDay _dndStart = const TimeOfDay(hour: 22, minute: 0);

  TimeOfDay _dndEnd = const TimeOfDay(hour: 8, minute: 0);

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);

    _animCtrl.forward();

    _load();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;

    setState(() {
      _videoQuality = prefs.getString('crux_video_quality') ?? 'HD (720p)';

      _micDefault = prefs.getBool('crux_mic_default') ?? true;

      _camDefault = prefs.getBool('crux_cam_default') ?? true;

      _notificationsEnabled = prefs.getBool('crux_notifications') ?? true;

      _dndEnabled = prefs.getBool('crux_dnd') ?? false;

      _dndStart = TimeOfDay(
        hour: prefs.getInt('crux_dnd_start_h') ?? 22,
        minute: prefs.getInt('crux_dnd_start_m') ?? 0,
      );

      _dndEnd = TimeOfDay(
        hour: prefs.getInt('crux_dnd_end_h') ?? 8,
        minute: prefs.getInt('crux_dnd_end_m') ?? 0,
      );
    });

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    if (uid.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingPro = false;
        });
      }
      return;
    }

    try {
      final doc =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();

      if (!doc.exists) {
        if (mounted) {
          setState(() {
            _loadingPro = false;
          });
        }
        return;
      }

      final data = doc.data()!;

      final isPro = data['isPro'] == true;

      final rawExpiry = data['proExpiresAt'] ?? data['proExpiry'];

      DateTime? expiry;

      if (rawExpiry is Timestamp) {
        expiry = rawExpiry.toDate();
      } else if (rawExpiry is String) {
        expiry = DateTime.tryParse(rawExpiry);
      } else if (rawExpiry is int) {
        expiry = DateTime.fromMillisecondsSinceEpoch(rawExpiry);
      }

      final isValid = isPro && expiry != null && expiry.isAfter(DateTime.now());

      if (!mounted) return;

      setState(() {
        _isPro = isValid;
        _proExpiry = isValid ? expiry : null;
        _loadingPro = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingPro = false;
        });
      }
    }
  }

  Future<void> _pickDndTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _dndStart : _dndEnd,
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.primary,
              surface: AppColors.surfaceElevated,
              onSurface: AppColors.textPrimary,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null) return;

    final prefs = await SharedPreferences.getInstance();

    if (isStart) {
      setState(() {
        _dndStart = picked;
      });

      await prefs.setInt('crux_dnd_start_h', picked.hour);

      await prefs.setInt('crux_dnd_start_m', picked.minute);
    } else {
      setState(() {
        _dndEnd = picked;
      });

      await prefs.setInt('crux_dnd_end_h', picked.hour);

      await prefs.setInt('crux_dnd_end_m', picked.minute);
    }
  }

  String _formatTime(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  String _proExpiryText() {
    if (_proExpiry == null) {
      return '';
    }

    final date = _proExpiry!;

    final days = date.difference(DateTime.now()).inDays;

    if (days <= 0) {
      return 'Expire aujourd\'hui';
    }

    if (days == 1) {
      return 'Expire demain';
    }

    return 'Expire dans $days jours '
        '(${date.day}/${date.month}/${date.year})';
  }

  @override
  Widget build(BuildContext context) {
    final localeProvider = context.watch<LocaleProvider>();

    final lang = localeProvider.locale.languageCode;

    final isDark = context.watch<ThemeProvider>().isDark;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.heroGradient),
        child: FadeTransition(
          opacity: _fadeAnim,
          child: RefreshIndicator(
            onRefresh: () async {
              HapticFeedback.lightImpact();
              await _load();
            },
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverAppBar(
                  expandedHeight: 120,
                  pinned: true,
                  backgroundColor: AppColors.surface,
                  elevation: 0,
                  leading: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _IconBtn(
                      onTap: () {
                        Navigator.pop(context);
                      },
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        color: AppColors.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                  flexibleSpace: FlexibleSpaceBar(
                    background: Container(
                      decoration: const BoxDecoration(
                        gradient: AppColors.heroGradient,
                      ),
                      child: Stack(
                        children: [
                          const Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: AppColors.logoHalo,
                              ),
                            ),
                          ),
                          SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                              child: Align(
                                alignment: Alignment.bottomLeft,
                                child: Text(
                                  AppTranslations.t('settings', lang),
                                  style: GoogleFonts.poppins(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(AppTranslations.t('profile', lang)),

                        GestureDetector(
                          onTap: () {
                            Navigator.pushNamed(context, '/profile');
                          },
                          child: _Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  _profileAvatar(),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          FirebaseAuth
                                                  .instance
                                                  .currentUser
                                                  ?.displayName ??
                                              FirebaseAuth
                                                  .instance
                                                  .currentUser
                                                  ?.email
                                                  ?.split('@')
                                                  .first ??
                                              'Utilisateur',
                                          style: GoogleFonts.poppins(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          FirebaseAuth
                                                  .instance
                                                  .currentUser
                                                  ?.email ??
                                              '',
                                          style: GoogleFonts.poppins(
                                            fontSize: 13,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: AppColors.textTertiary,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 28),

                        _SectionLabel(AppTranslations.t('appearance', lang)),

                        _Card(
                          child: Column(
                            children: [
                              _Tile(
                                icon:
                                    isDark
                                        ? Icons.dark_mode
                                        : Icons.light_mode_outlined,
                                title: AppTranslations.t('dark_mode', lang),
                                subtitle:
                                    isDark
                                        ? AppTranslations.t('enabled', lang)
                                        : AppTranslations.t('disabled', lang),
                                trailing: Switch(
                                  value: isDark,
                                  onChanged: (value) {
                                    HapticFeedback.selectionClick();

                                    context.read<ThemeProvider>().setDarkMode(
                                      value,
                                    );
                                  },
                                  trackColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.overlayMedium
                                        : AppColors.overlayLight;
                                  }),
                                  thumbColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.primary
                                        : AppColors.textTertiary;
                                  }),
                                ),
                              ),
                              const _Hairline(),
                              _Tile(
                                icon: Icons.language_outlined,
                                title: AppTranslations.t('language', lang),
                                subtitle: localeProvider.languageLabel,
                                onTap:
                                    () => _showLanguageDialog(localeProvider),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 28),

                        _SectionLabel(
                          AppTranslations.t('meeting_settings', lang),
                        ),

                        _Card(
                          child: Column(
                            children: [
                              _Tile(
                                icon: Icons.hd_outlined,
                                title: AppTranslations.t('video_quality', lang),
                                subtitle: _videoQuality,
                                onTap: _showQualityDialog,
                              ),
                              const _Hairline(),

                              _Tile(
                                icon: Icons.mic_outlined,
                                title: AppTranslations.t('mic_default', lang),
                                trailing: Switch(
                                  value: _micDefault,
                                  onChanged: (value) async {
                                    HapticFeedback.selectionClick();

                                    setState(() {
                                      _micDefault = value;
                                    });

                                    final prefs =
                                        await SharedPreferences.getInstance();

                                    await prefs.setBool(
                                      'crux_mic_default',
                                      value,
                                    );
                                  },
                                  trackColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.overlayMedium
                                        : AppColors.overlayLight;
                                  }),
                                  thumbColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.primary
                                        : AppColors.textTertiary;
                                  }),
                                ),
                              ),

                              const _Hairline(),

                              _Tile(
                                icon: Icons.videocam_outlined,
                                title: AppTranslations.t('cam_default', lang),
                                trailing: Switch(
                                  value: _camDefault,
                                  onChanged: (value) async {
                                    HapticFeedback.selectionClick();

                                    setState(() {
                                      _camDefault = value;
                                    });

                                    final prefs =
                                        await SharedPreferences.getInstance();

                                    await prefs.setBool(
                                      'crux_cam_default',
                                      value,
                                    );
                                  },
                                  trackColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.overlayMedium
                                        : AppColors.overlayLight;
                                  }),
                                  thumbColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.primary
                                        : AppColors.textTertiary;
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 28),

                        _SectionLabel(AppTranslations.t('notifications', lang)),

                        _Card(
                          child: Column(
                            children: [
                              _Tile(
                                icon: Icons.notifications_outlined,
                                title: AppTranslations.t('push_notifs', lang),
                                subtitle:
                                    _notificationsEnabled
                                        ? AppTranslations.t('enabled', lang)
                                        : AppTranslations.t('disabled', lang),
                                trailing: Switch(
                                  value: _notificationsEnabled,
                                  onChanged: (value) async {
                                    HapticFeedback.selectionClick();

                                    setState(() {
                                      _notificationsEnabled = value;
                                    });

                                    final prefs =
                                        await SharedPreferences.getInstance();

                                    await prefs.setBool(
                                      'crux_notifications',
                                      value,
                                    );
                                  },
                                  trackColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.overlayMedium
                                        : AppColors.overlayLight;
                                  }),
                                  thumbColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.primary
                                        : AppColors.textTertiary;
                                  }),
                                ),
                              ),

                              const _Hairline(),

                              _Tile(
                                icon: Icons.do_not_disturb_on_outlined,
                                title: 'Ne pas déranger',
                                subtitle:
                                    _dndEnabled
                                        ? 'De ${_formatTime(_dndStart)} '
                                            'à ${_formatTime(_dndEnd)}'
                                        : 'Désactivé',
                                trailing: Switch(
                                  value: _dndEnabled,
                                  onChanged: (value) async {
                                    HapticFeedback.selectionClick();

                                    setState(() {
                                      _dndEnabled = value;
                                    });

                                    final prefs =
                                        await SharedPreferences.getInstance();

                                    await prefs.setBool('crux_dnd', value);
                                  },
                                  trackColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.overlayMedium
                                        : AppColors.overlayLight;
                                  }),
                                  thumbColor: WidgetStateProperty.resolveWith<
                                    Color?
                                  >((states) {
                                    return states.contains(WidgetState.selected)
                                        ? AppColors.primary
                                        : AppColors.textTertiary;
                                  }),
                                ),
                              ),

                              if (_dndEnabled) ...[
                                const _Hairline(),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _DndChip(
                                          label: AppTranslations.t(
                                            'start_label',
                                            lang,
                                          ),
                                          value: _formatTime(_dndStart),
                                          onTap:
                                              () => _pickDndTime(isStart: true),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _DndChip(
                                          label: AppTranslations.t(
                                            'end_label',
                                            lang,
                                          ),
                                          value: _formatTime(_dndEnd),
                                          onTap:
                                              () =>
                                                  _pickDndTime(isStart: false),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 28),

                        _SectionLabel(AppTranslations.t('subscription', lang)),

                        GestureDetector(
                          onTap: () async {
                            HapticFeedback.mediumImpact();

                            final uid =
                                FirebaseAuth.instance.currentUser?.uid ?? '';

                            if (_isPro) {
                              if (context.mounted) {
                                _errorHandler.showInfoSnackBar(
                                  context,
                                  'CRUX PRO actif — '
                                  '${_proExpiryText()}',
                                );
                              }
                              return;
                            }

                            try {
                              await _proService.startPayment(
                                userId: uid,
                                userName:
                                    FirebaseAuth
                                        .instance
                                        .currentUser
                                        ?.displayName ??
                                    'Utilisateur',
                                userEmail:
                                    FirebaseAuth.instance.currentUser?.email,
                              );
                            } catch (error) {
                              if (context.mounted) {
                                _errorHandler.showError(
                                  context,
                                  error.toString(),
                                );
                              }
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: AppColors.cardGradient,
                              borderRadius: BorderRadius.circular(
                                AppColors.radiusCard,
                              ),
                              border: Border.all(color: AppColors.border),
                              boxShadow: AppColors.softShadow,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: AppColors.warningSurface,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: AppColors.warning.withValues(
                                        alpha: 0.30,
                                      ),
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.workspace_premium_outlined,
                                    color: AppColors.warning,
                                    size: 23,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _loadingPro
                                            ? AppTranslations.t('loading', lang)
                                            : (_isPro
                                                ? AppTranslations.t(
                                                  'pro_active',
                                                  lang,
                                                )
                                                : AppTranslations.t(
                                                  'pro_inactive',
                                                  lang,
                                                )),
                                        style: GoogleFonts.poppins(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _loadingPro
                                            ? ''
                                            : (_isPro
                                                ? _proExpiryText()
                                                : AppTranslations.t(
                                                  'pro_inactive_sub',
                                                  lang,
                                                )),
                                        style: GoogleFonts.poppins(
                                          fontSize: 12,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_loadingPro)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.warning,
                                    ),
                                  )
                                else if (!_isPro)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.warningSurface,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: AppColors.warning.withValues(
                                          alpha: 0.30,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      AppTranslations.t('activate', lang),
                                      style: GoogleFonts.poppins(
                                        color: AppColors.warning,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  )
                                else
                                  const Icon(
                                    Icons.check_circle_outline,
                                    color: AppColors.primaryDark,
                                    size: 23,
                                  ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 28),

                        if (!_loadingPro && _isPro) ...[
                          const _SectionLabel('PRO'),
                          _Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceElevated,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: AppColors.borderFocused,
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.diamond_outlined,
                                      color: AppColors.primaryDark,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppTranslations.t(
                                            'pro_account',
                                            lang,
                                          ),
                                          style: GoogleFonts.poppins(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 16,
                                            color: AppColors.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          _proExpiryText(),
                                          style: GoogleFonts.poppins(
                                            fontSize: 13,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 28),
                        ],

                        _SectionLabel(AppTranslations.t('about', lang)),

                        _Card(
                          child: Column(
                            children: [
                              _Tile(
                                icon: Icons.info_outline,
                                title: AppTranslations.t('app_name', lang),
                                subtitle: 'CRUX v1.0.0',
                                showChevron: false,
                              ),
                              const _Hairline(),
                              _Tile(
                                icon: Icons.description_outlined,
                                title: AppTranslations.t('terms', lang),
                                // Écran intégré (l'ancien lien externe
                                // crux.app/terms n'existait pas).
                                onTap: () =>
                                    Navigator.pushNamed(context, '/terms'),
                              ),
                              const _Hairline(),
                              _Tile(
                                icon: Icons.privacy_tip_outlined,
                                title: AppTranslations.t('privacy', lang),
                                // Écran intégré (l'ancien lien externe
                                // crux.app/privacy n'existait pas).
                                onTap: () =>
                                    Navigator.pushNamed(context, '/privacy'),
                              ),
                              const _Hairline(),
                              _Tile(
                                icon: Icons.code,
                                title: AppTranslations.t('built_by', lang),
                                subtitle: 'MESCHAC_</>',
                                showChevron: false,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileAvatar() {
    final user = FirebaseAuth.instance.currentUser;

    final initials =
        user?.displayName?.isNotEmpty == true
            ? user!.displayName!
                .split(' ')
                .take(2)
                .where((word) => word.isNotEmpty)
                .map((word) => word[0].toUpperCase())
                .join()
            : (user?.email?.isNotEmpty == true
                ? user!.email![0].toUpperCase()
                : 'U');

    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surfaceElevated,
        border: Border.all(color: AppColors.borderFocused, width: 1.5),
      ),
      child: ClipOval(
        child:
            user?.photoURL != null
                ? Image.network(
                  user!.photoURL!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) {
                    return Center(
                      child: Text(
                        initials,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                        ),
                      ),
                    );
                  },
                )
                : Center(
                  child: Text(
                    initials,
                    style: GoogleFonts.poppins(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                    ),
                  ),
                ),
      ),
    );
  }

  void _showQualityDialog() {
    const qualities = [
      'Basse (360p)',
      'Moyenne (480p)',
      'HD (720p)',
      'Full HD (1080p)',
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final lang = context.read<LocaleProvider>().locale.languageCode;

        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                AppTranslations.t('video_quality', lang),
                style: GoogleFonts.poppins(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              ...qualities.map((quality) {
                final selected = _videoQuality == quality;

                return GestureDetector(
                  onTap: () async {
                    HapticFeedback.selectionClick();

                    setState(() {
                      _videoQuality = quality;
                    });

                    final prefs = await SharedPreferences.getInstance();

                    await prefs.setString('crux_video_quality', quality);

                    if (mounted) {
                      Navigator.pop(context);
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color:
                          selected
                              ? AppColors.overlayMedium
                              : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color:
                            selected
                                ? AppColors.borderFocused
                                : AppColors.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.hd_outlined,
                          color:
                              selected
                                  ? AppColors.primary
                                  : AppColors.textTertiary,
                          size: 22,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          quality,
                          style: GoogleFonts.poppins(
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color:
                                selected
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        if (selected)
                          const Icon(
                            Icons.check_circle,
                            color: AppColors.primary,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _showLanguageDialog(LocaleProvider localeProvider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        final screenHeight = MediaQuery.of(context).size.height;

        return Container(
          constraints: BoxConstraints(maxHeight: screenHeight * 0.80),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Icon(
                          Icons.language_rounded,
                          color: AppColors.primaryDark,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          AppTranslations.t(
                            'language',
                            localeProvider.locale.languageCode,
                          ),
                          style: GoogleFonts.poppins(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${LocaleProvider.languages.length} langues',
                          style: GoogleFonts.poppins(
                            fontSize: 12,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 40),
                  itemCount: LocaleProvider.languages.length,
                  itemBuilder: (ctx, index) {
                    final language = LocaleProvider.languages.keys.elementAt(
                      index,
                    );

                    final selected = localeProvider.languageLabel == language;

                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();

                        context.read<LocaleProvider>().setLanguage(language);

                        Navigator.pop(context);
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color:
                              selected
                                  ? AppColors.overlayMedium
                                  : AppColors.overlayLight,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color:
                                selected
                                    ? AppColors.borderFocused
                                    : AppColors.border,
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              language,
                              style: GoogleFonts.poppins(
                                fontWeight:
                                    selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                fontSize: 15,
                                color:
                                    selected
                                        ? AppColors.textPrimary
                                        : AppColors.textSecondary,
                              ),
                            ),
                            const Spacer(),
                            if (selected)
                              const Icon(
                                Icons.check_circle,
                                color: AppColors.primary,
                                size: 20,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.poppins(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.cardGradient,
        borderRadius: BorderRadius.circular(AppColors.radiusCard),
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.softShadow,
      ),
      child: child,
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap:
          onTap == null
              ? null
              : () {
                HapticFeedback.selectionClick();

                onTap!();
              },
      borderRadius: BorderRadius.circular(AppColors.radiusCard),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.primaryDark, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.poppins(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              trailing ??
                  (onTap != null && showChevron
                      ? const Icon(
                        Icons.chevron_right,
                        color: AppColors.textTertiary,
                        size: 20,
                      )
                      : const SizedBox()),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, indent: 68, color: AppColors.divider);
  }
}

class _IconBtn extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;

  const _IconBtn({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.overlayMedium,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      ),
    );
  }
}

class _DndChip extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DndChip({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.overlayMedium,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 10,
                color: AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: GoogleFonts.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
