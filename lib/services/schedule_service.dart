// lib/services/schedule_service.dart
//
// ==========================================================================
//  CORRECTIF CENTRAL DE LA PLANIFICATION DE RÉUNION
// ==========================================================================
// Bug d'origine :
//   * `MeetingService.scheduleProMeeting()` écrivait dans la collection
//     `scheduled_meetings` avec `scheduledStart` en String ISO locale ;
//   * l'écran d'accueil (`_UpcomingSliver`, `_ReunionsTab`) lisait la
//     collection `meetings` avec `where status == 'scheduled'` +
//     `orderBy('startTime')` ;
//   → une réunion planifiée n'apparaissait JAMAIS sur l'accueil.
//   * l'organisateur n'était pas toujours ajouté à `participants`, donc même
//     avec la bonne collection le `arrayContains` échouait ;
//   * aucun rappel local n'était programmé ;
//   * aucune validation : on pouvait planifier dans le passé, ou double-taper
//     et créer deux réunions.
//
// Correctif : ce service unique est la SEULE porte d'entrée de la
// planification. Il écrit de façon atomique (WriteBatch) :
//   1. `meetings/{id}`            → document canonique lu par l'accueil,
//                                    dates en Timestamp, participants incluant
//                                    l'organisateur, status = 'scheduled' ;
//   2. `scheduled_meetings/{id}`  → miroir enrichi (options Pro, invités,
//                                    récurrence) conservé en ISO UTC pour
//                                    rester compatible avec
//                                    ScheduledMeetingModel.fromJson.
// Puis il programme les rappels locaux.
// ==========================================================================

import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/meeting_model.dart';
import '../models/user_model.dart';
import '../utils/date_flex.dart';
import '../utils/logger.dart';
import '../utils/meeting_notification_manager.dart';
import 'payment_service.dart';

/// Liens de partage. (Évite de dupliquer des URLs en dur dans les écrans.)
class CruxLinks {
  static const String webBase = 'https://crux-3c6be.web.app';
  static String meeting(String code) => '$webBase/join/$code';
}

/// Erreur métier de planification, affichable directement à l'utilisateur.
class ScheduleException implements Exception {
  final String message;
  final String? code;
  const ScheduleException(this.message, {this.code});
  @override
  String toString() => 'ScheduleException($code): $message';
}

/// Résultat d'une planification réussie.
class ScheduleResult {
  final MeetingModel meeting;
  final String meetingCode;
  final String shareLink;
  final int remindersScheduled;

  const ScheduleResult({
    required this.meeting,
    required this.meetingCode,
    required this.shareLink,
    required this.remindersScheduled,
  });
}

