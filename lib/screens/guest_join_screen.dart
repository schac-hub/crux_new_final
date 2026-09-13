import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/meeting_service.dart';
import '../theme/colors.dart';
import 'meeting_screen.dart';
import 'large_conference_screen.dart';
import '../widgets/app_logo.dart';

/// Screen shown when a guest taps a meeting link (crux://join/MEETING_ID).
/// Signs in anonymously — no account required.
class GuestJoinScreen extends StatefulWidget {
  final String meetingId;

  const GuestJoinScreen({super.key, required this.meetingId});

  @override
  State<GuestJoinScreen> createState() => _GuestJoinScreenState();
}

class _GuestJoinScreenState extends State<GuestJoinScreen> {
  final _nameCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _needsPasscode = false;
  bool _meetingExists = true;
  bool _meetingEnded = false;
  String _meetingTitle = 'Réunion';
  bool _isLarge = false;

  /// ID de document résolu : le paramètre du lien peut être un CODE de
  /// réunion (ABC-DEFG-HIJ, réunions programmées) et non un ID Firestore.
  String? _resolvedMeetingId;

  @override
  void initState() {
    super.initState();
    _checkMeeting();
  }

  Future<void> _checkMeeting() async {
    // Résout ID de document OU code de réunion (liens partagés).
    final doc = await MeetingService().resolveMeetingDoc(
      widget.meetingId.trim(),
    );
    if (!mounted) return;
    if (doc == null) {
      setState(() => _meetingExists = false);
      return;
    }
    final meeting = MeetingModel.fromDoc(doc.id, doc.data()!);
    setState(() => _resolvedMeetingId = doc.id);
    if (meeting.status == MeetingStatus.ended) {
      // L'hôte a clôturé la réunion : plus aucune entrée possible.
      setState(() {
        _meetingExists = false;
        _meetingEnded = true;
      });
      return;
    }
    setState(() {
      _needsPasscode = meeting.passcode != null && meeting.passcode!.isNotEmpty;
      if (meeting.title.isNotEmpty) _meetingTitle = meeting.title;
      _isLarge = meeting.isLargeConference;
    });
  }

  Future<void> _join() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Entre ton prénom pour continuer');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 1. Ensure the user is authenticated (anonymous or real account)
      User? current = FirebaseAuth.instance.currentUser;
      if (current == null) {
        final cred = await FirebaseAuth.instance.signInAnonymously();
        current = cred.user!;
      }
      await current.updateDisplayName(name);
      final uid = current.uid;

      // 2. Check passcode if needed
      if (_needsPasscode) {
        final meeting = await MeetingService().getMeetingOnce(
          _resolvedMeetingId ?? widget.meetingId,
        );
        if (meeting?.passcode != null &&
            meeting!.passcode!.isNotEmpty &&
            meeting.passcode != _passcodeCtrl.text.trim()) {
          setState(() {
            _error = 'Code d\'accès incorrect';
            _loading = false;
          });
          return;
        }
      }

      // 3. Write guest profile to Firestore (best-effort)
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'uid': uid,
          'name': name,
          'email': '',
          'isGuest': true,
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}

      // 4. Enregistrer l'invité dans `participants` : sans cela les règles
      // Firestore lui refusaient chat, sondages et fichiers.
      final resolvedId = _resolvedMeetingId ?? widget.meetingId;

      try {
        await MeetingService().addParticipant(resolvedId, uid);
      } catch (_) {}

      if (!mounted) return;

      if (_isLarge) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (_) => LargeConferenceScreen(
                  meetingId: resolvedId,
                  meetingName: _meetingTitle,
                  userId: uid,
                  userName: name,
                  userEmail: null,
                  isHost: false,
                ),
          ),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (_) => MeetingScreen(
                  meetingId: resolvedId,
                  meetingName: _meetingTitle,
                  userId: uid,
                  userName: name,
                  userEmail: null,
                  isHost: false,
                ),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = e.message ?? 'Erreur de connexion';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Erreur inattendue: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: !_meetingExists ? _buildNotFound() : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildNotFound() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _meetingEnded ? Icons.meeting_room : Icons.link_off,
          size: 64,
          color: Colors.white38,
        ),
        const SizedBox(height: 20),
        Text(
          _meetingEnded ? 'Réunion terminée' : 'Réunion introuvable',
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _meetingEnded
              ? 'L\'hôte a clôturé la réunion ${widget.meetingId}. '
                  'Elle n\'est plus accessible.'
              : 'Le code ${widget.meetingId} n\'existe pas ou a expiré.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(color: Colors.white54, fontSize: 14),
        ),
        const SizedBox(height: 28),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Retour',
            style: GoogleFonts.poppins(color: AppColors.primary),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Logo / icon
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFB71C1C), Color(0xFF6A1B9A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const AppLogoBadge(size: 72, borderRadius: 20),
        ),
        const SizedBox(height: 20),
        Text(
          _meetingTitle,
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Code : ${widget.meetingId}',
          style: GoogleFonts.poppins(
            color: Colors.white38,
            fontSize: 13,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 32),

        // Name field
        _Field(
          controller: _nameCtrl,
          label: 'Ton prénom ou surnom',
          icon: Icons.person_outline,
          textInputAction:
              _needsPasscode ? TextInputAction.next : TextInputAction.done,
          onSubmitted: _needsPasscode ? null : (_) => _join(),
        ),

        if (_needsPasscode) ...[
          const SizedBox(height: 16),
          _Field(
            controller: _passcodeCtrl,
            label: 'Code d\'accès',
            icon: Icons.lock_outline,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _join(),
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(color: Colors.redAccent, fontSize: 13),
          ),
        ],

        const SizedBox(height: 28),

        // Join button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _loading ? null : _join,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child:
                _loading
                    ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                    : Text(
                      'Rejoindre',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
          ),
        ),

        const SizedBox(height: 20),
        Text(
          'Aucun compte requis',
          style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.pushReplacementNamed(context, '/login'),
          child: Text(
            'Connexion avec un compte existant',
            style: GoogleFonts.poppins(color: AppColors.primary, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: GoogleFonts.poppins(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.poppins(color: Colors.white54, fontSize: 14),
        prefixIcon: Icon(icon, color: Colors.white38, size: 20),
        filled: true,
        fillColor: const Color(0xFF12121E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}
