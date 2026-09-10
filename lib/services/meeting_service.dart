import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:logger/logger.dart';

import '../models/meeting_model.dart';
import '../models/scheduled_meeting_model.dart';

export '../models/meeting_model.dart';
export '../models/scheduled_meeting_model.dart';

class MeetingService {
  static final MeetingService _instance = MeetingService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final Logger _log = Logger();

  factory MeetingService() => _instance;

  MeetingService._internal();

  // ---------------------------------------------------------------------------
  // AUTH
  // ---------------------------------------------------------------------------

  String _getCurrentUserId() {
    final userId = _auth.currentUser?.uid;

    if (userId == null || userId.isEmpty) {
      throw Exception('auth_required');
    }

    return userId;
  }

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  String _generateMeetingId() {
    return const Uuid().v4().replaceAll('-', '').substring(0, 12).toUpperCase();
  }

  String _generateMeetingCode() {
    // Generate XXX-XXX-XXX format (9 characters with dashes)
    final chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = DateTime.now().millisecondsSinceEpoch;

    String generateSegment(int offset) {
      String segment = '';
      for (int i = 0; i < 3; i++) {
        segment += chars[((random + offset + i * 17) * (i + 1)) % chars.length];
      }
      return segment;
    }

    return '${generateSegment(0)}-${generateSegment(100)}-${generateSegment(200)}';
  }

  String _enumValue(Object value) {
    return value.toString().split('.').last;
  }

  // ---------------------------------------------------------------------------
  // CREATE IMMEDIATE MEETING
  // ---------------------------------------------------------------------------