class ScheduleService {
  ScheduleService({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _db = firestore ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  /// Verrou anti double-soumission (double tap sur « Planifier »).
  static bool _inFlight = false;
  static bool get isBusy => _inFlight;

  static const Duration minLead = Duration(minutes: 2);
  static const Duration minDuration = Duration(minutes: 5);
  static const Duration maxDuration = Duration(hours: 12);
  static const Duration maxHorizon = Duration(days: 365);

  CollectionReference<Map<String, dynamic>> get _meetings =>
      _db.collection('meetings');
  CollectionReference<Map<String, dynamic>> get _scheduled =>
      _db.collection('scheduled_meetings');

  // ------------------------------------------------------------------ create

  /// Planifie une réunion. Lève [ScheduleException] en cas d'entrée invalide.
  Future<ScheduleResult> scheduleMeeting({
    required String title,
    required DateTime startTime,
    required Duration duration,
    String description = '',
    List<String> invitedEmails = const [],
    List<String> participantIds = const [],
    String? passcode,
    bool isLargeConference = false,
    bool waitingRoomEnabled = false,
    bool recordAutomatically = false,
    bool notifyAtOneHour = true,
    bool notifyAtFifteenMin = true,
    bool notifyAtFiveMin = true,
    bool notifyAtStart = true,
    String recurrence = 'none',
    Map<String, dynamic> extraSettings = const {},
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const ScheduleException(
        'Vous devez être connecté pour planifier une réunion.',
        code: 'unauthenticated',
      );
    }

    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw const ScheduleException(
        'Donnez un titre à votre réunion.',
        code: 'empty-title',
      );
    }
    if (cleanTitle.length > 120) {
      throw const ScheduleException(
        'Le titre ne doit pas dépasser 120 caractères.',
        code: 'title-too-long',
      );
    }

    final now = DateTime.now();
    if (startTime.isBefore(now.add(minLead))) {
      throw const ScheduleException(
        'Choisissez un horaire au moins 2 minutes dans le futur.',
        code: 'start-in-past',
      );
    }
    if (startTime.isAfter(now.add(maxHorizon))) {
      throw const ScheduleException(
        'Vous ne pouvez pas planifier plus d\'un an à l\'avance.',
        code: 'start-too-far',
      );
    }
    if (duration < minDuration || duration > maxDuration) {
      throw const ScheduleException(
        'La durée doit être comprise entre 5 minutes et 12 heures.',
        code: 'bad-duration',
      );
    }
    if (passcode != null && passcode.isNotEmpty) {
      if (!RegExp(r'^\d{4,6}$').hasMatch(passcode)) {
        throw const ScheduleException(
          'Le code d\'accès doit contenir 4 à 6 chiffres.',
          code: 'bad-passcode',
        );
      }
    }

    // Quota mensuel : une réunion planifiée compte comme une réunion
    // immédiate (free 3, pro 10, max illimité).
    final payment = PaymentService();
    final userDoc = await _db.collection('users').doc(user.uid).get();
    final userData = userDoc.data();

    if (userData != null) {
      final userModel = UserModel.fromJson(userData);

      if (!payment.isSubscriptionActive(userModel) &&
          userModel.plan != SubscriptionPlan.free) {
        throw const ScheduleException(
          'Votre abonnement a expiré. Renouvelez-le pour planifier '
          'une réunion.',
          code: 'subscription-expired',
        );
      }

      if (payment.hasExceededLimit(userModel)) {
        throw const ScheduleException(
          'Vous avez atteint votre quota de réunions ce mois-ci. '
          'Passez au forfait Pro ou Max pour continuer.',
          code: 'meeting-limit-exceeded',
        );
      }

      // Nouveau mois : remise à zéro du compteur.
      await payment.resetMonthlyCounterIfNeeded(user.uid);
    }

    if (_inFlight) {
      throw const ScheduleException(
        'Planification déjà en cours…',
        code: 'in-flight',
      );
    }
    _inFlight = true;

    try {
      final endTime = startTime.add(duration);
      final docRef = _meetings.doc();
      final meetingId = docRef.id;
      final code = _generateCode();

      // L'organisateur DOIT figurer dans participants : l'accueil filtre avec
      // `arrayContains: currentUser.uid`.
      final participants =
          <String>{
            user.uid,
            ...participantIds.where((e) => e.trim().isNotEmpty),
          }.toList();

      final meeting = MeetingModel(
        id: meetingId,
        title: cleanTitle,
        description: description.trim(),
        organizer:
            user.displayName?.trim().isNotEmpty == true
                ? user.displayName!.trim()
                : (user.email ?? 'Organisateur'),
        organizerId: user.uid,
        startTime: startTime,
        endTime: endTime,
        participants: participants,
        channelName: code,
        status: MeetingStatus.scheduled,
        createdAt: now,
        isLargeConference: isLargeConference,
        passcode: (passcode?.isEmpty ?? true) ? null : passcode,
      );

      final shareLink = CruxLinks.meeting(code);

      final batch = _db.batch();

      // 1) Document canonique lu par l'accueil.
      batch.set(docRef, {
        ...meeting.toJson(),
        'meetingCode': code,
        'meetingLink': shareLink,
        'source': 'schedule',
        'waitingRoomEnabled': waitingRoomEnabled,
        'recordAutomatically': recordAutomatically,
        'invitedEmails': invitedEmails,
        'recurrence': recurrence,
        'coHosts': const <String>[],
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 2) Miroir enrichi (compatible ScheduledMeetingModel : ISO UTC).
      batch.set(_scheduled.doc(meetingId), {
        'id': meetingId,
        'title': cleanTitle,
        'description': description.trim(),
        'organizerId': user.uid,
        'organizerName': meeting.organizer,
        'organizerEmail': user.email ?? '',
        'createdAt': flexIsoUtc(now),
        'scheduledStart': flexIsoUtc(startTime),
        'scheduledEnd': flexIsoUtc(endTime),
        'timezone': now.timeZoneName,
        'recurrence': recurrence,
        'recurrenceConfig': const <String, dynamic>{},
        'status': 'scheduled',
        'passcode': meeting.passcode,
        'waitingRoomEnabled': waitingRoomEnabled,
        'recordAutomatically': recordAutomatically,
        'participants': participants,
        'invitedEmails': invitedEmails,
        'coHosts': const <String>[],
        'notifyAtOneHour': notifyAtOneHour,
        'notifyAtFifteenMin': notifyAtFifteenMin,
        'notifyAtFiveMin': notifyAtFiveMin,
        'notifyAtStart': notifyAtStart,
        'meetingLink': shareLink,
        'meetingCode': code,
        'isLargeConference': isLargeConference,
        'settings': extraSettings,
        // Dupliqué en Timestamp pour permettre des requêtes serveur fiables
        // sans casser fromJson (qui lit `scheduledStart`).
        'startTimestamp': flexStamp(startTime),
      });

      await batch.commit();

      final reminders = await MeetingNotificationManager.instance
          .scheduleForMeeting(
            meetingId: meetingId,
            title: cleanTitle,
            startTime: startTime,
            oneHour: notifyAtOneHour,
            fifteenMin: notifyAtFifteenMin,
            fiveMin: notifyAtFiveMin,
            atStart: notifyAtStart,
          );

      // La réunion planifiée consomme le quota mensuel (même règle que les
      // réunions immédiates) ; l'échec d'incrément ne bloque pas la création.
      try {
        await payment.incrementMeetingCount(userId: user.uid);
      } catch (e) {
        logger.w('incrementMeetingCount (scheduled) failed: $e');
      }

      logger.i('📅 Réunion planifiée $meetingId à $startTime ($code)');

      return ScheduleResult(
        meeting: meeting,
        meetingCode: code,
        shareLink: shareLink,
        remindersScheduled: reminders,
      );
    } on FirebaseException catch (e) {
      logger.e('scheduleMeeting Firebase → ${e.code} ${e.message}');
      throw ScheduleException(
        e.code == 'permission-denied'
            ? 'Permissions insuffisantes pour planifier cette réunion.'
            : 'Échec de la planification (${e.code}).',
        code: e.code,
      );
    } catch (e, st) {
      logger.e('scheduleMeeting', error: e, stackTrace: st);
      throw const ScheduleException(
        'Une erreur est survenue. Vérifiez votre connexion et réessayez.',
        code: 'unknown',
      );
    } finally {
      _inFlight = false;
    }
  }

  // ------------------------------------------------------------------ update

  /// Déplace une réunion planifiée et reprogramme les rappels.
  Future<void> reschedule({
    required String meetingId,
    required DateTime startTime,
    required Duration duration,
    String? title,
  }) async {
    final now = DateTime.now();
    if (startTime.isBefore(now.add(minLead))) {
      throw const ScheduleException(
        'Le nouvel horaire doit être dans le futur.',
        code: 'start-in-past',
      );
    }
    final endTime = startTime.add(duration);
    try {
      final batch = _db.batch();
      batch.update(_meetings.doc(meetingId), {
        'startTime': flexStamp(startTime),
        'endTime': flexStamp(endTime),
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        'status': MeetingStatus.scheduled.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      batch.set(_scheduled.doc(meetingId), {
        'scheduledStart': flexIsoUtc(startTime),
        'scheduledEnd': flexIsoUtc(endTime),
        'startTimestamp': flexStamp(startTime),
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      }, SetOptions(merge: true));
      await batch.commit();

      final snap = await _meetings.doc(meetingId).get();
      final data = snap.data() ?? const <String, dynamic>{};
      await MeetingNotificationManager.instance.rescheduleForMeeting(
        meetingId: meetingId,
        title: (title ?? data['title'] ?? 'Réunion CRUX') as String,
        startTime: startTime,
      );
    } on FirebaseException catch (e) {
      throw ScheduleException(
        'Modification impossible (${e.code}).',
        code: e.code,
      );
    }
  }

  /// Annule une réunion planifiée (les deux documents + les rappels).
  Future<void> cancelScheduled(String meetingId, {String? reason}) async {
    try {
      final batch = _db.batch();
      batch.set(_meetings.doc(meetingId), {
        'status': MeetingStatus.ended.name,
        'cancelledAt': FieldValue.serverTimestamp(),
        if (reason != null) 'cancellationReason': reason,
      }, SetOptions(merge: true));
      batch.set(_scheduled.doc(meetingId), {
        'status': 'cancelled',
        if (reason != null) 'cancellationReason': reason,
      }, SetOptions(merge: true));
      await batch.commit();
      await MeetingNotificationManager.instance.cancelForMeeting(meetingId);
    } on FirebaseException catch (e) {
      throw ScheduleException(
        'Annulation impossible (${e.code}).',
        code: e.code,
      );
    }
  }

  // ------------------------------------------------------------------- reads

  /// Réunions à venir de l'utilisateur (même requête que l'accueil).
  /// Index requis : meetings(participants ASC, status ASC, startTime ASC).
  Stream<List<MeetingModel>> streamUpcoming({String? userId, int limit = 20}) {
    final uid = userId ?? _auth.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _meetings
        .where('participants', arrayContains: uid)
        .where('status', isEqualTo: MeetingStatus.scheduled.name)
        .orderBy('startTime')
        .limit(limit)
        .snapshots()
        .map(
          (snap) =>
              snap.docs
                  .map((d) => MeetingModel.fromDoc(d.id, d.data()))
                  .where(
                    (m) => m.endTime.isAfter(
                      DateTime.now().subtract(const Duration(hours: 2)),
                    ),
                  )
                  .toList(),
        );
  }

  /// Reprogramme tous les rappels au démarrage de l'app (les notifications
  /// locales sont perdues après un redémarrage de l'appareil sur iOS/Android).
  Future<void> resyncReminders({String? userId}) async {
    final uid = userId ?? _auth.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap =
          await _meetings
              .where('participants', arrayContains: uid)
              .where('status', isEqualTo: MeetingStatus.scheduled.name)
              .orderBy('startTime')
              .limit(30)
              .get();
      for (final doc in snap.docs) {
        final m = MeetingModel.fromDoc(doc.id, doc.data());
        if (m.startTime.isAfter(DateTime.now())) {
          await MeetingNotificationManager.instance.scheduleForMeeting(
            meetingId: m.id,
            title: m.title,
            startTime: m.startTime,
          );
        }
      }
      logger.i('🔁 Rappels resynchronisés (${snap.docs.length})');
    } catch (e) {
      logger.w('resyncReminders → $e');
    }
  }

  // ------------------------------------------------------------------ helper

  /// Alphabet SANS caractères ambigus, en MAJUSCULES : tous les codes de
  /// réunion CRUX sont normalisés en majuscules (recherche par code, écran
  /// « Rejoindre », deep links) — un code minuscule était introuvable.
  static const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// Code type `ABC-DEFG-HIJ` (sans caractères ambigus).
  String _generateCode() {
    final rnd = Random.secure();
    String block(int n) =>
        List.generate(
          n,
          (_) => _alphabet[rnd.nextInt(_alphabet.length)],
        ).join();
    return '${block(3)}-${block(4)}-${block(3)}';
  }
}
