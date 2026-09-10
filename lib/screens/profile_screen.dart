import 'dart:convert';
import '../utils/local_file.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../l10n/app_translations.dart';
import '../providers/locale_provider.dart';
import '../services/note_service.dart';
import '../services/user_service.dart';
import '../theme/colors.dart';
import '../widgets/elegant_toast.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _picker = ImagePicker();

  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  bool _isUpdatingPhoto = false;
  bool _isSavingName = false;
  int _meetingsHosted = 0;
  String? _localPhotoPath;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      duration: const Duration(milliseconds: 700),
      vsync: this,
    );
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
    _animCtrl.forward();
    _loadAll();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final path = await UserService.instance.getLocalPhotoPath();
    final uid = _auth.currentUser?.uid;
    if (mounted) setState(() => _localPhotoPath = path);
    if (uid == null) return;
    try {
      final snap =
          await _db
              .collection('meetings')
              .where('organizerId', isEqualTo: uid)
              .get();
      if (mounted) setState(() => _meetingsHosted = snap.docs.length);
    } catch (_) {}
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 400,
        maxHeight: 400,
      );
      if (picked == null) return;
      setState(() => _isUpdatingPhoto = true);

      final appDir = await _getAppDocDir();
      await createLocalDir(appDir);

      final dest = '$appDir/profile_photo.jpg';
      await copyLocalFile(picked.path, dest);
      await UserService.instance.setLocalPhotoPath(dest);

      if (mounted) {
        setState(() {
          _localPhotoPath = dest;
          _isUpdatingPhoto = false;
        });
        _snack(
          AppTranslations.t(
            'photo_updated_ok',
            context.read<LocaleProvider>().locale.languageCode,
          ),
        );
      }

      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        final bytes = await readLocalFileBytes(picked.path);
        final b64 = bytes != null ? base64Encode(bytes) : null;
        if (b64 == null) return;
        UserService.instance
            .saveProfile(uid: uid, photoBase64: b64)
            .catchError((_) {});
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUpdatingPhoto = false);
        _snack('❌ Erreur: ${e.toString().substring(0, 40)}');
      }
    }
  }

  Future<String> _getAppDocDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  Future<void> _removePhoto() async {
    await UserService.instance.removeLocalPhotoPath();
    if (_localPhotoPath != null) {
      try {
        await deleteLocalFile(_localPhotoPath!);
      } catch (_) {}
    }
    final uid = _auth.currentUser?.uid;
    if (uid != null) {
      _db
          .collection('users')
          .doc(uid)
          .update({'photoBase64': FieldValue.delete()})
          .catchError((_) {});
    }
    if (mounted) {
      setState(() => _localPhotoPath = null);
      _snack(
        AppTranslations.t(
          'photo_removed_ok',
          context.read<LocaleProvider>().locale.languageCode,
        ),
      );
    }
  }

  void _showPhotoOptions(String lang) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (_) => Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  AppTranslations.t('change_photo', lang),
                  style: GoogleFonts.poppins(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                _SheetTile(
                  icon: Icons.photo_library_outlined,
                  label: AppTranslations.t('photo_gallery', lang),
                  onTap: () {
                    Navigator.pop(context);
                    _pickPhoto(ImageSource.gallery);
                  },
                ),
                _SheetTile(
                  icon: Icons.camera_alt_outlined,
                  label: AppTranslations.t('photo_camera', lang),
                  onTap: () {
                    Navigator.pop(context);
                    _pickPhoto(ImageSource.camera);
                  },
                ),
                if (_localPhotoPath != null)
                  _SheetTile(
                    icon: Icons.delete_outline,
                    label: AppTranslations.t('remove_photo', lang),
                    danger: true,
                    onTap: () {
                      Navigator.pop(context);
                      _removePhoto();
                    },
                  ),
              ],
            ),
          ),
    );
  }

  InputDecoration _fieldDecoration(String label, {IconData? icon}) {
    return InputDecoration(
      labelText: label,
      labelStyle: GoogleFonts.poppins(color: AppColors.textSecondary),
      prefixIcon:
          icon == null ? null : Icon(icon, color: AppColors.primaryDark),
      filled: true,
      fillColor: AppColors.surfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusField),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusField),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppColors.radiusField),
        borderSide: const BorderSide(color: AppColors.borderFocused, width: 2),
      ),
    );
  }

  Future<void> _showEditNameDialog(String lang) async {
    final ctrl = TextEditingController(
      text: _auth.currentUser?.displayName ?? '',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: AppColors.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppColors.radiusCard),
            ),
            title: Text(
              AppTranslations.t('change_name', lang),
              style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              style: GoogleFonts.poppins(color: AppColors.textPrimary),
              decoration: _fieldDecoration(
                AppTranslations.t('enter_new_name', lang),
                icon: Icons.person_outline,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  AppTranslations.t('cancel', lang),
                  style: GoogleFonts.poppins(color: AppColors.textSecondary),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.textOnPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppColors.radiusButton),
                  ),
                ),
                child: Text(
                  AppTranslations.t('save', lang),
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    var newName = ctrl.text.trim();
    if (newName.isEmpty) return;
    if (newName == (_auth.currentUser?.displayName ?? '').trim()) return;
    if (newName.length > 50) return;
    setState(() => _isSavingName = true);
    try {
      await _auth.currentUser!.updateDisplayName(newName);
      final uid = _auth.currentUser?.uid;
      if (uid != null) {
        UserService.instance
            .saveProfile(uid: uid, name: newName)
            .catchError((_) {});
      }
      if (mounted) {
        setState(() => _isSavingName = false);
        _snack(AppTranslations.t('name_updated', lang));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingName = false);
        _snack('❌ $e');
      }
    }
  }

  Future<void> _showChangePasswordDialog(String lang) async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    bool obscure1 = true, obscure2 = true;
    await showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setS) => AlertDialog(
                  backgroundColor: AppColors.surfaceElevated,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppColors.radiusCard),
                  ),
                  title: Text(
                    AppTranslations.t('change_password', lang),
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: currentCtrl,
                        obscureText: obscure1,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                        ),
                        decoration: _fieldDecoration(
                          AppTranslations.t('current_password', lang),
                          icon: Icons.lock_outline,
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscure1
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: AppColors.textTertiary,
                              size: 20,
                            ),
                            onPressed: () => setS(() => obscure1 = !obscure1),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: newCtrl,
                        obscureText: obscure2,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                        ),
                        decoration: _fieldDecoration(
                          AppTranslations.t('new_password', lang),
                          icon: Icons.lock_reset,
                        ).copyWith(
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscure2
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: AppColors.textTertiary,
                              size: 20,
                            ),
                            onPressed: () => setS(() => obscure2 = !obscure2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(
                        AppTranslations.t('cancel', lang),
                        style: GoogleFonts.poppins(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        final cur = currentCtrl.text.trim();
                        final nw = newCtrl.text.trim();
                        Navigator.pop(ctx);
                        await _changePassword(cur, nw, lang);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.textOnPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppColors.radiusButton,
                          ),
                        ),
                      ),
                      child: Text(
                        AppTranslations.t('save', lang),
                        style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _changePassword(
    String current,
    String newPass,
    String lang,
  ) async {
    if (current.isEmpty || newPass.isEmpty) {
      _snack('⚠️ ${AppTranslations.t('val_pwd_required', lang)}');
      return;
    }
    if (newPass.length < 6) {
      _snack('⚠️ ${AppTranslations.t('val_min_6', lang)}');
      return;
    }
    try {
      final user = _auth.currentUser!;
      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: current,
      );
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(newPass);
      if (mounted) _snack(AppTranslations.t('password_updated', lang));
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        final msg =
            e.code == 'wrong-password' || e.code == 'invalid-credential'
                ? '❌ Mot de passe actuel incorrect'
                : '❌ ${e.message}';
        _snack(msg);
      }
    } catch (e) {
      if (mounted) _snack('❌ Erreur: $e');
    }
  }

  Future<void> _confirmDeleteAccount(String lang) async {
    final hasEmail =
        _auth.currentUser?.providerData.any(
          (p) => p.providerId == 'password',
        ) ??
        false;
    String? reAuthPassword;
    if (hasEmail) {
      final ctrl = TextEditingController();
      reAuthPassword = await showDialog<String>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              backgroundColor: AppColors.surfaceElevated,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppColors.radiusCard),
              ),
              title: Text(
                AppTranslations.t('confirm_identity', lang),
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    AppTranslations.t('confirm_delete_msg', lang),
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    obscureText: true,
                    autofocus: true,
                    style: GoogleFonts.poppins(color: AppColors.textPrimary),
                    decoration: _fieldDecoration(
                      AppTranslations.t('password', lang),
                      icon: Icons.lock_outline,
                    ).copyWith(
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          AppColors.radiusField,
                        ),
                        borderSide: const BorderSide(
                          color: AppColors.error,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    AppTranslations.t('cancel', lang),
                    style: GoogleFonts.poppins(color: AppColors.textSecondary),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, ctrl.text),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: AppColors.textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        AppColors.radiusButton,
                      ),
                    ),
                  ),
                  child: Text(
                    AppTranslations.t('confirm_btn', lang),
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
      );
      if (reAuthPassword == null || !mounted) return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: AppColors.surfaceElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppColors.radiusCard),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: AppColors.errorSurface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.warning_outlined,
                    color: AppColors.error,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppTranslations.t('delete_account', lang),
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w700,
                      color: AppColors.error,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              AppTranslations.t('delete_confirm', lang),
              style: GoogleFonts.poppins(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(
                  AppTranslations.t('cancel', lang),
                  style: GoogleFonts.poppins(color: AppColors.textSecondary),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppColors.radiusButton),
                  ),
                ),
                child: Text(
                  AppTranslations.t('delete_account', lang),
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final user = _auth.currentUser!;
      if (hasEmail && reAuthPassword != null) {
        final cred = EmailAuthProvider.credential(
          email: user.email!,
          password: reAuthPassword,
        );
        await user.reauthenticateWithCredential(cred);
      }
      await _db.collection('users').doc(user.uid).delete();
      try {
        final presenceQuery =
            await _db
                .collectionGroup('presence')
                .where('userId', isEqualTo: user.uid)
                .limit(20)
                .get();
        for (final doc in presenceQuery.docs) {
          doc.reference.delete().catchError((_) {});
        }
      } catch (_) {}
      await user.delete();
      if (mounted) Navigator.of(context).pushReplacementNamed('/login');
    } on FirebaseAuthException catch (e) {
      if (mounted) _snack('❌ ${e.message}');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    final isError = msg.startsWith('❌');
    final isSuccess = msg.startsWith('✅');
    final cleanMsg = msg.replaceAll('❌', '').replaceAll('✅', '').trim();
    ElegantToast.show(
      context,
      title: isError ? 'Erreur' : (isSuccess ? 'Succès' : 'Information'),
      message: cleanMsg,
      type:
          isError
              ? ElegantToastType.error
              : (isSuccess ? ElegantToastType.success : ElegantToastType.info),
    );
  }

  Widget _buildAvatar() {
    final user = _auth.currentUser;
    final initials =
        (user?.displayName?.isNotEmpty == true)
            ? user!.displayName!
                .split(' ')
                .take(2)
                .map((w) => w[0].toUpperCase())
                .join()
            : (user?.email?[0].toUpperCase() ?? 'U');

    Widget photo;
    if (_isUpdatingPhoto) {
      photo = Container(
        color: AppColors.overlayMedium,
        child: const Center(
          child: CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 3,
          ),
        ),
      );
    } else if (localFileExists(_localPhotoPath ?? '')) {
      photo = Image(image: localFileImage(_localPhotoPath!)!, fit: BoxFit.cover);
    } else {
      photo = Container(
        color: AppColors.surfaceElevated,
        child: Center(
          child: Text(
            initials,
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 32,
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        GestureDetector(
          onTap:
              () => _showPhotoOptions(
                context.read<LocaleProvider>().locale.languageCode,
              ),
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.borderFocused, width: 2),
              boxShadow: AppColors.glowShadow,
            ),
            child: ClipOval(child: photo),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: GestureDetector(
            onTap:
                () => _showPhotoOptions(
                  context.read<LocaleProvider>().locale.languageCode,
                ),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.borderFocused),
              ),
              child: const Icon(
                Icons.camera_alt,
                size: 16,
                color: AppColors.primaryDark,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LocaleProvider>().locale.languageCode;
    final user = _auth.currentUser;
    final createdAt = user?.metadata.creationTime;
    final hasEmailProvider =
        user?.providerData.any((p) => p.providerId == 'password') ?? false;
    final hasGoogleProvider =
        user?.providerData.any((p) => p.providerId == 'google.com') ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.heroGradient),
        child: FadeTransition(
          opacity: _fadeAnim,
          child: RefreshIndicator(
            onRefresh: () async {
              HapticFeedback.lightImpact();
              await _loadAll();
            },
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverAppBar(
                  expandedHeight: 200,
                  pinned: true,
                  backgroundColor: AppColors.surface,
                  elevation: 0,
                  leading: Padding(
                    padding: const EdgeInsets.all(8),
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.overlayMedium,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new,
                          color: AppColors.textPrimary,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  flexibleSpace: FlexibleSpaceBar(
                    background: Container(
                      decoration: const BoxDecoration(
                        gradient: AppColors.heroGradient,
                      ),
                      child: SafeArea(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const SizedBox(height: 8),
                            _buildAvatar(),
                            const SizedBox(height: 10),
                            Text(
                              user?.displayName ??
                                  user?.email?.split('@')[0] ??
                                  'User',
                              style: GoogleFonts.poppins(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                              ),
                            ),
                            Text(
                              user?.email ?? '',
                              style: GoogleFonts.poppins(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 48),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(AppTranslations.t('account_stats', lang)),
                        _Card(
                          child: Row(
                            children: [
                              Expanded(
                                child: _Stat(
                                  label: AppTranslations.t(
                                    'meetings_hosted',
                                    lang,
                                  ),
                                  value: '$_meetingsHosted',
                                  icon: Icons.video_camera_front_outlined,
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 60,
                                color: AppColors.divider,
                              ),
                              Expanded(
                                child: _Stat(
                                  label: AppTranslations.t(
                                    'member_since',
                                    lang,
                                  ),
                                  value:
                                      createdAt != null
                                          ? '${createdAt.day}/${createdAt.month}/${createdAt.year}'
                                          : '—',
                                  icon: Icons.calendar_today_outlined,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        _SectionLabel(AppTranslations.t('profile_info', lang)),
                        _Card(
                          child: Column(
                            children: [
                              _Tile(
                                icon: Icons.person_outline,
                                title: AppTranslations.t('display_name', lang),
                                subtitle: user?.displayName ?? '—',
                                trailing:
                                    _isSavingName
                                        ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppColors.primary,
                                          ),
                                        )
                                        : const Icon(
                                          Icons.edit_outlined,
                                          color: AppColors.primaryDark,
                                          size: 20,
                                        ),
                                onTap: () => _showEditNameDialog(lang),
                              ),
                              const _Hairline(),
                              _Tile(
                                icon: Icons.email_outlined,
                                title: AppTranslations.t('email', lang),
                                subtitle: user?.email ?? '—',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        _SectionLabel(
                          AppTranslations.t('sign_in_methods', lang),
                        ),
                        _Card(
                          child: Column(
                            children: [
                              if (hasEmailProvider) ...[
                                _Tile(
                                  icon: Icons.lock_outline,
                                  title: AppTranslations.t(
                                    'email_password',
                                    lang,
                                  ),
                                  subtitle: user?.email ?? '',
                                  trailing: const _StatusBadge('Actif'),
                                ),
                                if (hasGoogleProvider) const _Hairline(),
                              ],
                              if (hasGoogleProvider)
                                _Tile(
                                  icon: Icons.g_mobiledata,
                                  title: AppTranslations.t(
                                    'google_account',
                                    lang,
                                  ),
                                  subtitle: user?.email ?? '',
                                  trailing: const _StatusBadge('Google'),
                                ),
                            ],
                          ),
                        ),
                        if (hasEmailProvider) ...[
                          const SizedBox(height: 28),
                          _SectionLabel(
                            AppTranslations.t('account_security', lang),
                          ),
                          _Card(
                            child: _Tile(
                              icon: Icons.lock_reset,
                              title: AppTranslations.t('change_password', lang),
                              onTap: () => _showChangePasswordDialog(lang),
                            ),
                          ),
                        ],
                        const SizedBox(height: 28),
                        const _SectionLabel('Zone dangereuse', danger: true),
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.errorSurface,
                            borderRadius: BorderRadius.circular(
                              AppColors.radiusCard,
                            ),
                            border: Border.all(
                              color: AppColors.error.withValues(alpha: 0.35),
                            ),
                          ),
                          child: _Tile(
                            icon: Icons.delete_forever_outlined,
                            title: AppTranslations.t('delete_account', lang),
                            danger: true,
                            onTap: () => _confirmDeleteAccount(lang),
                          ),
                        ),
                        const SizedBox(height: 28),
                        const _SectionLabel('Historique & Notes'),
                        StreamBuilder<QuerySnapshot>(
                          stream: NoteService.instance.streamUserNotes(
                            user?.uid ?? '',
                          ),
                          builder: (context, snap) {
                            if (!snap.hasData || snap.data!.docs.isEmpty) {
                              return _Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Center(
                                    child: Text(
                                      'Aucune note enregistrée',
                                      style: GoogleFonts.poppins(
                                        color: AppColors.textTertiary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                            return Column(
                              children:
                                  snap.data!.docs.map((doc) {
                                    final data =
                                        doc.data() as Map<String, dynamic>;
                                    return Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: _Card(
                                        child: ListTile(
                                          title: Text(
                                            '${data['meetingName']}',
                                            style: GoogleFonts.poppins(
                                              color: AppColors.textPrimary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '${data['content']}',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: GoogleFonts.poppins(
                                              color: AppColors.textSecondary,
                                              fontSize: 13,
                                            ),
                                          ),
                                          trailing: const Icon(
                                            Icons.chevron_right,
                                            color: AppColors.textTertiary,
                                          ),
                                          onTap: () => _showNoteDetail(data),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                            );
                          },
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

  void _showNoteDetail(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(
              '${data['meetingName']}',
              style: GoogleFonts.poppins(color: AppColors.textPrimary),
            ),
            content: SingleChildScrollView(
              child: Text(
                '${data['content']}',
                style: GoogleFonts.poppins(color: AppColors.textSecondary),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Fermer',
                  style: GoogleFonts.poppins(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool danger;
  const _SectionLabel(this.text, {this.danger = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 4),
    child: Text(
      text.toUpperCase(),
      style: GoogleFonts.poppins(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: danger ? AppColors.error : AppColors.textSecondary,
        letterSpacing: 1.2,
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: AppColors.cardGradient,
      borderRadius: BorderRadius.circular(AppColors.radiusCard),
      border: Border.all(color: AppColors.border),
      boxShadow: AppColors.softShadow,
    ),
    child: child,
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = danger ? AppColors.error : AppColors.primaryDark;
    return InkWell(
      onTap:
          onTap == null
              ? null
              : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
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
                  color:
                      danger
                          ? AppColors.error.withValues(alpha: 0.12)
                          : AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: iconColor, size: 20),
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
                    if (subtitle != null && subtitle!.isNotEmpty)
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
                  (onTap != null
                      ? Icon(
                        Icons.chevron_right,
                        color:
                            danger
                                ? AppColors.error.withValues(alpha: 0.7)
                                : AppColors.textTertiary,
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
  Widget build(BuildContext context) => const Divider(
    height: 1,
    thickness: 0.5,
    indent: 68,
    color: AppColors.divider,
  );
}

class _Stat extends StatelessWidget {
  final String label, value;
  final IconData icon;
  const _Stat({required this.label, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.primaryDark, size: 26),
        const SizedBox(height: 6),
        Text(
          value,
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 10,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    ),
  );
}

class _StatusBadge extends StatelessWidget {
  final String label;
  const _StatusBadge(this.label);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.successSurface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: GoogleFonts.poppins(
        color: AppColors.success,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _SheetTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.overlayMedium,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color:
              danger
                  ? AppColors.error.withValues(alpha: 0.35)
                  : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: danger ? AppColors.error : AppColors.primaryDark,
            size: 22,
          ),
          const SizedBox(width: 14),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    ),
  );
}
