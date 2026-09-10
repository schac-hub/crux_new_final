import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/colors.dart';
import '../services/meeting_service.dart';
import '../utils/logger.dart';
import '../widgets/custom_button.dart';
import 'meeting_screen.dart';
import 'large_conference_screen.dart';

/// Écran permettant à un utilisateur connecté de rejoindre une réunion
/// existante via son code. Appelé depuis HomeScreen : `JoinMeetingScreen()`.
class JoinMeetingScreen extends StatefulWidget {
  const JoinMeetingScreen({super.key});

  @override
  State<JoinMeetingScreen> createState() => _JoinMeetingScreenState();
}

class _JoinMeetingScreenState extends State<JoinMeetingScreen> {
  final _codeCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();
  bool _loading = false;
  bool _needsPasscode = false;
  String? _error;

  /// Réunion trouvée par code, en attente de validation (passcode, statut…).
  MeetingModel? _foundMeeting;

  @override
  void dispose() {
    _codeCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  String _displayName() {
    final fb = FirebaseAuth.instance.currentUser;
    if (fb?.displayName?.trim().isNotEmpty == true) return fb!.displayName!;
    if (fb?.email?.isNotEmpty == true && fb!.email!.contains('@')) {
      return fb.email!.split('@')[0];
    }
    return 'Utilisateur';
  }

  Future<void> _join() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _error = 'Entre le code de la réunion');
      return;
    }

    // Validate XXX-XXX-XXX format
    if (!RegExp(r'^[A-Z0-9]{3}-[A-Z0-9]{3}-[A-Z0-9]{3}$').hasMatch(code)) {
      setState(() => _error = 'Format invalide. Utilisez XXX-XXX-XXX');
      return;
    }

    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      setState(() => _error = 'Session expirée, reconnecte-toi');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      logger.i('🔍 Tentative de rejoindre réunion avec code: $code');

      // Recherche directe Firestore par meetingCode (BackendApiService est un
      // simple alias : une seule requête suffit désormais).
      final meeting = await MeetingService().getMeetingByCode(code);

      if (!mounted) return;

      if (meeting == null) {
        logger.e('❌ Réunion introuvable pour le code: $code');
        setState(() {
          _loading = false;
          _foundMeeting = null;
          _error = 'Réunion introuvable ou expirée';
        });
        return;
      }

      logger.i('✅ Réunion trouvée: ${meeting.id}');
      setState(() {
        _foundMeeting = meeting;
      });

      _tryEnter();
    } catch (e) {
      logger.e('❌ JoinMeetingScreen._join error', error: e);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de rejoindre la réunion. Réessaie.';
        });
      }
    }
  }

  /// Valide l'état de la réunion AVANT tout ajout de participant :
  /// statut, verrou hôte, puis passcode. Côté Zoom/Meet, aucune trace de
  /// présence ne doit exister tant que l'utilisateur n'est pas autorisé.
  void _tryEnter() {
    final meeting = _foundMeeting;
    if (meeting == null || !mounted) return;

    if (meeting.status == MeetingStatus.ended) {
      setState(() {
        _loading = false;
        _error = 'Cette réunion est terminée.';
      });
      return;
    }

    if (meeting.isLocked) {
      setState(() {
        _loading = false;
        _error = 'Réunion verrouillée par l\'hôte.';
      });
      return;
    }

    final hasPasscode = meeting.passcode != null && meeting.passcode!.isNotEmpty;
    if (hasPasscode && !_needsPasscode) {
      setState(() {
        _loading = false;
        _needsPasscode = true;
      });
      return;
    }
    if (hasPasscode && meeting.passcode != _passcodeCtrl.text.trim()) {
      setState(() {
        _loading = false;
        _error = 'Code d\'accès incorrect';
      });
      return;
    }

    _enterMeeting();
  }

  Future<void> _enterMeeting() async {
    final meeting = _foundMeeting;
    final current = FirebaseAuth.instance.currentUser;
    if (meeting == null || current == null || !mounted) return;

    try {
      await MeetingService().addParticipant(meeting.id, current.uid);
    } catch (e) {
      logger.w('Ajout participant échoué (jonction poursuivie)', error: e);
    }

    if (!mounted) return;

    if (meeting.isLargeConference) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder:
              (_) => LargeConferenceScreen(
                meetingId: meeting.id,
                meetingCode: meeting.meetingCode,
                meetingName: meeting.title,
                userId: current.uid,
                userName: _displayName(),
              ),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder:
              (_) => MeetingScreen(
                meetingId: meeting.id,
                meetingCode: meeting.meetingCode,
                meetingName: meeting.title,
                userId: current.uid,
                userName: _displayName(),
                userEmail: current.email,
                isHost: false,
                // Passcode déjà validé ici : MeetingScreen ne redemandera pas.
                preValidatedPasscode: meeting.passcode,
              ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Rejoindre une réunion',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.meeting_room,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Code de la réunion',
                style: GoogleFonts.poppins(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _codeCtrl,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(color: Colors.white, letterSpacing: 2),
                decoration: InputDecoration(
                  // CORRIGÉ : exemple au bon format XXX-XXX-XXX
                  hintText: 'Ex. AB3-CD7-9F2',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.primary),
                  ),
                ),
              ),
              if (_foundMeeting != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color:
                          _needsPasscode
                              ? AppColors.primary
                              : AppColors.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.videocam_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _foundMeeting!.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Organisée par ${_foundMeeting!.organizer}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_needsPasscode) ...[
                const SizedBox(height: 20),
                Text(
                  'Code d\'accès requis',
                  style: GoogleFonts.poppins(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _passcodeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(color: Colors.white, letterSpacing: 4),
                  decoration: InputDecoration(
                    hintText: '4 à 6 chiffres',
                    hintStyle: const TextStyle(color: Colors.white38),
                    counterStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: AppColors.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 28),
              CustomButton(
                label:
                    _loading
                        ? 'Recherche…'
                        : (_needsPasscode ? 'Valider le code' : 'Rejoindre'),
                isLoading: _loading,
                onPressed: _loading ? () {} : _join,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
