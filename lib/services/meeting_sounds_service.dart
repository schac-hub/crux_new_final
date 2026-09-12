import 'package:audioplayers/audioplayers.dart';

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
  void play(MeetingSound sound) {
    final player = _players[sound];

    if (player == null) return;

    player
        .stop()
        .then((_) => player.resume())
        .catchError((Object e) => logger.w('Sound play failed', error: e));
  }

  void dispose() {
    for (final player in _players.values) {
      player.dispose();
    }

    _players.clear();

    _initialized = false;
  }
}
