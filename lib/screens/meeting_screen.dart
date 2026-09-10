import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../services/meeting_service.dart';
import '../theme/colors.dart';
import '../widgets/elegant_toast.dart';
import 'large_conference_screen.dart';

class MeetingScreen extends StatefulWidget {
  final String meetingId;
  final String? meetingCode;
  final String meetingName;
  final String userId;
  final String userName;
  final String? userEmail;
  final bool isHost;

  /// Passcode déjà validé par un écran en amont (ex. JoinMeetingScreen) :
  /// évite une double saisie tout en gardant la vérification côté écran.
  final String? preValidatedPasscode;

  const MeetingScreen({
    super.key,
    required this.meetingId,
    this.meetingCode,
    required this.meetingName,
    required this.userId,
    required this.userName,
    this.userEmail,
    this.isHost = false,
    this.preValidatedPasscode,
  });

  @override
  State<MeetingScreen> createState() => _MeetingScreenState();
}

class _MeetingScreenState extends State<MeetingScreen> {
  final MeetingService _meetingService = MeetingService();

  final _passcodeCtrl = TextEditingController();

  bool _preparing = true;
  String? _error;

  // Porte de sécurité (tous chemins de jonction : accueil, code, deep links).
  bool _requiresPasscode = false;
  String? _meetingPasscode;
  String? _passError;

  // Préférences média pré-jonction (mêmes clés que SettingsScreen et que
  // LargeConferenceScreen._loadPreferences, pour un comportement cohérent).
  bool _micOn = true;
  bool _camOn = true;

