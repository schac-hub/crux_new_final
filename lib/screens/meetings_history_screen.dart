import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/meeting_model.dart';
import '../services/participant_photo_cache.dart';
import '../theme/colors.dart';

/// Onglet « Réunions » de l'accueil : les réunions récentes/non terminées
/// (rejoignables à nouveau) puis l'historique complet avec notes.
class MeetingsHistoryScreen extends StatelessWidget {
  final String userId;

  const MeetingsHistoryScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: Text(
            'Mes réunions',
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          bottom: const TabBar(
            indicatorColor: AppColors.primary,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textTertiary,
            tabs: [
              Tab(text: 'Récentes'),
              Tab(text: 'Historique'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _RecentMeetingsTab(userId: userId),
            _HistoryTab(userId: userId),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// RÉCENTES : réunions non terminées où je suis participant/organisateur
// =============================================================================

class _RecentMeetingsTab extends StatelessWidget {
  final String userId;

  const _RecentMeetingsTab({required this.userId});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    // Requête simple sans index composé : participants array-contains, tri
    // client sur createdAt.
    final stream = db
        .collection('meetings')
        .where('participants', arrayContains: userId)
        .orderBy('createdAt', descending: true)
        .limit(30)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }
        if (snap.hasError) {
          return const _Empty(
            icon: Icons.error_outline,
            text: 'Impossible de charger les réunions.',
          );
        }

        final docs =
            snap.data?.docs ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        final meetings = docs
            .map((d) => MeetingModel.fromJson({...d.data(), 'id': d.id}))
            .where((m) => m.status != MeetingStatus.ended)
            .toList();

        if (meetings.isEmpty) {
          return const _Empty(
            icon: Icons.videocam_off_outlined,
            text: 'Aucune réunion en cours.\nLancez-en une depuis l\'accueil.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: meetings.length,
          itemBuilder: (_, i) =>
              _MeetingCard(meeting: meetings[i], userId: userId),
        );
      },
    );
  }
}

// =============================================================================
// HISTORIQUE : toutes les réunions passées + notes enregistrées
// =============================================================================

class _HistoryTab extends StatelessWidget {
  final String userId;

  const _HistoryTab({required this.userId});

  @override
  Widget build(BuildContext context) {
    final notesStream = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('notes')
        .orderBy('updatedAt', descending: true)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: notesStream,
      builder: (context, notesSnap) {
        if (notesSnap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          );
        }

        final notes =
            notesSnap.data?.docs ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

        if (notes.isEmpty) {
          return const _Empty(
            icon: Icons.history_edu,
            text:
                'Aucune note enregistrée.\n'
                'Dans une réunion, ouvrez Notes puis « Sauvegarder » : '
                'elles apparaîtront ici.',
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: notes.length,
          itemBuilder: (_, i) {
            final data = notes[i].data();
            final meetingName =
                (data['meetingName'] as String?) ?? 'Réunion';
            final content = (data['content'] as String?) ?? '';
            final updatedAt = data['updatedAt'] as Timestamp?;

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppColors.radiusCard),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                leading: const CircleAvatar(
                  backgroundColor: AppColors.surfaceVariant,
                  child: Icon(Icons.sticky_note_2_outlined,
                      color: AppColors.primary, size: 20),
                ),
                title: Text(
                  meetingName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.poppins(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (updatedAt != null)
                      Text(
                        '${updatedAt.toDate().day}/${updatedAt.toDate().month}/${updatedAt.toDate().year}',
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                    if (content.isNotEmpty)
                      Text(
                        content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                onTap: () => _showNoteDetail(context, meetingName, content),
              ),
            );
          },
        );
      },
    );
  }

  void _showNoteDetail(BuildContext context, String name, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: Text(
          name,
          style: GoogleFonts.poppins(color: AppColors.textPrimary),
        ),
        content: SingleChildScrollView(
          child: Text(
            content.isEmpty ? '(Note vide)' : content,
            style: GoogleFonts.poppins(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Fermer',
              style: TextStyle(color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CARTE RÉUNION (récentes)
// =============================================================================

class _MeetingCard extends StatelessWidget {
  final MeetingModel meeting;
  final String userId;

  const _MeetingCard({required this.meeting, required this.userId});

  @override
  Widget build(BuildContext context) {
    final isOngoing = meeting.status == MeetingStatus.ongoing;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppColors.radiusCard),
        border: Border.all(
          color: isOngoing
              ? AppColors.success.withValues(alpha: 0.4)
              : AppColors.borderSubtle,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 8,
        ),
        leading: _OrganizerAvatar(uid: meeting.organizerId),
        title: Text(
          meeting.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.poppins(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOngoing ? AppColors.success : AppColors.textTertiary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              isOngoing ? 'En cours' : 'Planifiée',
              style: TextStyle(
                color: isOngoing ? AppColors.success : AppColors.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              meeting.meetingCode.isEmpty ? meeting.id : meeting.meetingCode,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        trailing: ElevatedButton(
          onPressed: () => _join(context),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.textOnPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: const Text('Rejoindre'),
        ),
      ),
    );
  }

  void _join(BuildContext context) {
    Navigator.of(context).pushNamed(
      '/meeting',
      arguments: {
        'meetingId': meeting.id,
        'meetingCode': meeting.meetingCode,
        'meetingName': meeting.title,
        'userId': userId,
        'userName':
            FirebaseAuth.instance.currentUser?.displayName ??
            FirebaseAuth.instance.currentUser?.email?.split('@')[0] ??
            'Utilisateur',
        'userEmail': FirebaseAuth.instance.currentUser?.email,
        'isHost': meeting.organizerId == userId,
      },
    );
  }
}

class _OrganizerAvatar extends StatefulWidget {
  final String uid;
  const _OrganizerAvatar({required this.uid});

  @override
  State<_OrganizerAvatar> createState() => _OrganizerAvatarState();
}

class _OrganizerAvatarState extends State<_OrganizerAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    ParticipantPhotoCache.photoFor(widget.uid).then((b) {
      if (mounted) setState(() => _bytes = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      backgroundColor: AppColors.surfaceVariant,
      backgroundImage: _bytes != null ? MemoryImage(_bytes!) : null,
      child: _bytes == null
          ? const Icon(Icons.videocam_outlined,
              color: AppColors.primary, size: 20)
          : null,
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Empty({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: AppColors.textTertiary),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
