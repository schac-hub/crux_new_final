import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/colors.dart';
import '../services/meeting_service.dart';
import '../utils/logger.dart';
import '../widgets/custom_button.dart';
import 'meeting_screen.dart';
import 'large_conference_screen.dart';

/// Écran de création d'une réunion (standard ou grande conférence).
class CreateMeetingScreen extends StatefulWidget {
  final bool largeConference;

  const CreateMeetingScreen({
    super.key,
    this.largeConference = false,
  });

  @override
  State<CreateMeetingScreen> createState() =>
      _CreateMeetingScreenState();
}

class _CreateMeetingScreenState
    extends State<CreateMeetingScreen> {
  final _titleCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();

  bool _showPasscode = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  String _displayName() {
    final fb = FirebaseAuth.instance.currentUser;

    if (fb?.displayName?.trim().isNotEmpty == true) {
      return fb!.displayName!;
    }

    if (fb?.email?.isNotEmpty == true &&
        fb!.email!.contains('@')) {
      return fb.email!.split('@')[0];
    }

    return 'Utilisateur';
  }

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();

    if (title.isEmpty) {
      setState(() {
        _error = 'Donne un titre à ta réunion';
      });
      return;
    }

    final passcode = _passcodeCtrl.text.trim();

    if (passcode.isNotEmpty &&
        (passcode.length < 4 || passcode.length > 6)) {
      setState(() {
        _error =
            'Le code d\'accès doit faire 4 à 6 chiffres';
      });
      return;
    }

    if (passcode.isNotEmpty &&
        !RegExp(r'^\d+$').hasMatch(passcode)) {
      setState(() {
        _error =
            'Le code d\'accès ne doit contenir que des chiffres';
      });
      return;
    }

    final current = FirebaseAuth.instance.currentUser;

    if (current == null) {
      setState(() {
        _error = 'Session expirée, reconnecte-toi';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final meetingId =
          await MeetingService().createMeeting(
        title: title,
        description: '',
        organizerName: _displayName(),
        organizerId: current.uid,
        passcode:
            passcode.isNotEmpty ? passcode : null,
        isLargeConference: widget.largeConference,
      );

      logger.i(
        '✅ Réunion créée via direct Firestore: $meetingId',
      );

      if (!mounted) return;

      if (widget.largeConference) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => LargeConferenceScreen(
              meetingId: meetingId,
              meetingName: title,
              userId: current.uid,
              userName: _displayName(),
              userEmail: current.email,
              isHost: true,
            ),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => MeetingScreen(
              meetingId: meetingId,
              meetingName: title,
              userId: current.uid,
              userName: _displayName(),
              userEmail: current.email,
              isHost: true,
            ),
          ),
        );
      }
    } catch (e) {
      logger.e(
        'CreateMeetingScreen._create error',
        error: e,
      );

      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'Impossible de créer la réunion. Réessaie.';
        });
      }
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
          widget.largeConference
              ? 'Grande conférence'
              : 'Nouvelle réunion',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 16,
          ),
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
                child: Icon(
                  widget.largeConference
                      ? Icons.groups
                      : Icons.video_call,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Titre de la réunion',
                style: GoogleFonts.poppins(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _titleCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Ex. Point d\'équipe hebdo',
                  hintStyle:
                      const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: AppColors.border,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: AppColors.border,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: AppColors.primary,
                value: _showPasscode,
                onChanged: (v) {
                  setState(() => _showPasscode = v);
                },
                title: Text(
                  'Protéger avec un code d\'accès',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 14,
                  ),
                ),
              ),
              if (_showPasscode) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _passcodeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(
                    color: Colors.white,
                    letterSpacing: 4,
                  ),
                  decoration: InputDecoration(
                    hintText: '4 à 6 chiffres',
                    hintStyle: const TextStyle(
                      color: Colors.white38,
                    ),
                    counterStyle: const TextStyle(
                      color: Colors.white38,
                    ),
                    filled: true,
                    fillColor:
                        AppColors.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: AppColors.border,
                      ),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              CustomButton(
                label: _loading
                    ? 'Création…'
                    : 'Démarrer la réunion',
                isLoading: _loading,
                onPressed: _loading ? () {} : _create,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
