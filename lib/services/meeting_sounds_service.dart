import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/logger.dart';

/// Sons de notification en réunion (référence Google Meet) : message de chat,
/// main levée, entrée/sortie de participant, sondage. Fonctionne sur web
/// (AudioContext) comme sur mobile — les lecteurs sont préchargés pour une
/// latence minimale et ne coupent jamais l'audio de la réunion (mixage).
enum MeetingSound {
  chatMessage('chat_message.wav'),

  handRaise('hand_raise.wav'),

  participantJoin('participant_join.wav'),

  participantLeave('participant_leave.wav'),

  pollStarted('poll_started.wav'),

  /// Alerte hôte « limite gratuite bientôt atteinte » (10 min puis 5 min).
  limitWarning('limit_warning.wav');

  const MeetingSound(this.asset);

  final String asset;
}

class MeetingSounds {
  MeetingSounds._();

  static final MeetingSounds instance = MeetingSounds._();

  final Map<MeetingSound, AudioPlayer> _players = {};

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    _initialized = true;

    for (final sound in MeetingSound.values) {
      try {
        final player = AudioPlayer();

        // Low latency : lecture instantanée à chaque événement.
        await player.setPlayerMode(PlayerMode.lowLatency);

        await player.setSource(AssetSource('sounds/${sound.asset}'));

        _players[sound] = player;
      } catch (e) {
        logger.w('Sound preload failed (${sound.asset})', error: e);
      }
    }
  }

  /// Joue un son sans interrompre la réunion ; les erreurs sont silencieuses
  /// (un son manquant ne doit jamais perturber un appel).
  ///
  /// RESPECTE le réglage « Ne pas déranger » (Paramètres) : pendant la
  /// fenêtre horaire configurée, aucun son n'est joué.
  void play(MeetingSound sound) {
    unawaited(_playIfAllowed(sound));
  }

  Future<void> _playIfAllowed(MeetingSound sound) async {
    if (await _isMutedByDnd()) return;

    final player = _players[sound];

    if (player == null) return;

    try {
      await player.stop();

      await player.resume();
    } catch (e) {
      logger.w('Sound play failed', error: e);
    }
  }

  /// Vrai si « Ne pas déranger » est actif ET si l'heure courante est dans
  /// la fenêtre configurée (gestion des fenêtres à cheval sur minuit).
  Future<bool> _isMutedByDnd() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (prefs.getBool('crux_dnd') != true) return false;

      final startH = prefs.getInt('crux_dnd_start_h') ?? 22;
      final startM = prefs.getInt('crux_dnd_start_m') ?? 0;
      final endH = prefs.getInt('crux_dnd_end_h') ?? 8;
      final endM = prefs.getInt('crux_dnd_end_m') ?? 0;

      final now = DateTime.now();
      final minutesNow = now.hour * 60 + now.minute;
      final start = startH * 60 + startM;
      final end = endH * 60 + endM;

      if (start == end) return false;

      return start < end
          ? (minutesNow >= start && minutesNow < end)
          : (minutesNow >= start || minutesNow < end);
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    for (final player in _players.values) {
      player.dispose();
    }

    _players.clear();

    _initialized = false;
  }
}
