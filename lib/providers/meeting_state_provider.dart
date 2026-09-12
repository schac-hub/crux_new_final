import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import '../meeting/entities/speaker_state.dart';
import '../meeting/entities/live_feed_config.dart';
import '../meeting/entities/participant_display.dart';
import '../meeting/conference_layout_controller.dart';
import '../models/user_model.dart';

// Note: MeetingStateProvider is in providers/ folder, so ../meeting/ is correct

class MeetingStateProvider extends ChangeNotifier {
  final ConferenceLayoutController _layoutController;

  MeetingStateProvider() : _layoutController = ConferenceLayoutController() {
    _layoutController.initialize();
  }

  // Local media state
  bool _isMicEnabled = true;
  bool _isCameraEnabled = true;
  bool _isScreenSharing = false;
  bool _isHandRaised = false;

  // Network stats
  double _fps = 60.0;
  int _latency = 0;
  double _bandwidth = 0.0;
  double _jitter = 0.0;

  // Meeting info
  String? _meetingId;
  String? _meetingName;
  Room? _room;
  DateTime _meetingStartTime = DateTime.now();

  // Time expiry tracking
  Timer? _durationTimer;
  bool _hostNotified10Min = false;
  bool _meetingEnded = false;

  // Getters
  ConferenceLayoutController get layoutController => _layoutController;
  SpeakerState get speakerState => _layoutController.speakerState;
  LiveFeedConfig get feedConfig => _layoutController.feedConfig;
  SpeakerQueue get speakerQueue => _layoutController.speakerQueue;
  Map<String, ParticipantDisplayState> get participantStates =>
      _layoutController.participantStates;

  bool get isMicEnabled => _isMicEnabled;
  bool get isCameraEnabled => _isCameraEnabled;
  bool get isScreenSharing => _isScreenSharing;
  bool get isHandRaised => _isHandRaised;

  /// Le temps gratuit est épuisé : l'UI doit afficher la fin de réunion.
  bool get meetingEnded => _meetingEnded;

  /// L'hôte a été prévenu qu'il ne reste que 10 minutes.
  bool get hostNotified10Min => _hostNotified10Min;

  double get fps => _fps;
  int get latency => _latency;
  double get bandwidth => _bandwidth;
  double get jitter => _jitter;

  String? get meetingId => _meetingId;
  String? get meetingName => _meetingName;
  Room? get room => _room;

  int get participantCount => _layoutController.participantCount;
  List<ParticipantDisplayState> get activeParticipants =>
      _layoutController.activeParticipants;

  // Initialize meeting
  void initializeMeeting({
    required String meetingId,
    required String meetingName,
    Room? room,
    UserModel? userModel,
  }) {
    _meetingId = meetingId;
    _meetingName = meetingName;
    _room = room;
    _meetingStartTime = DateTime.now();
    _hostNotified10Min = false;
    _meetingEnded = false;

    // Timer de durée uniquement quand un profil abonnement est fourni ;
    // sinon l'écran de réunion gère lui-même la limite gratuite (paywall).
    if (userModel != null) {
      _startDurationTimer(userModel);
    }

    notifyListeners();
  }