  /// Crée une réunion immédiate et retourne le modèle complet
  /// (id + meetingCode XXX-XXX-XXX + passcode) pour naviguer sans
  /// re-lire le document dans Firestore.
  Future<MeetingModel> createMeeting({
    required String title,
    required String description,
    required String organizerName,
    String? organizerId,
    String? passcode,
    bool isLargeConference = false,
  }) async {
    try {
      final userId = _getCurrentUserId();

      final cleanTitle = title.trim();
      final cleanDescription = description.trim();
      final cleanOrganizerName = organizerName.trim();

      if (cleanTitle.isEmpty) {
        throw Exception('title_required');
      }

      if (cleanOrganizerName.isEmpty) {
        throw Exception('organizer_name_required');
      }

      // Le compte authentifié reste la source de vérité.
      final finalOrganizerId = userId;

      // Si un organizerId est fourni, il doit correspondre
      // au compte actuellement authentifié.
      if (organizerId != null &&
          organizerId.isNotEmpty &&
          organizerId != userId) {
        _log.w(
          'organizerId fourni ($organizerId) différent du compte '
          'authentifié ($userId). Utilisation de $userId.',
        );
      }

      final cleanPasscode =
          passcode?.trim().isNotEmpty == true ? passcode!.trim() : null;

      if (cleanPasscode != null) {
        if (cleanPasscode.length < 4 || cleanPasscode.length > 6) {
          throw Exception('passcode_invalid_length');
        }

        if (!RegExp(r'^\d+$').hasMatch(cleanPasscode)) {
          throw Exception('passcode_must_be_digits');
        }
      }

      final meetingId = _generateMeetingId();
      final meetingCode = _generateMeetingCode();
      final now = DateTime.now();

      final meeting = MeetingModel(
        id: meetingId,
        title: cleanTitle,
        description: cleanDescription,
        organizer: cleanOrganizerName,
        organizerId: finalOrganizerId,
        startTime: now,
        endTime: now.add(const Duration(hours: 1)),
        participants: [finalOrganizerId],
        channelName: meetingId,
        status: MeetingStatus.ongoing,
        createdAt: now,
        passcode: cleanPasscode,
        isLargeConference: isLargeConference,
        meetingCode: meetingCode,
      );

      final meetingRef = _firestore.collection('meetings').doc(meetingId);

      bool written = false;

      for (int attempt = 0; attempt < 3 && !written; attempt++) {
        try {
          await meetingRef.set(meeting.toJson());

          written = true;

          _log.i('Réunion créée: $meetingId');
        } catch (e, stackTrace) {
          _log.w(
            'createMeeting attempt ${attempt + 1} failed: $e',
            error: e,
            stackTrace: stackTrace,
          );

          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 100 * (1 << attempt)));
          }
        }
      }

      if (!written) {
        throw Exception('firestore_write_failed');
      }

      // Vérification serveur.
      try {
        final snap = await meetingRef.get(
          const GetOptions(source: Source.server),
        );

        if (!snap.exists) {
          throw Exception('meeting_verification_failed');
        }

        _log.d('Réunion vérifiée sur Firestore: $meetingId');
      } catch (e) {
        _log.e('Vérification Firestore échouée: $e');

        // Ici on ne masque plus l'erreur de vérification.
        rethrow;
      }

      return meeting;
    } on FirebaseAuthException catch (e) {
      _log.e('Firebase Auth error: ${e.code}');
      throw Exception('auth_failed: ${e.code}');
    } catch (e, stackTrace) {
      _log.e('createMeeting error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // SCHEDULED PROFESSIONAL MEETING
  // ---------------------------------------------------------------------------

  Future<ScheduledMeetingModel> scheduleProMeeting({
    required String title,
    required String description,
    required String organizerName,
    required String organizerEmail,
    DateTime? startTime,
    DateTime? endTime,
    String timezone = 'UTC',
    String? passcode,
    bool waitingRoomEnabled = false,
    bool allowBeforeHost = false,
    bool disableGuests = false,
    bool cameraEnabled = true,
    bool microphoneEnabled = true,
    bool screenShareEnabled = true,
    bool chatEnabled = true,
    bool reactionsEnabled = true,
    bool recordAutomatically = false,
    String recordingType = 'none',
    List<String> invitedEmails = const [],
    bool notifyAtOneHour = true,
    bool notifyAtFifteenMin = true,
    bool notifyAtFiveMin = true,
    bool notifyAtStart = true,
    MeetingType meetingType = MeetingType.standard,
    bool isLargeConference = false,
    Map<String, dynamic> customSettings = const {},
  }) async {
    try {
      final userId = _getCurrentUserId();

      final cleanTitle = title.trim();
      final cleanDescription = description.trim();
      final cleanOrganizerName = organizerName.trim();
      final cleanOrganizerEmail = organizerEmail.trim();

      if (cleanTitle.isEmpty) {
        throw Exception('title_required');
      }

      if (cleanOrganizerName.isEmpty) {
        throw Exception('organizer_name_required');
      }

      if (cleanOrganizerEmail.isEmpty) {
        throw Exception('organizer_email_required');
      }

      final now = DateTime.now();

      final start = startTime ?? now.add(const Duration(hours: 1));
      final end = endTime ?? start.add(const Duration(hours: 1));

      if (start.isBefore(now.subtract(const Duration(minutes: 5)))) {
        throw Exception('start_time_in_past');
      }

      if (!end.isAfter(start)) {
        throw Exception('end_time_before_start');
      }

      final cleanPasscode =
          passcode?.trim().isNotEmpty == true ? passcode!.trim() : null;

      if (cleanPasscode != null) {
        if (cleanPasscode.length < 4 || cleanPasscode.length > 6) {
          throw Exception('passcode_invalid_length');
        }

        if (!RegExp(r'^\d+$').hasMatch(cleanPasscode)) {
          throw Exception('passcode_must_be_digits');
        }
      }

      final cleanInvitedEmails =
          invitedEmails
              .map((email) => email.trim().toLowerCase())
              .where((email) => email.isNotEmpty)
              .toSet()
              .toList();

      final meetingId = _generateMeetingId();
      final meetingCode = _generateMeetingCode();

      final meetingLink = 'https://crux-app.web/join/$meetingId';

      final meeting = ScheduledMeetingModel(
        id: meetingId,
        title: cleanTitle,
        description: cleanDescription,
        organizerId: userId,
        organizerName: cleanOrganizerName,
        organizerEmail: cleanOrganizerEmail,
        createdAt: now,
        scheduledStart: start,
        scheduledEnd: end,
        timezone: timezone,
        status: ScheduledMeetingStatus.scheduled,
        passcode: cleanPasscode,
        waitingRoomEnabled: waitingRoomEnabled,
        allowBeforeHost: allowBeforeHost,
        disableGuests: disableGuests,
        cameraEnabled: cameraEnabled,
        microphoneEnabled: microphoneEnabled,
        screenShareEnabled: screenShareEnabled,
        chatEnabled: chatEnabled,
        reactionsEnabled: reactionsEnabled,
        recordAutomatically: recordAutomatically,
        recordingType: recordingType,
        participants: [userId],
        invitedEmails: cleanInvitedEmails,
        coHosts: const [],
        notifyAtOneHour: notifyAtOneHour,
        notifyAtFifteenMin: notifyAtFifteenMin,
        notifyAtFiveMin: notifyAtFiveMin,
        notifyAtStart: notifyAtStart,
        meetingLink: meetingLink,
        meetingCode: meetingCode,
        meetingType: meetingType,
        isLargeConference: isLargeConference,
        settings: Map<String, dynamic>.from(customSettings),
      );

      final meetingRef = _firestore
          .collection('scheduled_meetings')
          .doc(meetingId);

      bool written = false;

      for (int attempt = 0; attempt < 3 && !written; attempt++) {
        try {
          await meetingRef.set(meeting.toJson());

          written = true;

          _log.i(
            'Réunion planifiée créée: '
            '$meetingId (${meeting.scheduledStart})',
          );
        } catch (e, stackTrace) {
          _log.w(
            'scheduleProMeeting attempt ${attempt + 1} failed: $e',
            error: e,
            stackTrace: stackTrace,
          );

          if (attempt < 2) {
            await Future.delayed(Duration(milliseconds: 100 * (1 << attempt)));
          }
        }
      }

      if (!written) {
        throw Exception('firestore_write_failed');
      }

      return meeting;
    } on FirebaseAuthException catch (e) {
      _log.e('Firebase Auth error: ${e.code}');
      throw Exception('auth_failed: ${e.code}');
    } catch (e, stackTrace) {
      _log.e('scheduleProMeeting error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // LEGACY SCHEDULE METHOD
  // ---------------------------------------------------------------------------

  Future<String> scheduleMeeting({
    required String title,
    required String description,
    required String organizerName,
    required DateTime startTime,
    String? passcode,
  }) async {
    try {
      final currentUser = _auth.currentUser;

      if (currentUser == null) {
        throw Exception('auth_required');
      }

      final meeting = await scheduleProMeeting(
        title: title,
        description: description,
        organizerName: organizerName,
        organizerEmail: currentUser.email ?? 'unknown@crux.app',
        startTime: startTime,
        passcode: passcode,
      );

      return meeting.id;
    } on FirebaseAuthException catch (e) {
      _log.e('Firebase Auth error: ${e.code}');
      throw Exception('auth_failed: ${e.code}');
    } catch (e, stackTrace) {
      _log.e('scheduleMeeting error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // GET MEETING
  // ---------------------------------------------------------------------------

  Stream<MeetingModel?> getMeeting(String meetingId) {
    return _firestore.collection('meetings').doc(meetingId).snapshots().map((
      snap,
    ) {
      if (!snap.exists || snap.data() == null) {
        return null;
      }

      return MeetingModel.fromJson(snap.data()!);
    });
  }

  Future<MeetingModel?> getMeetingOnce(String meetingId) async {
    try {
      final snap = await _firestore
          .collection('meetings')
          .doc(meetingId)
          .get(const GetOptions(source: Source.server));

      if (!snap.exists || snap.data() == null) {
        return null;
      }

      return MeetingModel.fromJson(snap.data()!);
    } catch (e) {
      _log.w('getMeetingOnce server error: $e');

      try {
        final snap =
            await _firestore.collection('meetings').doc(meetingId).get();

        if (!snap.exists || snap.data() == null) {
          return null;
        }

        return MeetingModel.fromJson(snap.data()!);
      } catch (fallbackError) {
        _log.w('getMeetingOnce fallback error: $fallbackError');

        return null;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // GET MEETING BY CODE
  // ---------------------------------------------------------------------------

  Future<MeetingModel?> getMeetingByCode(String meetingCode) async {
    final upperCode = meetingCode.trim().toUpperCase();

    if (upperCode.isEmpty) {
      return null;
    }

    try {
      final snap = await _firestore
          .collection('meetings')
          .where('meetingCode', isEqualTo: upperCode)
          .limit(1)
          .get(const GetOptions(source: Source.server));

      if (snap.docs.isEmpty) {
        return null;
      }

      return MeetingModel.fromJson(snap.docs.first.data());
    } catch (e) {
      _log.w('getMeetingByCode server error: $e');

      try {
        final snap =
            await _firestore
                .collection('meetings')
                .where('meetingCode', isEqualTo: upperCode)
                .limit(1)
                .get();

        if (snap.docs.isEmpty) {
          return null;
        }

        return MeetingModel.fromJson(snap.docs.first.data());
      } catch (fallbackError) {
        _log.w('getMeetingByCode fallback error: $fallbackError');

        return null;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // GET SCHEDULED MEETING
  // ---------------------------------------------------------------------------

  Future<ScheduledMeetingModel?> getScheduledMeeting(String meetingId) async {
    try {
      final snap = await _firestore
          .collection('scheduled_meetings')
          .doc(meetingId)
          .get(const GetOptions(source: Source.server));

      if (!snap.exists || snap.data() == null) {
        return null;
      }

      return ScheduledMeetingModel.fromJson(snap.data()!);
    } catch (e) {
      _log.w('getScheduledMeeting error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // STREAM USER SCHEDULED MEETINGS
  // ---------------------------------------------------------------------------

  Stream<List<ScheduledMeetingModel>> streamUserScheduledMeetings(
    String userId, {
    ScheduledMeetingStatus? statusFilter,
  }) {
    Query<Map<String, dynamic>> query = _firestore
        .collection('scheduled_meetings')
        .where('participants', arrayContains: userId);

    if (statusFilter != null) {
      query = query.where('status', isEqualTo: _enumValue(statusFilter));
    }

    query = query.orderBy('scheduledStart');

    return query.snapshots().map((snap) {
      return snap.docs
          .map((doc) => ScheduledMeetingModel.fromJson(doc.data()))
          .toList();
    });
  }

  // ---------------------------------------------------------------------------
  // STATUS
  // ---------------------------------------------------------------------------

  Future<void> updateMeetingStatus(
    String meetingId,
    MeetingStatus status,
  ) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'status': _enumValue(status),
      });
    } catch (e, stackTrace) {
      _log.e('updateMeetingStatus error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> updateScheduledMeetingStatus(
    String meetingId,
    ScheduledMeetingStatus status,
  ) async {
    try {
      final Map<String, dynamic> data = {'status': _enumValue(status)};

      if (status == ScheduledMeetingStatus.live) {
        data['actualStart'] = FieldValue.serverTimestamp();
      } else if (status == ScheduledMeetingStatus.ended) {
        data['actualEnd'] = FieldValue.serverTimestamp();
      }

      await _firestore
          .collection('scheduled_meetings')
          .doc(meetingId)
          .update(data);

      _log.i(
        'Statut réunion planifiée mis à jour: '
        '$meetingId -> ${_enumValue(status)}',
      );
    } catch (e, stackTrace) {
      _log.e(
        'updateScheduledMeetingStatus error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // CANCEL
  // ---------------------------------------------------------------------------

  Future<void> cancelScheduledMeeting(
    String meetingId, {
    String reason = 'Cancelled by organizer',
  }) async {
    try {
      await _firestore.collection('scheduled_meetings').doc(meetingId).update({
        'status': _enumValue(ScheduledMeetingStatus.cancelled),
        'cancellationReason': reason,
      });

      _log.i('Réunion planifiée annulée: $meetingId');
    } catch (e, stackTrace) {
      _log.e(
        'cancelScheduledMeeting error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // PARTICIPANTS
  // ---------------------------------------------------------------------------

  Future<void> addParticipant(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'participants': FieldValue.arrayUnion([userId]),
      });
    } catch (e, stackTrace) {
      _log.e('addParticipant error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> addParticipantToScheduled(
    String meetingId,
    String userId,
  ) async {
    try {
      await _firestore.collection('scheduled_meetings').doc(meetingId).update({
        'participants': FieldValue.arrayUnion([userId]),
      });
    } catch (e, stackTrace) {
      _log.e(
        'addParticipantToScheduled error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> removeParticipantFromScheduled(
    String meetingId,
    String userId,
  ) async {
    try {
      await _firestore.collection('scheduled_meetings').doc(meetingId).update({
        'participants': FieldValue.arrayRemove([userId]),
      });
    } catch (e, stackTrace) {
      _log.e(
        'removeParticipantFromScheduled error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> removeParticipant(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'participants': FieldValue.arrayRemove([userId]),
      });
    } catch (e, stackTrace) {
      _log.e('removeParticipant error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // PRESENCE
  // ---------------------------------------------------------------------------

  Future<void> registerPresence(
    String meetingId,
    String userId,
    String userName,
  ) async {
    try {
      await _firestore
          .collection('meetings')
          .doc(meetingId)
          .collection('presence')
          .doc(userId)
          .set({
            'userId': userId,
            'name': userName,
            'micOn': true,
            'camOn': true,
            'handRaised': false,
            'isSpeaking': false,
            'joinedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e, stackTrace) {
      _log.e('registerPresence error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> removePresence(String meetingId, String userId) async {
    try {
      await _firestore
          .collection('meetings')
          .doc(meetingId)
          .collection('presence')
          .doc(userId)
          .delete();
    } catch (e, stackTrace) {
      _log.e('removePresence error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // HISTORY
  // ---------------------------------------------------------------------------

  Future<void> saveMeetingHistoryForUser({
    required String meetingId,
    required String userId,
    required String title,
    required int durationSeconds,
    bool endMeeting = false,
  }) async {
    try {
      final userRef = _firestore.collection('users').doc(userId);

      final historyRef = userRef.collection('meeting_history').doc(meetingId);

      final meetingRef = _firestore.collection('meetings').doc(meetingId);

      final safeDuration = durationSeconds < 0 ? 0 : durationSeconds;

      await _firestore.runTransaction((transaction) async {
        final existingHistory = await transaction.get(historyRef);

        transaction.set(historyRef, {
          'meetingId': meetingId,
          'title': title,
          'duration': safeDuration,
          'endedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (!existingHistory.exists) {
          transaction.set(userRef, {
            'meetingCount': FieldValue.increment(1),
            'totalDuration': FieldValue.increment(safeDuration),
          }, SetOptions(merge: true));
        }

        if (endMeeting) {
          transaction.set(meetingRef, {
            'status': _enumValue(MeetingStatus.ended),
            'endedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      });
    } catch (e, stackTrace) {
      _log.e(
        'saveMeetingHistoryForUser error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // PRESENCE STREAM
  // ---------------------------------------------------------------------------

  Stream<List<Map<String, dynamic>>> streamPresence(String meetingId) {
    return _firestore
        .collection('meetings')
        .doc(meetingId)
        .collection('presence')
        .snapshots()
        .map((snap) => snap.docs.map((doc) => doc.data()).toList());
  }

  // ---------------------------------------------------------------------------
  // LOCK / MUTE ALL
  // ---------------------------------------------------------------------------

  Future<void> setLocked(String meetingId, bool locked) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'isLocked': locked,
      });
    } catch (e, stackTrace) {
      _log.e('setLocked error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> triggerMuteAll(String meetingId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'muteAllCount': FieldValue.increment(1),
      });
    } catch (e, stackTrace) {
      _log.e('triggerMuteAll error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // CO-HOSTS
  // ---------------------------------------------------------------------------

  Future<void> addCoHost(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'coHosts': FieldValue.arrayUnion([userId]),
      });
    } catch (e, stackTrace) {
      _log.e('addCoHost error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> addCoHostToScheduled(String meetingId, String userId) async {
    try {
      await _firestore.collection('scheduled_meetings').doc(meetingId).update({
        'coHosts': FieldValue.arrayUnion([userId]),
      });
    } catch (e, stackTrace) {
      _log.e(
        'addCoHostToScheduled error: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> removeCoHost(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'coHosts': FieldValue.arrayRemove([userId]),
      });
    } catch (e, stackTrace) {
      _log.e('removeCoHost error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // JOIN BY CODE
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> joinMeetingByCode(
    String meetingCode,
    String userId,
  ) async {
    try {
      final authenticatedUserId = _getCurrentUserId();

      if (userId.trim().isEmpty) {
        throw Exception('user_id_empty');
      }

      if (userId != authenticatedUserId) {
        throw Exception('user_id_mismatch');
      }

      final cleanCode = meetingCode.trim().toUpperCase();

      if (cleanCode.isEmpty) {
        throw Exception('meeting_code_empty');
      }

      final snapshot =
          await _firestore
              .collection('meetings')
              .where('meetingCode', isEqualTo: cleanCode)
              .limit(1)
              .get();

      if (snapshot.docs.isEmpty) {
        _log.e('Réunion non trouvée: $cleanCode');

        throw Exception('meeting_not_found');
      }

      final meetingDoc = snapshot.docs.first;

      final meetingId = meetingDoc.id;

      final meeting = MeetingModel.fromDoc(meetingId, meetingDoc.data());

      // Vérification d'une réunion terminée.
      if (meeting.status == MeetingStatus.ended) {
        throw Exception('meeting_ended');
      }

      if (!meeting.participants.contains(userId)) {
        await addParticipant(meetingId, userId);
      }

      final isHost = meeting.organizerId == userId;

      _log.i(
        'Utilisateur $userId rejoint '
        'réunion $meetingId (host=$isHost)',
      );

      return {
        'meetingId': meetingId,
        'isHost': isHost,
        'meetingTitle': meeting.title,
      };
    } catch (e, stackTrace) {
      _log.e('joinMeetingByCode error: $e', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // HOST CHECK
  // ---------------------------------------------------------------------------

  Future<bool> isUserHostOfMeeting(String meetingId, String userId) async {
    try {
      final meetingDoc =
          await _firestore.collection('meetings').doc(meetingId).get();

      if (!meetingDoc.exists || meetingDoc.data() == null) {
        return false;
      }

      final meeting = MeetingModel.fromDoc(meetingId, meetingDoc.data()!);

      return meeting.organizerId == userId;
    } catch (e, stackTrace) {
      _log.e('isUserHostOfMeeting error: $e', error: e, stackTrace: stackTrace);

      return false;
    }
  }
}