  /// Code partageable (XXX-XXX-XXX) ; retombe sur l'ID technique si absent.
  String get _shareCode =>
      (widget.meetingCode ?? '').trim().isNotEmpty
          ? widget.meetingCode!.trim()
          : widget.meetingId;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _passcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _micOn = prefs.getBool('crux_mic_default') ?? true;
          _camOn = prefs.getBool('crux_cam_default') ?? true;
        });
      }

      // Contrôles d'accès centralisés : statut, verrou hôte, passcode.
      // L'hôte ne repasse pas par la saisie de son propre passcode.
      final meeting = await _meetingService.getMeetingOnce(widget.meetingId);

      if (!mounted) return;

      if (meeting != null) {
        if (meeting.status == MeetingStatus.ended) {
          setState(() {
            _preparing = false;
            _error = 'Cette réunion est terminée.';
          });
          return;
        }

        if (meeting.isLocked && !widget.isHost) {
          setState(() {
            _preparing = false;
            _error = 'Réunion verrouillée par l\'hôte.';
          });
          return;
        }

        final passcode = meeting.passcode;
        final needsPasscode =
            passcode != null &&
            passcode.isNotEmpty &&
            !widget.isHost &&
            widget.preValidatedPasscode != passcode;

        if (needsPasscode) {
          setState(() {
            _preparing = false;
            _requiresPasscode = true;
            _meetingPasscode = passcode;
          });
          return;
        }
      }

      await _finalizeJoin();
    } catch (e) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _finalizeJoin() async {
    try {
      // Utiliser le backend server pour ajouter le participant
      await _addParticipantViaBackend(widget.meetingId);

      if (widget.isHost) {
        await _meetingService.updateMeetingStatus(
          widget.meetingId,
          MeetingStatus.ongoing,
        );
      }

      if (mounted) {
        setState(() {
          _preparing = false;
          _requiresPasscode = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = e.toString();
        });
      }
    }
  }

  void _submitPasscode() {
    if (_passcodeCtrl.text.trim() == _meetingPasscode) {
      setState(() {
        _passError = null;
        _preparing = true;
      });

      _finalizeJoin();
    } else {
      setState(() => _passError = 'Code d\'accès incorrect');
    }
  }

  Future<void> _setMicDefault(bool value) async {
    setState(() => _micOn = value);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('crux_mic_default', value);
  }

  Future<void> _setCamDefault(bool value) async {
    setState(() => _camOn = value);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('crux_cam_default', value);
  }

  Future<void> _addParticipantViaBackend(String meetingId) async {
    try {
      // Utiliser Firebase UID comme identité LiveKit
      final firebaseUid = FirebaseAuth.instance.currentUser?.uid;
      if (firebaseUid == null || firebaseUid.isEmpty) {
        throw Exception('Authentification Firebase requise');
      }

      // Ajouter le participant via Firestore direct
      await _meetingService.addParticipant(meetingId, firebaseUid);
    } catch (e) {
      throw Exception('Erreur ajout participant: $e');
    }
  }

  void _copyText(String text, String successMessage) {
    Clipboard.setData(ClipboardData(text: text));

    ElegantToast.show(
      context,
      title: 'Succès',
      message: successMessage,
      type: ElegantToastType.success,
    );
  }

  void _joinCall() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => LargeConferenceScreen(
              meetingId: widget.meetingId,
              meetingCode: widget.meetingCode,
              meetingName: widget.meetingName,
              userId: widget.userId,
              userName: widget.userName,
              userEmail: widget.userEmail,
              isHost: widget.isHost,
            ),
      ),
    ).then((_) async {
      await _meetingService.removeParticipant(widget.meetingId, widget.userId);

      if (mounted) {
        Navigator.pop(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child:
            _preparing
                ? const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                )
                : _requiresPasscode
                ? _buildPasscodeGate()
                : _error != null
                ? _buildError()
                : _buildContent(),
      ),
    );
  }

  Widget _buildPasscodeGate() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppColors.radiusCard),
            border: Border.all(color: AppColors.borderSubtle),
            boxShadow: AppColors.softShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.lock_outline,
                color: AppColors.primary,
                size: 48,
              ),
              const SizedBox(height: 16),
              const Text(
                'Code d\'accès requis',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Cette réunion est protégée par un code.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _passcodeCtrl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                obscureText: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  letterSpacing: 6,
                ),
                decoration: InputDecoration(
                  hintText: '4 à 6 chiffres',
                  hintStyle: const TextStyle(color: AppColors.textTertiary),
                  counterStyle: const TextStyle(color: AppColors.textTertiary),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                ),
                onSubmitted: (_) => _submitPasscode(),
              ),
              if (_passError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _passError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _submitPasscode,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.textOnPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        AppColors.radiusButton,
                      ),
                    ),
                  ),
                  child: const Text('Valider'),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Annuler',
                  style: TextStyle(color: AppColors.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 52),
            const SizedBox(height: 20),
            const Text(
              'Impossible de préparer la réunion',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.textOnPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppColors.radiusButton),
                  ),
                ),
                child: const Text('Retour'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const SizedBox(height: 32),
          _buildMeetingCard(),
          const Spacer(),
          _buildStartButton(),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Annuler',
              style: TextStyle(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(
            Icons.arrow_back_ios_new,
            color: AppColors.textPrimary,
            size: 20,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.meetingName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMeetingCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppColors.radiusCard),
        border: Border.all(color: AppColors.borderSubtle),
        boxShadow: AppColors.softShadow,
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              gradient: AppColors.primaryGradient,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.videocam_outlined,
              color: AppColors.textOnPrimary,
              size: 30,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Prêt à rejoindre',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Audio et vidéo via LiveKit avec transport WebRTC sécurisé.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 22),
          InkWell(
            onTap:
                () => _copyText(
                  _shareCode,
                  'Code de la réunion copié dans le presse-papiers.',
                ),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.tag,
                    color: AppColors.textTertiary,
                    size: 15,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    _shareCode,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.copy_outlined,
                    color: AppColors.textTertiary,
                    size: 15,
                  ),
                ],
              ),
            ),
          ),
          TextButton.icon(
            onPressed:
                () => _copyText(
                  AppConfig.webJoinLink(widget.meetingId),
                  'Lien d\'invitation copié.',
                ),
            icon: const Icon(Icons.link_outlined, size: 16),
            label: const Text(
              'Copier le lien d\'invitation',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const Divider(color: AppColors.borderSubtle, height: 28),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeTrackColor: AppColors.primary,
            value: _micOn,
            onChanged: _setMicDefault,
            secondary: Icon(
              _micOn ? Icons.mic : Icons.mic_off,
              color: _micOn ? AppColors.primary : AppColors.textTertiary,
              size: 22,
            ),
            title: const Text(
              'Rejoindre avec le micro activé',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeTrackColor: AppColors.primary,
            value: _camOn,
            onChanged: _setCamDefault,
            secondary: Icon(
              _camOn ? Icons.videocam : Icons.videocam_off,
              color: _camOn ? AppColors.primary : AppColors.textTertiary,
              size: 22,
            ),
            title: const Text(
              'Rejoindre avec la caméra activée',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStartButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: _joinCall,
        icon: const Icon(Icons.videocam_outlined),
        label: const Text(
          "DÉMARRER L'APPEL",
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .3),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.textOnPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusButton),
          ),
        ),
      ),
    );
  }
}
