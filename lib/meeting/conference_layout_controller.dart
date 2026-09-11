import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'entities/speaker_state.dart';
import 'entities/live_feed_config.dart';
import 'entities/participant_display.dart';
import 'layout/conference_layout_engine.dart';

class ConferenceLayoutController extends ChangeNotifier {
  SpeakerState _speakerState = const SpeakerState();
  LiveFeedConfig _feedConfig = const LiveFeedConfig();
  final SpeakerQueue _speakerQueue = SpeakerQueue();
  final Map<String, ParticipantDisplayState> _participantStates = {};
  Timer? _speakerDetectionTimer;
  Timer? _audioLevelTimer;

  static const double _dominantSpeakerThreshold = -40.0;
  static const Duration _speakerHoldDuration = Duration(milliseconds: 500);

  ConferenceLayoutController();

  SpeakerState get speakerState => _speakerState;
  LiveFeedConfig get feedConfig => _feedConfig;
  SpeakerQueue get speakerQueue => _speakerQueue;
  Map<String, ParticipantDisplayState> get participantStates =>
      Map.unmodifiable(_participantStates);

  List<ParticipantDisplayState> get activeParticipants =>
      _participantStates.values.where((p) => p.isVisible).toList();

  int get participantCount => _participantStates.length;

  void initialize() {
    _startSpeakerDetection();
    _startAudioLevelMonitoring();
  }

  @override
  void dispose() {
    _speakerDetectionTimer?.cancel();
    _audioLevelTimer?.cancel();
    super.dispose();
  }

  void updateParticipant(Participant participant) {
    // Une reconnexion (même identité Firebase, nouveau sid) ne doit pas
    // créer une tuile fantôme en plus : l'entrée la plus récente remplace
    // l'ancienne (2 écrans identiques quand on est seul).
    final identity = participant.identity;
    if (identity.isNotEmpty) {
      _participantStates.removeWhere(
        (_, s) =>
            s.participant.identity == identity &&
            s.participant.sid != participant.sid,
      );
    }

    final existingState = _participantStates[participant.sid];
    final newState = ParticipantDisplayState(
      participant: participant,
      mode: existingState?.mode ?? ParticipantDisplayMode.tile,
      isAudioActive: participant.isMuted == false,
      // isCameraEnabled() = publication caméra présente ET non mutée :
      // évite l'écran noir quand la caméra est coupée (on affiche l'avatar).
      isVideoEnabled: participant.isCameraEnabled(),
      // Détection réelle du partage d'écran (publication screenShareVideo).
      isScreenSharing: participant.isScreenShareEnabled(),
      hasHandRaised: _metadataHandRaised(participant),
      audioLevel: existingState?.audioLevel ?? 0.0,
      lastActiveTime: existingState?.lastActiveTime ?? DateTime.now(),
    );

    _participantStates[participant.sid] = newState;
    notifyListeners();
  }

  /// Lit `hand_raised` dans les métadonnées JSON du participant.
  ///
  /// IMPORTANT : ne pas faire `metadata.contains('hand_raised')` — la clé
  /// reste présente avec la valeur false quand on BAISSE la main, ce qui
  /// rendait le badge impossible à désactiver.
  static bool _metadataHandRaised(Participant participant) {
    final metadata = participant.metadata;
    if (metadata == null || metadata.isEmpty) return false;
    try {
      final decoded = jsonDecode(metadata);
      if (decoded is Map<String, dynamic>) {
        return decoded['hand_raised'] == true;
      }
    } catch (_) {}
    return false;
  }

  void removeParticipant(String participantId) {
    _participantStates.remove(participantId);
    _speakerQueue.removeWhere((p) => p.sid == participantId);

    if (_speakerState.currentSpeaker?.sid == participantId) {
      _switchToNextSpeaker();
    }

    notifyListeners();
  }

  void updateAudioLevel(String participantId, double level) {
    final state = _participantStates[participantId];
    if (state != null) {
      _participantStates[participantId] = state.copyWith(
        audioLevel: level,
        lastActiveTime: level > 0.1 ? DateTime.now() : state.lastActiveTime,
      );

      if (level > _dominantSpeakerThreshold && !_speakerState.isPinned) {
        _considerAsDominantSpeaker(participantId);
      }
    }
  }

  void setSpeakerMode(SpeakerMode mode) {
    _speakerState = _speakerState.copyWith(mode: mode);
    notifyListeners();
  }