  /// Timer de durée : sur le forfait gratuit, avertit l'hôte 10 minutes
  /// avant l'échéance puis clôt réellement la réunion à 1 h 45 min.
  void _startDurationTimer(UserModel userModel) {
    _durationTimer?.cancel();

    // Plan effectif : tient compte de l'expiration de l'abonnement.
    final plan = userModel.effectivePlan;

    // Pro/Max : pas de limite de durée, aucun timer nécessaire.
    if (plan != SubscriptionPlan.free) {
      return;
    }

    _durationTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (_meetingEnded || _room == null) {
        timer.cancel();
        return;
      }

      final elapsed = DateTime.now().difference(_meetingStartTime);
      final warningDuration =
          freeTierDuration - freeTierWarningDuration; // 1h35

      // 10 minutes restantes : on marque l'état, l'UI (écran de réunion)
      // joue le son d'alerte et affiche l'avertissement à l'hôte.
      if (elapsed >= warningDuration &&
          elapsed < freeTierDuration &&
          !_hostNotified10Min) {
        _hostNotified10Min = true;
        notifyListeners();
      }

      // Temps gratuit épuisé : clôture réelle de la réunion.
      if (elapsed >= freeTierDuration && !_meetingEnded) {
        _meetingEnded = true;
        timer.cancel();
        _ejectAllParticipants();
      }
    });
  }

  /// Éjection réelle de tout le monde : on passe la réunion en « ended »
  /// dans Firestore. L'écran de réunion écoute ce statut en temps réel et
  /// déconnecte l'hôte comme les participants (message de fin affiché).
  Future<void> _ejectAllParticipants() async {
    _meetingEnded = true;
    _durationTimer?.cancel();
    notifyListeners();

    final meetingId = _meetingId;

    if (meetingId == null || meetingId.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('meetings')
          .doc(meetingId)
          .set({
        'status': 'ended',
        'endedReason': 'free_tier_expired',
        'endedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      // L'échec Firestore ne doit pas laisser l'hôte bloqué : l'état local
      // reste « ended », l'écran quitte aussi sur ce signal.
      debugPrint('Failed to mark meeting ended: $e');
    }
  }

  // Media controls
  void toggleMic() {
    _isMicEnabled = !_isMicEnabled;
    notifyListeners();
  }

  void setMicEnabled(bool enabled) {
    _isMicEnabled = enabled;
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraEnabled = !_isCameraEnabled;
    notifyListeners();
  }

  void setCameraEnabled(bool enabled) {
    _isCameraEnabled = enabled;
    notifyListeners();
  }

  void toggleScreenShare() {
    _isScreenSharing = !_isScreenSharing;
    if (_isScreenSharing) {
      _layoutController.setSpeakerMode(SpeakerMode.screenshare);
    } else {
      _layoutController.autoAdjustLayout();
    }
    notifyListeners();
  }

  void setScreenSharing(bool sharing) {
    if (_isScreenSharing == sharing) return;
    _isScreenSharing = sharing;
    if (_isScreenSharing) {
      _layoutController.setSpeakerMode(SpeakerMode.screenshare);
    } else {
      _layoutController.autoAdjustLayout();
    }
    notifyListeners();
  }

  void toggleHandRaise() {
    _isHandRaised = !_isHandRaised;
    if (_room != null) {
      final localParticipant = _room!.localParticipant;
      if (localParticipant != null) {
        _layoutController.handleHandRaise(localParticipant.sid, _isHandRaised);
      }
    }
    notifyListeners();
  }

  // Layout controls
  void setSpeakerMode(SpeakerMode mode) {
    _layoutController.setSpeakerMode(mode);
    notifyListeners();
  }

  void pinParticipant(String participantId) {
    _layoutController.pinParticipant(participantId);
    notifyListeners();
  }

  void unpinParticipant() {
    _layoutController.unpinParticipant();
    notifyListeners();
  }

  void setFeedConfig(LiveFeedConfig config) {
    _layoutController.setFeedConfig(config);
    notifyListeners();
  }

  // Participant management
  void updateParticipant(Participant participant) {
    _layoutController.updateParticipant(participant);
  }

  void removeParticipant(String participantId) {
    _layoutController.removeParticipant(participantId);
  }

  void updateAudioLevel(String participantId, double level) {
    _layoutController.updateAudioLevel(participantId, level);
  }

  void updateParticipantMode(
    String participantId,
    ParticipantDisplayMode mode,
  ) {
    _layoutController.updateParticipantMode(participantId, mode);
  }

  // Network stats
  void updateNetworkStats({
    double? fps,
    int? latency,
    double? bandwidth,
    double? jitter,
  }) {
    if (fps != null) _fps = fps;
    if (latency != null) _latency = latency;
    if (bandwidth != null) _bandwidth = bandwidth;
    if (jitter != null) _jitter = jitter;
    notifyListeners();
  }

  // Auto layout adjustment
  void autoAdjustLayout() {
    _layoutController.autoAdjustLayout();
    notifyListeners();
  }

  // Cleanup
  @override
  void dispose() {
    _durationTimer?.cancel();
    _layoutController.dispose();
    super.dispose();
  }
}