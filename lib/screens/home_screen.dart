import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import '../models/user_model.dart';
import '../services/meeting_service.dart';
import '../wallpaper/wallpaper_provider.dart';
import '../routes/app_routes.dart';
import '../services/schedule_service.dart';
import '../services/user_service.dart';
import '../services/backend_api_service.dart';
import '../theme/colors.dart';
import '../wallpaper/app_background.dart';
import '../utils/logger.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.user,
  });

  final UserModel user;

  @override
  State<HomeScreen> createState() =>
      _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _schedule = ScheduleService();
  final _codeCtrl = TextEditingController();

  int _selectedNav = 0;
  String? _localPhotoPath;

  String get _uid =>
      widget.user.uid.isNotEmpty
          ? widget.user.uid
          : (FirebaseAuth.instance.currentUser?.uid ??
              '');

  String get _displayName =>
      widget.user.name.trim().isNotEmpty
          ? widget.user.name.trim()
          : 'Bienvenue';

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_uid.isNotEmpty) {
        _schedule.resyncReminders(
          userId: _uid,
        );
      }
    });

    _loadLocalPhoto();
  }

  Future<void> _loadLocalPhoto() async {
    final path =
        await UserService.instance.getLocalPhotoPath();

    if (mounted) {
      setState(() {
        _localPhotoPath = path;
      });
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startInstant() {
    final code =
        DateTime.now().millisecondsSinceEpoch
            .toRadixString(36);

    Navigator.of(context).pushNamed(
      AppRoutes.meeting,
      arguments: {
        'meetingId': code,
        'meetingName': 'Réunion instantanée',
        'userId': _uid,
        'userName': _displayName,
        'userEmail': widget.user.email,
        'isHost': true,
      },
    );
  }

  void _joinMeeting(MeetingModel meeting) {
    Navigator.of(context).pushNamed(
      AppRoutes.meeting,
      arguments: {
        'meetingId': meeting.id,
        'meetingName': meeting.title,
        'userId': _uid,
        'userName': _displayName,
        'userEmail': widget.user.email,
        'isHost': meeting.organizerId == _uid,
      },
    );
  }

  Future<void> _joinByCode() async {
    final code =
        _codeCtrl.text.trim().toUpperCase();

    if (code.isEmpty) {
      _snack(
        'Veuillez entrer un code de réunion',
      );
      return;
    }

    if (!RegExp(
      r'^[A-Z0-9]{3}-[A-Z0-9]{3}-[A-Z0-9]{3}$',
    ).hasMatch(code)) {
      _snack(
        'Format invalide. Utilisez XXX-XXX-XXX',
      );
      return;
    }

    FocusScope.of(context).unfocus();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _buildJoinLoadingDialog(code),
    );

    try {
      logger.d(
        'Tentative de rejoindre réunion avec code: $code',
      );

      final backendService =
          BackendApiService();

      final meetingData =
          await backendService.getMeetingByCode(
        code,
      );

      if (!mounted) return;

      Navigator.of(context).pop();

      if (meetingData == null) {
        logger.d(
          'Backend n\'a pas trouvé la réunion, tentative via Firestore direct',
        );

        final meeting =
            await MeetingService().getMeetingByCode(
          code,
        );

        if (!mounted) return;

        if (meeting == null) {
          logger.d(
            'Réunion introuvable via Firestore pour le code: $code',
          );

          _showJoinErrorDialog(
            code,
            'Aucune réunion trouvée pour ce code',
          );
          return;
        }

        logger.d(
          'Réunion trouvée via Firestore: ${meeting.id}',
        );

        _codeCtrl.clear();
        _joinMeeting(meeting);
        return;
      }

      final meeting =
          backendService.parseMeetingData(
        meetingData,
      );

      if (meeting != null) {
        logger.d(
          'Réunion trouvée via backend: ${meeting.id}',
        );

        final shouldJoin =
            await _showMeetingDetailsDialog(
          meeting,
        );

        if (!mounted) return;

        if (shouldJoin) {
          try {
            await backendService.addParticipant(
              meeting.id,
            );

            logger.d(
              'Participant ajouté via backend',
            );
          } catch (e) {
            logger.d(
              'Échec ajout participant via backend, tentative direct',
            );

            await MeetingService().addParticipant(
              meeting.id,
              _uid,
            );

            logger.d(
              'Participant ajouté via Firestore direct',
            );
          }

          _codeCtrl.clear();
          _joinMeeting(meeting);
        }
      } else {
        logger.d(
          'Erreur parsing meeting data du backend',
        );

        _showJoinErrorDialog(
          code,
          'Erreur lors de la lecture des données de la réunion',
        );
      }
    } catch (e) {
      logger.e(
        'Erreur lors de la jonction: $e',
      );

      if (mounted) {
        Navigator.of(context).pop();

        _showJoinErrorDialog(
          code,
          'Connexion impossible: ${e.toString()}',
        );
      }
    }
  }

  Widget _buildJoinLoadingDialog(
    String code,
  ) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
            color: AppColors.primary,
          ),
          const SizedBox(height: 20),
          const Text(
            'Recherche de la réunion...',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Code: $code',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _showMeetingDetailsDialog(
    dynamic meeting,
  ) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor:
                AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(16),
            ),
            title: const Row(
              children: [
                Icon(
                  Icons.video_call,
                  color: AppColors.primary,
                  size: 28,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Détails de la réunion',
                    style: TextStyle(
                      color:
                          AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize:
                  MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                _buildDetailRow(
                  'Titre',
                  meeting.title ??
                      'Réunion',
                ),
                _buildDetailRow(
                  'Code',
                  meeting.meetingCode ??
                      'N/A',
                ),
                _buildDetailRow(
                  'Organisateur',
                  meeting.organizer ??
                      'Inconnu',
                ),
                _buildDetailRow(
                  'Participants',
                  '${meeting.participants?.length ?? 0}',
                ),
                if (meeting.description !=
                        null &&
                    meeting.description!
                        .isNotEmpty)
                  _buildDetailRow(
                    'Description',
                    meeting.description!,
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(context)
                        .pop(false),
                child: const Text(
                  'Annuler',
                  style: TextStyle(
                    color:
                        AppColors.textSecondary,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () =>
                    Navigator.of(context)
                        .pop(true),
                style:
                    ElevatedButton.styleFrom(
                  backgroundColor:
                      AppColors.primary,
                  foregroundColor:
                      AppColors.textOnPrimary,
                  shape:
                      RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(
                      8,
                    ),
                  ),
                ),
                child:
                    const Text('Rejoindre'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _buildDetailRow(
    String label,
    String value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 8,
      ),
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color:
                    AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color:
                    AppColors.textPrimary,
                fontSize: 14,
                fontWeight:
                    FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showJoinErrorDialog(
    String code,
    String errorMessage,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor:
            AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(16),
        ),
        title: const Row(
          children: [
            Icon(
              Icons.error_outline,
              color: AppColors.error,
              size: 28,
            ),
            SizedBox(width: 12),
            Text(
              'Échec de la jonction',
              style: TextStyle(
                color:
                    AppColors.textPrimary,
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize:
              MainAxisSize.min,
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(
              errorMessage,
              style: const TextStyle(
                color:
                    AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Code: $code',
              style: const TextStyle(
                color:
                    AppColors.textTertiary,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(),
            child: const Text(
              'Fermer',
              style: TextStyle(
                color:
                    AppColors.textSecondary,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _codeCtrl.clear();
            },
            style:
                ElevatedButton.styleFrom(
              backgroundColor:
                  AppColors.primary,
              foregroundColor:
                  AppColors.textOnPrimary,
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(8),
              ),
            ),
            child:
                const Text('Réessayer'),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
              color:
                  AppColors.textPrimary,
            ),
          ),
          backgroundColor:
              AppColors.surfaceElevated,
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }

  void _handleNavigation(int index) {
    setState(() {
      _selectedNav = index;
    });

    switch (index) {
      case 0:
        break;

      case 1:
        Navigator.of(context)
            .pushNamed(
              AppRoutes.schedule,
            )
            .then(
              (_) => _loadLocalPhoto(),
            );

        setState(() {
          _selectedNav = 0;
        });
        break;

      case 2:
        Navigator.of(context)
            .pushNamed(
              AppRoutes.settings,
            )
            .then(
              (_) => _loadLocalPhoto(),
            );

        setState(() {
          _selectedNav = 0;
        });
        break;

      case 3:
        Navigator.of(context)
            .pushNamed(
              AppRoutes.profile,
            )
            .then(
              (_) => _loadLocalPhoto(),
            );

        setState(() {
          _selectedNav = 0;
        });
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallpaper =
        context
            .watch<WallpaperProvider>()
            .config;

    final screenWidth =
        MediaQuery.of(context).size.width;

    final useWideLayout =
        screenWidth >= 720;

    final content = SafeArea(
      child: RefreshIndicator(
        color: AppColors.primary,
        backgroundColor:
            AppColors.surface,
        onRefresh: () async =>
            setState(() {}),
        child: ListView(
          padding:
              const EdgeInsets.fromLTRB(
            20,
            8,
            20,
            40,
          ),
          children: [
            _header(),
            const SizedBox(height: 28),
            _heroCard(),
            const SizedBox(height: 16),
            _joinRow(),
            const SizedBox(height: 32),
            _sectionHeader('À venir'),
            const SizedBox(height: 12),
            _upcoming(),
          ],
        ),
      ),
    );

    final body = wallpaper.hasImage
        ? AppBackground(
            config: wallpaper,
            child: content,
          )
        : Container(
            decoration:
                const BoxDecoration(
              gradient:
                  AppColors.heroGradient,
            ),
            child: content,
          );

    return Scaffold(
      backgroundColor:
          AppColors.background,
      body: useWideLayout
          ? _buildWideLayout(body)
          : SafeArea(
              child: body,
            ),
      bottomNavigationBar:
          useWideLayout
              ? null
              : _buildBottomNavBar(),
    );
  }

  Widget _buildWideLayout(
    Widget body,
  ) {
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(
              right: BorderSide(
                color: AppColors.border
                    .withValues(alpha: 0.6),
              ),
            ),
          ),
          child: SafeArea(
            right: false,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(
                vertical: 12,
                horizontal: 6,
              ),
              child: NavigationRail(
                selectedIndex: _selectedNav,
                onDestinationSelected:
                    _handleNavigation,
                extended: false,
                backgroundColor:
                    Colors.transparent,
                elevation: 0,
                labelType:
                    NavigationRailLabelType.all,
                indicatorColor:
                    AppColors.primary
                        .withValues(
                  alpha: 0.15,
                ),
                selectedIconTheme:
                    const IconThemeData(
                  color:
                      AppColors.primary,
                  size: 24,
                ),
                unselectedIconTheme:
                    const IconThemeData(
                  color:
                      AppColors.textTertiary,
                  size: 22,
                ),
                selectedLabelTextStyle:
                    const TextStyle(
                  color:
                      AppColors.primary,
                  fontSize: 10,
                  fontWeight:
                      FontWeight.w700,
                  letterSpacing: 0.2,
                ),
                unselectedLabelTextStyle:
                    const TextStyle(
                  color:
                      AppColors.textTertiary,
                  fontSize: 10,
                  fontWeight:
                      FontWeight.w600,
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(
                      Icons.home_outlined,
                    ),
                    selectedIcon: Icon(
                      Icons.home_rounded,
                    ),
                    label: Text('Accueil'),
                    padding:
                        EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: Icon(
                      Icons.event_outlined,
                    ),
                    selectedIcon: Icon(
                      Icons.event_rounded,
                    ),
                    label: Text('Réunions'),
                    padding:
                        EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: Icon(
                      Icons.settings_outlined,
                    ),
                    selectedIcon: Icon(
                      Icons.settings_rounded,
                    ),
                    label: Text('Param.'),
                    padding:
                        EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: Icon(
                      Icons.person_outline,
                    ),
                    selectedIcon: Icon(
                      Icons.person_rounded,
                    ),
                    label: Text('Profil'),
                    padding:
                        EdgeInsets.symmetric(
                      vertical: 6,
                    ),
                  ),
                ],
                trailing: Expanded(
                  child: Align(
                    alignment:
                        Alignment.bottomCenter,
                    child: Padding(
                      padding:
                          const EdgeInsets.only(
                        bottom: 20,
                      ),
                      child: Column(
                        mainAxisSize:
                            MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap:
                                _openNativeApp,
                            borderRadius:
                                BorderRadius
                                    .circular(8),
                            child: Container(
                              padding:
                                  const EdgeInsets
                                      .all(8),
                              decoration:
                                  BoxDecoration(
                                gradient:
                                    AppColors
                                        .primaryGradient,
                                borderRadius:
                                    BorderRadius
                                        .circular(8),
                              ),
                              child:
                                  const Icon(
                                Icons
                                    .launch_rounded,
                                color:
                                    Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                          const SizedBox(
                            height: 4,
                          ),
                          const Text(
                            'Ouvrir app',
                            style: TextStyle(
                              color: AppColors
                                  .textTertiary,
                              fontSize: 8,
                              fontWeight:
                                  FontWeight
                                      .w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: SafeArea(
            left: false,
            child: body,
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNavBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(
            color: AppColors.border
                .withValues(alpha: 0.6),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 6,
          ),
          child: Row(
            children: [
              Expanded(
                child: NavigationBar(
                  selectedIndex:
                      _selectedNav,
                  onDestinationSelected:
                      _handleNavigation,
                  backgroundColor:
                      Colors.transparent,
                  elevation: 0,
                  height: 64,
                  indicatorColor:
                      AppColors.primary
                          .withValues(
                    alpha: 0.15,
                  ),
                  indicatorShape:
                      RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(
                      14,
                    ),
                  ),
                  labelBehavior:
                      NavigationDestinationLabelBehavior
                          .alwaysShow,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(
                        Icons.home_outlined,
                        size: 24,
                      ),
                      selectedIcon: Icon(
                        Icons.home_rounded,
                        size: 26,
                      ),
                      label: 'Accueil',
                    ),
                    NavigationDestination(
                      icon: Icon(
                        Icons.event_outlined,
                        size: 24,
                      ),
                      selectedIcon: Icon(
                        Icons.event_rounded,
                        size: 26,
                      ),
                      label: 'Réunions',
                    ),
                    NavigationDestination(
                      icon: Icon(
                        Icons.settings_outlined,
                        size: 24,
                      ),
                      selectedIcon: Icon(
                        Icons.settings_rounded,
                        size: 26,
                      ),
                      label: 'Paramètres',
                    ),
                    NavigationDestination(
                      icon: Icon(
                        Icons.person_outline,
                        size: 24,
                      ),
                      selectedIcon: Icon(
                        Icons.person_rounded,
                        size: 26,
                      ),
                      label: 'Profil',
                    ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.only(
                  right: 8,
                  bottom: 8,
                ),
                child: InkWell(
                  onTap: _openNativeApp,
                  borderRadius:
                      BorderRadius.circular(
                    12,
                  ),
                  child: Container(
                    padding:
                        const EdgeInsets.all(
                      12,
                    ),
                    decoration:
                        BoxDecoration(
                      gradient:
                          AppColors
                              .primaryGradient,
                      borderRadius:
                          BorderRadius.circular(
                        12,
                      ),
                    ),
                    child: const Icon(
                      Icons.launch_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final initials = _displayName
            .trim()
            .isEmpty
        ? 'C'
        : _displayName
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w[0])
            .join()
            .toUpperCase();

    Widget avatar;

    if (_localPhotoPath != null &&
        File(_localPhotoPath!).existsSync()) {
      avatar = CircleAvatar(
        radius: 24,
        backgroundImage:
            FileImage(
          File(_localPhotoPath!),
        ),
      );
    } else {
      avatar = CircleAvatar(
        radius: 24,
        backgroundColor:
            AppColors.primary,
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontWeight:
                FontWeight.w700,
            fontSize: 16,
          ),
        ),
      );
    }

    return Row(
      children: [
        avatar,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                _greeting(),
                style: const TextStyle(
                  color:
                      AppColors.textTertiary,
                  fontSize: 12,
                  letterSpacing: 1.4,
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _displayName,
                maxLines: 1,
                overflow:
                    TextOverflow.ellipsis,
                style: const TextStyle(
                  color:
                      AppColors.textPrimary,
                  fontSize: 26,
                  fontWeight:
                      FontWeight.w700,
                  letterSpacing: -0.8,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () =>
              Navigator.of(context)
                  .pushNamed(
            AppRoutes.wallpaper,
          ),
          icon: const Icon(
            Icons.wallpaper,
            color:
                AppColors.textTertiary,
          ),
          tooltip:
              'Modifier le fond d\'écran',
        ),
      ],
    );
  }

  Widget _heroCard() {
    return Container(
      padding:
          const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient:
            AppColors.cardGradient,
        borderRadius:
            BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          const Text(
            'Lancer ou planifier une réunion',
            style: TextStyle(
              color:
                  AppColors.textPrimary,
              fontSize: 18,
              fontWeight:
                  FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed:
                      _startInstant,
                  style:
                      ElevatedButton.styleFrom(
                    backgroundColor:
                        AppColors.primary,
                    foregroundColor:
                        AppColors.textOnPrimary,
                    padding:
                        const EdgeInsets
                            .symmetric(
                      vertical: 12,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(
                        12,
                      ),
                    ),
                  ),
                  child: const Text(
                    'Démarrer',
                    style: TextStyle(
                      fontWeight:
                          FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      Navigator.of(
                        context,
                      ).pushNamed(
                        AppRoutes.schedule,
                      ),
                  style:
                      OutlinedButton.styleFrom(
                    side:
                        const BorderSide(
                      color:
                          AppColors.border,
                    ),
                    padding:
                        const EdgeInsets
                            .symmetric(
                      vertical: 12,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(
                        12,
                      ),
                    ),
                  ),
                  child: const Text(
                    'Planifier',
                    style: TextStyle(
                      color:
                          AppColors.textPrimary,
                      fontWeight:
                          FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _joinRow() {
    return Container(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 12,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius:
            BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.border,
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.video_call_rounded,
            color:
                AppColors.textTertiary,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _codeCtrl,
              style: const TextStyle(
                color:
                    AppColors.textPrimary,
                fontSize: 14,
              ),
              decoration:
                  const InputDecoration(
                hintText:
                    'Code de réunion',
                hintStyle: TextStyle(
                  color:
                      AppColors.textTertiary,
                  fontSize: 14,
                ),
                border:
                    InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(
                  vertical: 12,
                ),
              ),
              textCapitalization:
                  TextCapitalization
                      .characters,
              onSubmitted: (_) =>
                  _joinByCode(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed:
                _joinByCode,
            icon: const Icon(
              Icons.arrow_forward_rounded,
              color:
                  AppColors.primary,
            ),
            style:
                IconButton.styleFrom(
              backgroundColor:
                  AppColors.primary
                      .withValues(
                alpha: 0.1,
              ),
              padding:
                  const EdgeInsets.all(
                8,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openNativeApp() async {
    const appScheme = 'crux://';

    try {
      final uri = Uri.parse(
        appScheme,
      );

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        _snack(
          'Application CRUX non installée sur cet appareil',
        );
      }
    } catch (e) {
      _snack(
        'Impossible d\'ouvrir l\'application',
      );
    }
  }

  Widget _sectionHeader(
    String title,
  ) {
    return Text(
      title,
      style: const TextStyle(
        color:
            AppColors.textPrimary,
        fontSize: 14,
        fontWeight:
            FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _upcoming() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('meetings')
          .where(
            'participants',
            arrayContains: _uid,
          )
          .where(
            'endTime',
            isGreaterThan:
                Timestamp.now(),
          )
          .orderBy('endTime')
          .limit(5)
          .snapshots(),
      builder: (context, snap) {
        if (snap.connectionState ==
            ConnectionState.waiting) {
          return const Center(
            child:
                CircularProgressIndicator(
              valueColor:
                  AlwaysStoppedAnimation(
                AppColors.primary,
              ),
            ),
          );
        }

        if (!snap.hasData ||
            snap.data!.docs.isEmpty) {
          return _empty(
            'Aucune réunion à venir.',
          );
        }

        return Column(
          children: snap.data!.docs
              .map(
                (doc) =>
                    _meetingCard(
                  MeetingModel.fromDoc(
                    doc.id,
                    doc.data()
                        as Map<
                            String,
                            dynamic>,
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }

  Widget _meetingCard(
    MeetingModel meeting,
  ) {
    final live =
        meeting.endTime
                .isAfter(
              DateTime.now(),
            ) &&
            meeting.startTime
                .isBefore(
              DateTime.now(),
            );

    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            AppColors.surface,
        borderRadius:
            BorderRadius.circular(
          12,
        ),
        border: Border.all(
          color:
              AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        meeting.title,
                        maxLines: 1,
                        overflow:
                            TextOverflow
                                .ellipsis,
                        style:
                            const TextStyle(
                          color:
                              AppColors
                                  .textPrimary,
                          fontSize: 15,
                          fontWeight:
                              FontWeight.w600,
                        ),
                      ),
                    ),
                    if (live) ...[
                      const SizedBox(
                        width: 8,
                      ),
                      Container(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration:
                            BoxDecoration(
                          color: AppColors
                              .liveWithOpacity(
                            0.14,
                          ),
                          borderRadius:
                              BorderRadius
                                  .circular(
                            999,
                          ),
                        ),
                        child:
                            const Text(
                          'EN DIRECT',
                          style:
                              TextStyle(
                            color:
                                AppColors
                                    .liveDot,
                            fontSize: 9,
                            fontWeight:
                                FontWeight
                                    .w800,
                            letterSpacing:
                                0.8,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(
                  height: 4,
                ),
                Text(
                  '${_time(meeting.startTime)} – ${_time(meeting.endTime)}'
                  '${meeting.participants.length > 1 ? ' · ${meeting.participants.length} participants' : ''}',
                  style:
                      const TextStyle(
                    color: AppColors
                        .textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(
            width: 10,
          ),
          TextButton(
            style:
                TextButton.styleFrom(
              foregroundColor:
                  meeting.isJoinable
                      ? AppColors
                          .textPrimary
                      : AppColors
                          .textDisabled,
            ),
            onPressed:
                meeting.isJoinable
                    ? () =>
                        _joinMeeting(
                          meeting,
                        )
                    : null,
            child:
                const Text(
              'Rejoindre',
              style: TextStyle(
                fontWeight:
                    FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(
    String message,
  ) =>
      Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(
          vertical: 34,
          horizontal: 20,
        ),
        decoration:
            BoxDecoration(
          color:
              AppColors.surface,
          borderRadius:
              BorderRadius.circular(
            20,
          ),
          border: Border.all(
            color:
                AppColors.borderSubtle,
          ),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.event_note_outlined,
              color:
                  AppColors.textDisabled,
              size: 26,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign:
                  TextAlign.center,
              style:
                  const TextStyle(
                color:
                    AppColors.textTertiary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      );

  String _greeting() {
    final h =
        DateTime.now().hour;

    if (h < 6) {
      return 'BONNE NUIT';
    }

    if (h < 12) {
      return 'BONJOUR';
    }

    if (h < 18) {
      return 'BON APRÈS-MIDI';
    }

    return 'BONSOIR';
  }

  String _time(
    DateTime d,
  ) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
