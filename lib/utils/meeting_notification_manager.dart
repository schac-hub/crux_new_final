import 'io_compat.dart' show Platform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

import 'logger.dart';

/// Décalages de rappel supportés, dans l'ordre d'affichage.
enum MeetingReminder { oneHour, fifteenMin, fiveMin, atStart }

extension MeetingReminderX on MeetingReminder {
  Duration get lead => switch (this) {
    MeetingReminder.oneHour => const Duration(hours: 1),
    MeetingReminder.fifteenMin => const Duration(minutes: 15),
    MeetingReminder.fiveMin => const Duration(minutes: 5),
    MeetingReminder.atStart => Duration.zero,
  };

  String get label => switch (this) {
    MeetingReminder.oneHour => 'dans 1 heure',
    MeetingReminder.fifteenMin => 'dans 15 minutes',
    MeetingReminder.fiveMin => 'dans 5 minutes',
    MeetingReminder.atStart => 'commence maintenant',
  };

  /// Offset ajouté à l'ID de base (4 slots réservés par réunion).
  int get slot => index;
}

class MeetingNotificationManager {
  MeetingNotificationManager._();
  static final MeetingNotificationManager instance =
      MeetingNotificationManager._();
  factory MeetingNotificationManager() => instance;

  final FlutterLocalNotificationsPlugin _ln = FlutterLocalNotificationsPlugin();

  static const String channelId = 'crux_meeting_reminders';
  static const String channelName = 'Rappels de réunion';
  static const String channelDescription =
      'Notifications avant le début de vos réunions CRUX';

  bool _ready = false;
  bool _exactAlarmAllowed = true;

  /// À appeler une fois au démarrage, **avant** toute planification.
  /// (dans `main()`, juste après `NotificationService().initialize()`)
  Future<void> initialize() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      try {
        final localName = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(localName));
      } catch (e) {
        // Fuseau système illisible : on reste sur UTC plutôt que de crasher.
        logger.w('Fuseau local introuvable ($e) → UTC');
        tz.setLocalLocation(tz.UTC);
      }

      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosInit = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _ln.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
      );

      if (Platform.isAndroid) {
        final android =
            _ln
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >();
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: channelDescription,
            importance: Importance.high,
          ),
        );
        await android?.requestNotificationsPermission();
        _exactAlarmAllowed =
            await android?.canScheduleExactNotifications() ?? true;
        if (!_exactAlarmAllowed) {
          logger.w(
            'Alarmes exactes refusées → rappels programmés en mode inexact',
          );
        }
      }

      _ready = true;
      logger.i('✅ MeetingNotificationManager prêt (${tz.local.name})');
    } catch (e, st) {
      logger.e(
        'MeetingNotificationManager.initialize',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// ID stable dérivé du meetingId : permet d'annuler les rappels d'une
  /// réunion sans stocker les IDs générés.
  int _baseId(String meetingId) {
    final hash = meetingId.hashCode.abs() % 100000;
    return 200000 + hash * 4;
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.event,
    ),
    iOS: DarwinNotificationDetails(),
  );

  /// Programme les rappels demandés pour une réunion.
  ///
  /// Retourne le nombre de rappels effectivement programmés (les échéances
  /// déjà passées sont ignorées, ce qui est le cas normal quand on planifie
  /// une réunion dans 10 minutes).
  Future<int> scheduleForMeeting({
    required String meetingId,
    required String title,
    required DateTime startTime,
    bool oneHour = true,
    bool fifteenMin = true,
    bool fiveMin = true,
    bool atStart = true,
  }) async {
    await initialize();
    if (!_ready) return 0;

    await cancelForMeeting(meetingId);

    final wanted = <MeetingReminder>[
      if (oneHour) MeetingReminder.oneHour,
      if (fifteenMin) MeetingReminder.fifteenMin,
      if (fiveMin) MeetingReminder.fiveMin,
      if (atStart) MeetingReminder.atStart,
    ];

    final base = _baseId(meetingId);
    final now = DateTime.now();
    var scheduled = 0;

    for (final reminder in wanted) {
      final when = startTime.subtract(reminder.lead);
      if (!when.isAfter(now.add(const Duration(seconds: 5)))) continue;

      try {
        await _ln.zonedSchedule(
          base + reminder.slot,
          title.isEmpty ? 'Réunion CRUX' : title,
          'Votre réunion ${reminder.label}.',
          tz.TZDateTime.from(when, tz.local),
          _details,
          androidScheduleMode:
              _exactAlarmAllowed
                  ? AndroidScheduleMode.exactAllowWhileIdle
                  : AndroidScheduleMode.inexactAllowWhileIdle,
          payload: 'meeting:$meetingId',
          matchDateTimeComponents: null,
        );
        scheduled++;
      } catch (e) {
        logger.e('zonedSchedule($meetingId/${reminder.name}) → $e');
      }
    }

    logger.i('🔔 $scheduled rappel(s) programmé(s) pour $meetingId');
    return scheduled;
  }

  /// Annule les 4 slots de rappel d'une réunion (édition ou annulation).
  Future<void> cancelForMeeting(String meetingId) async {
    await initialize();
    final base = _baseId(meetingId);
    for (var i = 0; i < 4; i++) {
      try {
        await _ln.cancel(base + i);
      } catch (_) {
        // Un ID inexistant n'est pas une erreur.
      }
    }
  }

  /// Reprogramme après modification de l'horaire.
  Future<int> rescheduleForMeeting({
    required String meetingId,
    required String title,
    required DateTime startTime,
    bool oneHour = true,
    bool fifteenMin = true,
    bool fiveMin = true,
    bool atStart = true,
  }) => scheduleForMeeting(
    meetingId: meetingId,
    title: title,
    startTime: startTime,
    oneHour: oneHour,
    fifteenMin: fifteenMin,
    fiveMin: fiveMin,
    atStart: atStart,
  );

  /// Utile pour un écran de debug.
  Future<List<PendingNotificationRequest>> pending() async {
    await initialize();
    return _ln.pendingNotificationRequests();
  }
}