  void pinParticipant(String participantId) {
    final participant = _participantStates[participantId]?.participant;
    if (participant != null) {
      _speakerState = _speakerState.copyWith(
        isPinned: true,
        pinnedParticipantId: participantId,
        currentSpeaker: participant,
        speakerTimestamp: DateTime.now(),
      );
      notifyListeners();
    }
  }

  void unpinParticipant() {
    _speakerState = _speakerState.copyWith(
      isPinned: false,
      pinnedParticipantId: null,
    );
    _switchToNextSpeaker();
    notifyListeners();
  }

  void setFeedConfig(LiveFeedConfig config) {
    _feedConfig = config;
    notifyListeners();
  }

  void _startSpeakerDetection() {
    _speakerDetectionTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      _detectDominantSpeaker,
    );
  }

  void _startAudioLevelMonitoring() {
    _audioLevelTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      _monitorAudioLevels,
    );
  }

  void _detectDominantSpeaker(_) {
    if (_speakerState.isPinned) return;

    Participant? loudestParticipant;
    double highestLevel = _dominantSpeakerThreshold;

    for (final state in _participantStates.values) {
      if (state.isAudioActive && state.audioLevel > highestLevel) {
        highestLevel = state.audioLevel;
        loudestParticipant = state.participant;
      }
    }

    if (loudestParticipant != null &&
        loudestParticipant.sid != _speakerState.currentSpeaker?.sid) {
      _switchSpeaker(loudestParticipant);
    }
  }

  void _monitorAudioLevels(_) {
    for (final state in _participantStates.values) {
      if (state.isAudioActive && state.audioLevel > 0.1) {
        final participant = state.participant;
        if (participant is LocalParticipant) {
          final audioPub = participant.getTrackPublicationBySource(
            TrackSource.microphone,
          );
          if (audioPub != null) {
            // Simulate audio level for local participant
            updateAudioLevel(state.participantId, 0.5);
          }
        }
      }
    }
  }

  void _considerAsDominantSpeaker(String participantId) {
    final participant = _participantStates[participantId]?.participant;
    if (participant != null) {
      _speakerQueue.add(participant);

      if (!_speakerState.isPinned) {
        _switchSpeakerWithDelay(participant);
      }
    }
  }

  void _switchSpeakerWithDelay(Participant participant) {
    Future.delayed(_speakerHoldDuration, () {
      if (_speakerState.currentSpeaker?.sid != participant.sid &&
          !_speakerState.isPinned) {
        _switchSpeaker(participant);
      }
    });
  }

  void _switchSpeaker(Participant newSpeaker) {
    _speakerState = _speakerState.copyWith(
      currentSpeaker: newSpeaker,
      speakerTimestamp: DateTime.now(),
    );

    _speakerQueue.add(newSpeaker);
    notifyListeners();
  }

  void _switchToNextSpeaker() {
    final nextSpeaker = _speakerQueue.nextSpeaker;
    if (nextSpeaker != null) {
      _speakerState = _speakerState.copyWith(
        currentSpeaker: nextSpeaker,
        speakerTimestamp: DateTime.now(),
      );
      notifyListeners();
    }
  }

  void handleHandRaise(String participantId, bool raised) {
    final state = _participantStates[participantId];
    if (state != null) {
      _participantStates[participantId] = state.copyWith(hasHandRaised: raised);

      if (raised && !_speakerState.isPinned) {
        final participant = state.participant;
        _speakerQueue.add(participant);
        _switchSpeakerWithDelay(participant);
      }

      notifyListeners();
    }
  }

  void updateParticipantMode(
    String participantId,
    ParticipantDisplayMode mode,
  ) {
    final state = _participantStates[participantId];
    if (state != null) {
      _participantStates[participantId] = state.copyWith(mode: mode);
      notifyListeners();
    }
  }

  SpeakerMode determineOptimalMode() {
    // Garde-fou : `values.first` sur une map vide lèverait un StateError.
    if (_participantStates.isEmpty) {
      return SpeakerMode.gallery;
    }

    final screenSharingParticipant = _participantStates.values.firstWhere(
      (p) => p.isScreenSharing,
      orElse: () => _participantStates.values.first,
    );

    final hasScreenShare = screenSharingParticipant.isScreenSharing;
    final participantCount = _participantStates.length;

    return ConferenceLayoutEngine.determineSpeakerMode(
      hasScreenShare: hasScreenShare,
      participantCount: participantCount,
      forceDual: _speakerState.isDualSpeaker,
    );
  }

  void autoAdjustLayout() {
    final optimalMode = determineOptimalMode();
    if (optimalMode != _speakerState.mode) {
      setSpeakerMode(optimalMode);
    }
  }
}
