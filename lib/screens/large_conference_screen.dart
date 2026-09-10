import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:livekit_client/livekit_client.dart' hide logger;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../models/meeting_report_model.dart';
import '../providers/meeting_state_provider.dart';
import '../services/file_sharing_service.dart';
import '../services/input_validator.dart';
import '../services/keyboard_shortcuts_service.dart';
import '../services/livekit_service.dart';
import '../services/meeting_service.dart';
import '../services/noise_reduction_service.dart';
import '../services/note_service.dart';
import '../services/polls_service.dart';
import '../services/pro_service.dart';
import '../services/recording_service.dart';
import '../theme/colors.dart';
import '../utils/logger.dart';
import '../meeting/crux_conference_view.dart';
import '../meeting/entities/speaker_state.dart';
import '../meeting/reaction_bus.dart';
import '../screens/meeting_report_screen.dart';
import '../screens/pro_screen.dart';
import '../widgets/network_quality_indicator.dart';
import '../widgets/reaction_emojis.dart';

class LargeConferenceScreen extends StatefulWidget {
  final String meetingId;
  final String? meetingCode;
  final String meetingName;
  final String userId;
  final String userName;
  final String? userEmail;
  final bool isHost;

  const LargeConferenceScreen({
    super.key,
    required this.meetingId,
    this.meetingCode,
    required this.meetingName,
    required this.userId,
    required this.userName,
    this.userEmail,
    this.isHost = false,
  });

  @override
  State<LargeConferenceScreen> createState() => _LargeConferenceScreenState();
}

class _LargeConferenceScreenState extends State<LargeConferenceScreen>
    with WidgetsBindingObserver {
  // ===========================================================================
  // LARGE WEBINAR CONFIGURATION
  // ===========================================================================

  /// Capacité cible de ce mode webinaire.
  ///
  /// Cette valeur est uniquement une indication UI.
  /// Elle ne configure pas la capacité réelle de LiveKit.
  static const int _targetParticipants = 10000;

  // ===========================================================================
  // SERVICES
  // ===========================================================================

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final FlutterTts _tts = FlutterTts();

  final stt.SpeechToText _speech = stt.SpeechToText();

  // ===========================================================================
  // LIVEKIT
  // ===========================================================================

  Room? _room;

  EventsListener<RoomEvent>? _roomListener;

  bool _isConnecting = false;

  bool _isReconnecting = false;

  int _reconnectAttempts = 0;

  // ===========================================================================
  // PARTICIPANTS
  // ===========================================================================

  List<RemoteParticipant> _remoteParticipants = <RemoteParticipant>[];

  String? _organizerId;

  final Set<String> _raisedHands = <String>{};

  // ===========================================================================
  // LOCAL MEDIA
  // ===========================================================================

  bool _micOn = true;

  bool _camOn = true;

  bool _screenSharing = false;

  // ===========================================================================
  // UI
  // ===========================================================================

  bool _loading = true;

  String? _error;

  bool _showChat = false;

  bool _showParticipants = false;

  bool _showNotes = false;

  bool _voiceAssistant = false;

  bool _liveCaptions = false;

  bool _handRaised = false;

  // ===========================================================================
  // MEDIA / QUALITÉ (référence Zoom/Meet)
  // ===========================================================================

  /// Caméra active (avant / arrière), commutable en cours de réunion.
  CameraPosition _cameraPosition = CameraPosition.front;

  /// Qualité vidéo persistée (clé `crux_video_quality`, partagée avec
  /// SettingsScreen) appliquée aux options de capture LiveKit.
  String _videoQuality = 'HD (720p)';

  /// Affichage de l'overlay de statistiques réseau.
  bool _showNetworkStats = true;

  // ===========================================================================
  // MODÉRATION
  // ===========================================================================

  bool _meetingLocked = false;

  /// Cohôtes nommés par l'hôte (sync live depuis le document réunion).
  Set<String> _coHosts = <String>{};

  bool get _isModerator =>
      widget.isHost ||
      widget.userId == _organizerId ||
      _coHosts.contains(widget.userId);

  /// Vérifie côté réception qu'un expéditeur de commande de modération
  /// (mute, kick…) est bien hôte ou co-hôte selon les données Firestore :
  /// un participant ne peut pas s'auto-promouvoir via le data channel.
  bool _isModeratorIdentity(String? identity) {
    if (identity == null || identity.isEmpty) return false;

    return identity == _organizerId || _coHosts.contains(identity);
  }

  // ===========================================================================
  // CHAT NON LU
  // ===========================================================================

  int _unreadChat = 0;

  int _lastSeenChatCount = 0;

  bool _chatInitialSync = false;

  // ===========================================================================
  // MESURE DE LATENCE (ping/pong LiveKit data channel)
  // ===========================================================================

  Timer? _latencyTimer;

  final Map<int, int> _pendingPings = <int, int>{};

  int _lastRttMs = 0;

  // ===========================================================================
  // FONCTIONNALITÉS ZOOM (sondages, Q&A, enregistrement, fichiers, raccourcis)
  // ===========================================================================

  final KeyboardShortcutsService _shortcuts = KeyboardShortcutsService.instance;

  bool _showPolls = false;

  bool _isMeetingRecording = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _recordingSub;

  late final TextEditingController _qaCtrl;

  // ===========================================================================
  // CAPTIONS
  // ===========================================================================

  String _currentTranscription = '';

  // ===========================================================================
  // TIMER
  // ===========================================================================

  Timer? _callTimer;

  int _secondsElapsed = 0;

  bool _isPro = false;

  bool _paywallShown = false;

  // ===========================================================================
  // FIRESTORE
  // ===========================================================================

  StreamSubscription<QuerySnapshot>? _presenceSubscription;

  StreamSubscription<QuerySnapshot>? _chatSubscription;

  // ===========================================================================
  // CONTROLLERS
  // ===========================================================================

  late final TextEditingController _chatController;

  late final TextEditingController _noteController;

  final List<_ChatMessage> _chatMessages = <_ChatMessage>[];

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();

    _chatController = TextEditingController();

    _noteController = TextEditingController();

    _qaCtrl = TextEditingController();

    WidgetsBinding.instance.addObserver(this);

    // Raccourcis clavier type Zoom (web/desktop ; inoffensif sur mobile).
    _shortcuts.initialize(
      onToggleMic: _toggleMic,
      onToggleCamera: _toggleCamera,
      onToggleScreenShare: _toggleScreenShare,
      onToggleHandRaise: _toggleRaiseHand,
      onLeaveMeeting: _confirmLeave,
      onToggleChat: _toggleChatPanel,
      onToggleParticipants: _toggleParticipantsPanel,
      onToggleReactions: _showReactionsPicker,
      onMuteAll: _muteAllOthers,
    );

    // Sondages & Q&A temps réel (PollsService branché sur cette réunion).
    unawaited(PollsService.instance.initialize(meetingId: widget.meetingId));

    // Préférences audio (réduction de bruit, AEC, AGC) lues à la connexion.
    unawaited(NoiseReductionService.instance.initialize());

    // Initialize meeting state provider
    final meetingProvider = context.read<MeetingStateProvider>();
    meetingProvider.initializeMeeting(
      meetingId: widget.meetingId,
      meetingName: widget.meetingName,
    );

    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _callTimer?.cancel();

    _latencyTimer?.cancel();

    _recordingSub?.cancel();

    _presenceSubscription?.cancel();

    _chatSubscription?.cancel();

    _roomListener?.dispose();

    _room?.disconnect();

    _tts.stop();

    _speech.stop();

    _chatController.dispose();

    _noteController.dispose();

    _qaCtrl.dispose();

    super.dispose();
  }

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  Future<void> _initialize() async {
    try {
      await _loadPreferences();

      await _checkPro();

      await _loadOrganizer();

      await _registerPresence();

      await _connect();

      _listenPresence();

      _listenChat();

      _listenRecordingState();

      _startTimer();

      _startLatencyMonitor();

      if (!mounted) return;

      setState(() {
        _loading = false;
      });
    } catch (e, stackTrace) {
      logger.e(
        'Large conference initialization failed',
        error: e,
        stackTrace: stackTrace,
      );

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // ===========================================================================
  // PREFERENCES
  // ===========================================================================

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (!mounted) return;

      setState(() {
        _micOn = prefs.getBool('crux_mic_default') ?? true;

        _camOn = prefs.getBool('crux_cam_default') ?? true;

        _videoQuality =
            prefs.getString('crux_video_quality') ?? _videoQuality;

        _showNetworkStats = prefs.getBool('crux_show_network_stats') ?? true;
      });
    } catch (e) {
      logger.w('Could not load conference preferences', error: e);
    }
  }

  // ===========================================================================
  // PRO
  // ===========================================================================

  Future<void> _checkPro() async {
    try {
      final value = await ProService().checkProStatus(widget.userId);

      if (!mounted) return;

      setState(() {
        _isPro = value;
      });
    } catch (e) {
      logger.w('Pro check failed', error: e);
    }
  }

  // ===========================================================================
  // ORGANIZER
  // ===========================================================================

  Future<void> _loadOrganizer() async {
    try {
      final doc =
          await _db
              .collection(AppConfig.meetingsCollection)
              .doc(widget.meetingId)
              .get();

      if (!doc.exists) return;

      final data = doc.data();

      if (data == null) return;

      _organizerId = data['organizerId']?.toString();

      _meetingLocked = data['isLocked'] == true;

      _coHosts = Set<String>.from(List<dynamic>.from(data['coHosts'] ?? []));
    } catch (e) {
      logger.w('Could not load organizer', error: e);
    }
  }

  // ===========================================================================
  // PRESENCE
  // ===========================================================================

  Future<void> _registerPresence() async {
    await MeetingService().registerPresence(
      widget.meetingId,
      widget.userId,
      widget.userName,
    );

    if (widget.isHost) {
      await MeetingService().updateMeetingStatus(
        widget.meetingId,
        MeetingStatus.ongoing,
      );
    }
  }

  void _listenPresence() {
    _presenceSubscription = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .collection('presence')
        .snapshots()
        .listen((snapshot) {
          if (!mounted) return;

          final hands = <String>{};

          for (final doc in snapshot.docs) {
            final data = doc.data();

            if (data['handRaised'] == true) {
              hands.add(doc.id);
            }
          }

          setState(() {
            _raisedHands
              ..clear()
              ..addAll(hands);
          });
        });
  }

  // ===========================================================================
  // CHAT
  // ===========================================================================

  void _listenChat() {
    _chatSubscription = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .collection('chat')
        .orderBy('timestamp', descending: false)
        .limit(AppConfig.maxLocalChatMessages)
        .snapshots()
        .listen((snapshot) {
          if (!mounted) return;

          final messages = <_ChatMessage>[];

          for (final doc in snapshot.docs) {
            final data = doc.data();

            messages.add(
              _ChatMessage(
                senderId: data['senderId']?.toString() ?? '',
                sender: data['sender']?.toString() ?? 'Anonyme',
                message:
                    data['message']?.toString() ??
                    data['text']?.toString() ??
                    '',
                timestamp:
                    data['timestamp'] is Timestamp
                        ? (data['timestamp'] as Timestamp).toDate()
                        : null,
                isPrivate: data['isPrivate'] == true,
                fileUrl: data['fileUrl']?.toString(),
                fileName: data['fileName']?.toString(),
              ),
            );
          }

          setState(() {
            _chatMessages
              ..clear()
              ..addAll(messages);

            // Compteur de messages non lus (comportement Zoom/Meet) :
            // la première synchronisation ne compte pas comme non lu.
            if (!_chatInitialSync) {
              _chatInitialSync = true;
              _lastSeenChatCount = messages.length;
            } else if (_showChat) {
              _lastSeenChatCount = messages.length;
            } else {
              _unreadChat = (messages.length - _lastSeenChatCount).clamp(
                0,
                messages.length,
              );
            }
          });
        });
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();

    if (text.isEmpty) return;

    final validationError = InputValidator.validateChatMessage(text, 'fr');

    if (validationError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(validationError)),
        );
      }
      return;
    }

    _chatController.clear();

    try {
      await _db
          .collection(AppConfig.meetingsCollection)
          .doc(widget.meetingId)
          .collection('chat')
          .add({
            'senderId': widget.userId,
            'sender': widget.userName,
            'message': text,
            'text': text,
            'timestamp': FieldValue.serverTimestamp(),
            'isPrivate': false,
          });

      await _sendData({
        'type': 'chat',
        'senderId': widget.userId,
        'sender': widget.userName,
        'message': text,
      });
    } catch (e) {
      logger.w('Chat send failed', error: e);
    }
  }

  // ===========================================================================
  // PARTAGE DE FICHIERS DANS LE CHAT (FileSharingService + Firebase Storage)
  // ===========================================================================

  Future<void> _shareChatFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(withData: true);

      if (!mounted || result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      final bytes = picked.bytes;
      final name = picked.name;

      if (bytes == null || bytes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fichier illisible.')),
        );
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Envoi du fichier…')));

      final data = await FileSharingService.instance.shareFileBytes(
        meetingId: widget.meetingId,
        fileName: name,
        bytes: bytes,
        senderId: widget.userId,
        senderName: widget.userName,
      );

      // Message de chat lié au fichier : le rendu affiche une pièce jointe.
      await _db
          .collection(AppConfig.meetingsCollection)
          .doc(widget.meetingId)
          .collection('chat')
          .add({
            'senderId': widget.userId,
            'sender': widget.userName,
            'message': '📎 ${data['fileName']}',
            'text': '📎 ${data['fileName']}',
            'fileUrl': data['fileUrl'],
            'fileName': data['fileName'],
            'fileSize': data['fileSize'],
            'timestamp': FieldValue.serverTimestamp(),
            'isPrivate': false,
          });

      await _sendData({
        'type': 'chat',
        'senderId': widget.userId,
        'sender': widget.userName,
        'message': '📎 ${data['fileName']}',
      });
    } catch (e) {
      logger.w('File share failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Partage impossible : ${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    }
  }

  // ===========================================================================
  // LIVEKIT CONNECTION
  // ===========================================================================

  Future<void> _connect() async {
    if (_isConnecting) return;

    _isConnecting = true;

    try {
      // Utiliser Firebase UID comme identité LiveKit
      final firebaseUid = LiveKitService.instance.getFirebaseIdentity();
      if (firebaseUid == null || firebaseUid.isEmpty) {
        throw Exception('Utilisateur Firebase non authentifié');
      }

      logger.i('🔐 Connecting to LiveKit with Firebase UID: $firebaseUid');

      // Obtenir les détails de connexion depuis l'API Sandbox
      final connectionDetails = await LiveKitService.instance
          .fetchConnectionDetails(
            room: widget.meetingId,
            identity: firebaseUid,
            name: widget.userName,
          );

      if (connectionDetails == null) {
        throw Exception(
          'Le serveur LiveKit Sandbox n’a pas retourné '
          'de détails de connexion valides.',
        );
      }

      logger.i('✅ LiveKit connection details received');
      logger.i('📡 Server URL: ${connectionDetails.serverUrl}');
      logger.i('🎫 Room Name: ${connectionDetails.roomName}');

      await _disposeRoom();

      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultVideoPublishOptions: const VideoPublishOptions(simulcast: true),
          // Caméra active + qualité vidéo persistée (référence Zoom/Meet).
          defaultCameraCaptureOptions: CameraCaptureOptions(
            cameraPosition: _cameraPosition,
            params: _videoParamsForQuality(_videoQuality),
          ),
          // Traitement audio « communication » piloté par NoiseReductionService
          // (préférences persistées, appliquées à la (re)connexion).
          defaultAudioCaptureOptions: AudioCaptureOptions(
            echoCancellation: NoiseReductionService.instance.echoCancellation,
            autoGainControl: NoiseReductionService.instance.autoGainControl,
            noiseSuppression: NoiseReductionService.instance.isEnabled,
            highPassFilter: true,
          ),
        ),
      );

      _room = room;

      _roomListener = room.createListener();

      _setupRoomEvents(_roomListener!);

      // Utiliser serverUrl et participantToken depuis la réponse Sandbox
      await room
          .connect(
            connectionDetails.serverUrl,
            connectionDetails.participantToken,
          )
          .timeout(
            AppConfig.roomConnectionTimeout,
            onTimeout: () {
              throw TimeoutException('Connexion LiveKit expirée.');
            },
          );

      final local = room.localParticipant;

      if (local != null) {
        await local.setMicrophoneEnabled(_micOn);

        await local.setCameraEnabled(_camOn);
      }

      _refreshParticipants();

      _reconnectAttempts = 0;

      if (mounted) {
        setState(() {
          _isReconnecting = false;
        });
      }
    } catch (error) {
      // A failed connect must not leave a half-connected room around. The
      // next attempt fetches a fresh sandbox token and creates a new room.
      await _disposeRoom();
      rethrow;
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _disposeRoom() async {
    _roomListener?.dispose();

    _roomListener = null;

    final oldRoom = _room;

    _room = null;

    if (oldRoom != null) {
      try {
        await oldRoom.disconnect();
      } catch (e) {
        logger.w('LiveKit disconnect failed', error: e);
      }
    }
  }

  // ===========================================================================
  // ROOM EVENTS
  // ===========================================================================

  void _setupRoomEvents(EventsListener<RoomEvent> listener) {
    final meetingProvider = context.read<MeetingStateProvider>();

    listener
      ..on<RoomConnectedEvent>((_) {
        _refreshParticipants();
        meetingProvider.initializeMeeting(
          meetingId: widget.meetingId,
          meetingName: widget.meetingName,
          room: _room,
        );
      })
      ..on<RoomReconnectingEvent>((_) {
        if (!mounted) return;

        setState(() {
          _isReconnecting = true;
        });
      })
      ..on<RoomReconnectedEvent>((_) {
        if (!mounted) return;

        _reconnectAttempts = 0;

        setState(() {
          _isReconnecting = false;
        });

        _refreshParticipants();
      })
      ..on<RoomDisconnectedEvent>((_) {
        if (!mounted) return;

        unawaited(_attemptReconnect());
      })
      ..on<ParticipantConnectedEvent>((event) {
        _refreshParticipants();

        // Update meeting state provider
        meetingProvider.updateParticipant(event.participant);

        if (_voiceAssistant) {
          final name =
              event.participant.name.trim().isNotEmpty
                  ? event.participant.name
                  : 'Un participant';

          _announce('$name a rejoint.');
        }
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _refreshParticipants();

        // Update meeting state provider
        meetingProvider.removeParticipant(event.participant.sid);

        if (_voiceAssistant) {
          final name =
              event.participant.name.trim().isNotEmpty
                  ? event.participant.name
                  : 'Un participant';

          _announce('$name a quitté.');
        }
      })
      ..on<ActiveSpeakersChangedEvent>((event) {
        if (!mounted) return;

        if (event.speakers.isEmpty) {
          meetingProvider.setSpeakerMode(SpeakerMode.gallery);
          return;
        }

        for (final speaker in event.speakers) {
          meetingProvider.updateAudioLevel(speaker.sid, speaker.audioLevel);
        }
      })
      ..on<ParticipantMetadataUpdatedEvent>((event) {
        _refreshParticipants();
        meetingProvider.updateParticipant(event.participant);
      })
      ..on<TrackSubscribedEvent>((event) {
        _refreshParticipants();
        meetingProvider.updateParticipant(event.participant);
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _refreshParticipants();
        meetingProvider.updateParticipant(event.participant);
      })
      ..on<TrackPublishedEvent>((event) {
        _refreshParticipants();
        meetingProvider.updateParticipant(event.participant);
      })
      ..on<TrackUnpublishedEvent>((event) {
        _refreshParticipants();
        meetingProvider.updateParticipant(event.participant);
      })
      ..on<DataReceivedEvent>(_handleDataReceived);
  }

  // ===========================================================================
  // PARTICIPANTS
  // ===========================================================================

  void _refreshParticipants() {
    final room = _room;

    if (!mounted || room == null) {
      return;
    }

    final participants = room.remoteParticipants.values.toList();

    setState(() {
      _remoteParticipants = participants;
    });

    // Update meeting state provider with all participants
    final meetingProvider = context.read<MeetingStateProvider>();

    // Add local participant
    if (room.localParticipant != null) {
      meetingProvider.updateParticipant(room.localParticipant!);
    }

    // Add all remote participants
    for (final participant in participants) {
      meetingProvider.updateParticipant(participant);
    }
  }

  // ===========================================================================
  // LIVEKIT DATA
  // ===========================================================================

  void _handleDataReceived(DataReceivedEvent event) {
    try {
      final text = utf8.decode(event.data);

      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final type = decoded['type']?.toString();

      if (type == 'mute_all') {
        final sender = event.participant?.identity;

        if (_isModeratorIdentity(sender) && _micOn) {
          _toggleMic();

          _announce('L’organisateur a coupé votre microphone.');
        }

        return;
      }

      if (type == 'mute_one') {
        final target = decoded['target']?.toString();
        final sender = event.participant?.identity;

        if (target == widget.userId && _isModeratorIdentity(sender) && _micOn) {
          _toggleMic();

          _announce('L’organisateur a coupé votre microphone.');
        }

        return;
      }

      if (type == 'reaction') {
        final emoji = decoded['emoji']?.toString();

        if (emoji != null && emoji.isNotEmpty) {
          ReactionBus.instance.publish(emoji);
        }

        return;
      }

      if (type == 'kick') {
        final target = decoded['target']?.toString();
        final sender = event.participant?.identity;

        if (target == widget.userId && _isModeratorIdentity(sender)) {
          _showRemovedByHostDialog();
        }

        return;
      }

      if (type == 'end_meeting') {
        final sender = event.participant?.identity;

        if (_isModeratorIdentity(sender) && !_isModerator) {
          _showEndedByHostDialog();
        }

        return;
      }

      if (type == 'ping') {
        final id = decoded['id'];

        if (id is int) {
          unawaited(_sendData({'type': 'pong', 'id': id}));
        }

        return;
      }

      if (type == 'pong') {
        final id = decoded['id'];

        if (id is int && _pendingPings.containsKey(id)) {
          final sentAt = _pendingPings.remove(id) ?? 0;

          final rtt = DateTime.now().millisecondsSinceEpoch - sentAt;

          // RTT plausible uniquement (horloges non synchronisées).
          if (rtt >= 0 && rtt < 60000 && mounted) {
            setState(() => _lastRttMs = rtt);

            context
                .read<MeetingStateProvider>()
                .updateNetworkStats(latency: rtt);
          }
        }

        return;
      }

      if (type == 'lower_all_hands') {
        final sender = event.participant?.identity;

        if (_isModeratorIdentity(sender)) {
          if (_handRaised) {
            unawaited(_toggleRaiseHand());
          }

          if (mounted) {
            setState(() => _raisedHands.remove(widget.userId));
          }
        }

        return;
      }

      if (type == 'lower_one') {
        final target = decoded['target']?.toString();

        if (target == widget.userId && _handRaised) {
          unawaited(_toggleRaiseHand());
        }

        return;
      }

      if (type == 'raise_hand') {
        final identity = decoded['identity']?.toString();

        if (identity == null) {
          return;
        }

        if (mounted) {
          setState(() {
            _raisedHands.add(identity);
          });
        }

        return;
      }

      if (type == 'lower_hand') {
        final identity = decoded['identity']?.toString();

        if (identity == null) {
          return;
        }

        if (mounted) {
          setState(() {
            _raisedHands.remove(identity);
          });
        }

        return;
      }
    } catch (e) {
      logger.w('LiveKit data decoding failed', error: e);
    }
  }

  Future<void> _sendData(Map<String, dynamic> payload) async {
    final room = _room;

    if (room == null) return;

    final local = room.localParticipant;

    if (local == null) return;

    try {
      final data = utf8.encode(jsonEncode(payload));

      await local.publishData(data, reliable: true);
    } catch (e) {
      logger.w('LiveKit data send failed', error: e);
    }
  }

  // ===========================================================================
  // MICROPHONE
  // ===========================================================================

  Future<void> _toggleMic() async {
    final next = !_micOn;

    try {
      final local = _room?.localParticipant;

      if (local == null) return;

      await local.setMicrophoneEnabled(next);

      if (!mounted) return;

      setState(() {
        _micOn = next;
      });
    } catch (e) {
      logger.w('Microphone toggle failed', error: e);
    }
  }

  // ===========================================================================
  // CAMERA
  // ===========================================================================

  Future<void> _toggleCamera() async {
    final next = !_camOn;

    try {
      final local = _room?.localParticipant;

      if (local == null) return;

      await local.setCameraEnabled(
        next,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: _cameraPosition,
          params: _videoParamsForQuality(_videoQuality),
        ),
      );

      if (!mounted) return;

      setState(() {
        _camOn = next;
      });
    } catch (e) {
      logger.w('Camera toggle failed', error: e);
    }
  }

  // ===========================================================================
  // QUALITÉ VIDÉO (préréglages LiveKit, cohérents avec SettingsScreen)
  // ===========================================================================

  VideoParameters _videoParamsForQuality(String quality) {
    switch (quality) {
      case 'Basse (360p)':
        return VideoParametersPresets.h360_169;
      case 'Moyenne (480p)':
        return VideoParametersPresets.h540_169;
      case 'Full HD (1080p)':
        return VideoParametersPresets.h1080_169;
      default:
        return VideoParametersPresets.h720_169;
    }
  }

  Future<void> _applyVideoQuality(String quality) async {
    if (quality == _videoQuality) return;

    if (!mounted) return;

    setState(() => _videoQuality = quality);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('crux_video_quality', quality);
    } catch (e) {
      logger.w('Could not persist video quality', error: e);
    }

    // Ré-application à chaud : la caméra est relancée avec les nouveaux
    // paramètres de capture, sans quitter la réunion.
    if (!_camOn) return;

    try {
      final local = _room?.localParticipant;

      if (local == null) return;

      await local.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: _cameraPosition,
          params: _videoParamsForQuality(quality),
        ),
      );
    } catch (e) {
      logger.w('Video quality change failed', error: e);
    }
  }

  Future<void> _switchCamera() async {
    final next =
        _cameraPosition == CameraPosition.front
            ? CameraPosition.back
            : CameraPosition.front;

    if (!mounted) return;

    setState(() => _cameraPosition = next);

    // Caméra éteinte : la position sera appliquée au prochain démarrage.
    if (!_camOn) return;

    try {
      final local = _room?.localParticipant;

      if (local == null) return;

      await local.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: next,
          params: _videoParamsForQuality(_videoQuality),
        ),
      );
    } catch (e) {
      logger.w('Camera switch failed', error: e);
    }
  }

  // ===========================================================================
  // RÉACTIONS (partagées via le data channel LiveKit)
  // ===========================================================================

  Future<void> _sendReactionString(String emoji) async {
    ReactionBus.instance.publish(emoji);

    await _sendData({
      'type': 'reaction',
      'emoji': emoji,
      'identity': widget.userId,
    });
  }

  void _showReactionsPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            // Le widget ferme lui-même la feuille après sélection.
            child: ReactionEmojis(onReactionSelected: _sendReactionString),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // MESURE DE LATENCE (ping/pong sur le data channel, style Meet)
  // ===========================================================================

  void _startLatencyMonitor() {
    _latencyTimer?.cancel();

    _latencyTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final local = _room?.localParticipant;

      if (local == null) return;

      final now = DateTime.now().millisecondsSinceEpoch;

      // Purge des pings sans réponse (> 60 s).
      _pendingPings.removeWhere((_, sentAt) => now - sentAt > 60000);

      _pendingPings[now] = now;

      _sendData({'type': 'ping', 'id': now});
    });
  }

  // ===========================================================================
  // DISPOSITION (vue orateur / galerie)
  // ===========================================================================

  void _setLayoutGallery(bool gallery) {
    final provider = context.read<MeetingStateProvider>();

    provider.setSpeakerMode(
      gallery ? SpeakerMode.gallery : SpeakerMode.single,
    );
  }

  bool get _isGalleryLayout {
    final provider = context.read<MeetingStateProvider>();

    return provider.speakerState.mode == SpeakerMode.gallery;
  }

  // ===========================================================================
  // PANNEAUX (chat / participants) — cibles des raccourcis clavier
  // ===========================================================================

  void _toggleChatPanel() {
    if (!mounted) return;

    setState(() {
      _showChat = !_showChat;
      if (_showChat) {
        _unreadChat = 0;
        _lastSeenChatCount = _chatMessages.length;
      }
    });
  }

  void _toggleParticipantsPanel() {
    if (!mounted) return;

    setState(() {
      _showParticipants = !_showParticipants;
    });
  }

  // ===========================================================================
  // ENREGISTREMENT (RecordingService + indicateur partagé style Zoom)
  // ===========================================================================

  /// Écoute le document réunion : indicateur REC, verrou et cohôtes restent
  /// synchronisés en temps réel pour tous les participants (web + mobile).
  void _listenRecordingState() {
    _recordingSub = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .snapshots()
        .listen((snap) {
          if (!mounted) return;

          final data = snap.data();

          final isRecording = data?['isRecording'] == true;

          final coHosts = Set<String>.from(
            List<dynamic>.from(data?['coHosts'] ?? const []),
          );

          final locked = data?['isLocked'] == true;

          if (isRecording != _isMeetingRecording ||
              !_setEquals(coHosts, _coHosts) ||
              locked != _meetingLocked) {
            setState(() {
              _isMeetingRecording = isRecording;

              _coHosts = coHosts;

              _meetingLocked = locked;
            });
          }
        });
  }

  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;

    return a.every(b.contains);
  }

  Future<void> _toggleRecording() async {
    if (!_isModerator) return;

    final service = RecordingService.instance;

    try {
      if (service.isRecording) {
        await service.stopRecording();

        await _db
            .collection(AppConfig.meetingsCollection)
            .doc(widget.meetingId)
            .update({'isRecording': false});

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enregistrement arrêté.')),
        );
      } else {
        await service.startRecording(
          meetingId: widget.meetingId,
          meetingName: widget.meetingName,
        );

        await _db
            .collection(AppConfig.meetingsCollection)
            .doc(widget.meetingId)
            .update({'isRecording': true});

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enregistrement démarré.')),
        );
      }
    } catch (e) {
      logger.w('Recording toggle failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enregistrement indisponible (permission ou réseau).',
            ),
          ),
        );
      }
    }
  }

  Future<void> _stopRecordingIfMine() async {
    final service = RecordingService.instance;

    if (!service.isRecording) return;

    try {
      await service.stopRecording();

      await _db
          .collection(AppConfig.meetingsCollection)
          .doc(widget.meetingId)
          .update({'isRecording': false});
    } catch (e) {
      logger.w('Stop recording on leave failed', error: e);
    }
  }

  // ===========================================================================
  // MAINS LEVÉES — actions hôtes (style Zoom)
  // ===========================================================================

  Future<void> _lowerAllHands() async {
    if (!_isModerator) return;

    if (!mounted) return;

    setState(() => _raisedHands.clear());

    await _sendData({'type': 'lower_all_hands', 'identity': widget.userId});
  }

  // ===========================================================================
  // MODÉRATION (muter un participant, exclure, verrouiller, terminer)
  // ===========================================================================

  Future<void> _requestMuteOne(String identity) async {
    await _sendData({'type': 'mute_one', 'target': identity});

    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Demande de mute envoyée.')));
  }

  Future<void> _kickParticipant(String identity) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Retirer ce participant ?',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Il sera retiré immédiatement de la réunion.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
              ),
              child: const Text('Retirer'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    await _sendData({'type': 'kick', 'target': identity});
  }

  Future<void> _toggleLockMeeting() async {
    final next = !_meetingLocked;

    try {
      await MeetingService().setLocked(widget.meetingId, next);

      if (!mounted) return;

      setState(() => _meetingLocked = next);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next
                ? 'Réunion verrouillée : plus personne ne peut rejoindre.'
                : 'Réunion déverrouillée.',
          ),
        ),
      );
    } catch (e) {
      logger.w('Lock meeting failed', error: e);
    }
  }

  Future<void> _endMeetingForAll() async {
    if (!_isModerator) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Terminer pour tous ?',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'La réunion sera clôturée pour tous les participants.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
              ),
              child: const Text('Terminer'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      await MeetingService().saveMeetingHistoryForUser(
        meetingId: widget.meetingId,
        userId: widget.userId,
        title: widget.meetingName,
        durationSeconds: _secondsElapsed,
        endMeeting: true,
      );

      await _sendData({'type': 'end_meeting'});
    } catch (e) {
      logger.w('End meeting failed', error: e);
    }

    // Rapport de fin de réunion (comme Zoom) pour l'hôte.
    final report = MeetingReportModel(
      meetingId: widget.meetingId,
      title: widget.meetingName,
      hostName: widget.userName,
      hostId: widget.userId,
      durationSeconds: _secondsElapsed,
      participantNames: [
        widget.userName,
        ..._remoteParticipants.map(
          (p) => p.name.isNotEmpty ? p.name : 'Participant',
        ),
      ],
      messageCount: _chatMessages.length,
      endedAt: DateTime.now(),
    );

    await _stopRecordingIfMine();

    await _disposeRoom();

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MeetingReportScreen(report: report)),
    );
  }

  void _showRemovedByHostDialog() {
    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Retiré de la réunion',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'L’hôte vous a retiré de cette réunion.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext);

                _leave();
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  void _showEndedByHostDialog() {
    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Réunion terminée',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'L’hôte a terminé la réunion pour tous les participants.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext);

                _leave();
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // COHÔTES (nomination/retrait par l'hôte, sync Firestore temps réel)
  // ===========================================================================

  Future<void> _toggleCoHost(String identity) async {
    try {
      if (_coHosts.contains(identity)) {
        await MeetingService().removeCoHost(widget.meetingId, identity);
      } else {
        await MeetingService().addCoHost(widget.meetingId, identity);
      }
      // La mise à jour UI arrive par le listener du document réunion.
    } catch (e) {
      logger.w('Co-host toggle failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Action co-hôte impossible.')),
        );
      }
    }
  }

  void _showParticipantActions(RemoteParticipant p) {
    if (!_isModerator) return;

    if (p.identity == _organizerId) return;

    final raised = _raisedHands.contains(p.identity);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    p.name.isNotEmpty ? p.name : 'Participant',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (raised)
                  ListTile(
                    leading: const Icon(
                      Icons.waving_hand,
                      color: Colors.orange,
                    ),
                    title: const Text(
                      'Baisser la main',
                      style: TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);

                      setState(() => _raisedHands.remove(p.identity));

                      _sendData({
                        'type': 'lower_one',
                        'target': p.identity,
                      });
                    },
                  ),
                ListTile(
                  leading: Icon(
                    _coHosts.contains(p.identity)
                        ? Icons.shield_moon_outlined
                        : Icons.shield_outlined,
                    color: AppColors.primary,
                  ),
                  title: Text(
                    _coHosts.contains(p.identity)
                        ? 'Retirer le rôle de co-hôte'
                        : 'Nommer co-hôte',
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Modération : mute, retrait, sondages, enregistrement',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);

                    _toggleCoHost(p.identity);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.mic_off_outlined,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Demander de couper le micro',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);

                    _requestMuteOne(p.identity);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.person_remove_outlined,
                    color: AppColors.error,
                  ),
                  title: const Text(
                    'Retirer de la réunion',
                    style: TextStyle(color: AppColors.error),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);

                    _kickParticipant(p.identity);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // PARAMÈTRES EN COURS DE RÉUNION
  // ===========================================================================

  void _showMeetingSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                          'Paramètres de la réunion',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Text(
                          'Vidéo',
                          style: TextStyle(
                            color: Colors.white38,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(
                          Icons.cameraswitch_outlined,
                          color: Colors.white,
                        ),
                        title: const Text(
                          'Caméra',
                          style: TextStyle(color: Colors.white),
                        ),
                        trailing: Text(
                          _cameraPosition == CameraPosition.front
                              ? 'Avant'
                              : 'Arrière',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        onTap: () {
                          _switchCamera();

                          setSheetState(() {});
                        },
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                          'Affichage',
                          style: TextStyle(
                            color: Colors.white38,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.dashboard_outlined,
                          color: Colors.white,
                        ),
                        activeTrackColor: AppColors.primary,
                        value: _isGalleryLayout,
                        onChanged: (gallery) {
                          _setLayoutGallery(gallery);

                          setSheetState(() {});
                        },
                        title: const Text(
                          'Vue galerie',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          'Sinon vue orateur automatique',
                          style: TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.speed_outlined,
                          color: Colors.white,
                        ),
                        activeTrackColor: AppColors.primary,
                        value: _showNetworkStats,
                        onChanged: (value) async {
                          setState(() => _showNetworkStats = value);

                          setSheetState(() {});

                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setBool('crux_show_network_stats', value);
                        },
                        title: const Text(
                          'Statistiques réseau',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.graphic_eq,
                          color: Colors.white,
                        ),
                        activeTrackColor: AppColors.primary,
                        value: NoiseReductionService.instance.isEnabled,
                        onChanged: (value) async {
                          await NoiseReductionService.instance.setEnabled(
                            value,
                          );

                          setSheetState(() {});

                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Appliqué à la prochaine (re)connexion audio.',
                                ),
                              ),
                            );
                          }
                        },
                        title: const Text(
                          'Réduction de bruit',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                          'Accessibilité',
                          style: TextStyle(
                            color: Colors.white38,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.closed_caption_outlined,
                          color: Colors.white,
                        ),
                        activeTrackColor: AppColors.primary,
                        value: _liveCaptions,
                        onChanged: (value) {
                          Navigator.pop(sheetContext);

                          if (value != _liveCaptions) {
                            _toggleCaptions();
                          }
                        },
                        title: const Text(
                          'Sous-titres en direct',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.volume_up_outlined,
                          color: Colors.white,
                        ),
                        activeTrackColor: AppColors.primary,
                        value: _voiceAssistant,
                        onChanged: (value) {
                          setState(() => _voiceAssistant = value);

                          setSheetState(() {});
                        },
                        title: const Text(
                          'Assistant vocal',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                          'Qualité vidéo',
                          style: TextStyle(
                            color: Colors.white38,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      ...['Basse (360p)', 'Moyenne (480p)', 'HD (720p)', 'Full HD (1080p)']
                          .map(
                            (quality) => ListTile(
                              dense: true,
                              leading: Icon(
                                quality == _videoQuality
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color:
                                    quality == _videoQuality
                                        ? AppColors.primary
                                        : Colors.white38,
                                size: 20,
                              ),
                              title: Text(
                                quality,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              onTap: () {
                                _applyVideoQuality(quality);

                                setSheetState(() {});
                              },
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
  // ===========================================================================
  // SCREEN SHARE (CORRIGÉ — anti-crash Android + Web)
  // ===========================================================================

  bool _isScreenSharingStarting = false;

  Future<void> _toggleScreenShare() async {
    // Évite le double-tap qui lance 2 MediaProjection simultanés (crash Android)
    if (_isScreenSharingStarting) {
      logger.w('Screen share already starting/stopping — ignoring tap');
      return;
    }

    final local = _room?.localParticipant;
    if (local == null) {
      logger.w('Cannot toggle screen share: no local participant');
      return;
    }

    // Si on est en train de partager → on arrête (pas de risque)
    if (_screenSharing) {
      _isScreenSharingStarting = true;
      try {
        await local.setScreenShareEnabled(false);
        if (mounted) {
          setState(() => _screenSharing = false);
          context.read<MeetingStateProvider>().setScreenSharing(false);
        }
      } catch (e) {
        logger.e('Screen share STOP failed', error: e);
      } finally {
        _isScreenSharingStarting = false;
      }
      return;
    }

    // Démarrage du partage — peut crash si permission refusée ou MediaProjection annulé
    _isScreenSharingStarting = true;
    try {
      logger.i('Starting screen share...');

      // 1. Vérifier qu'on est sur une plateforme qui supporte screen share
      if (kIsWeb) {
        // Web : getDisplayMedia — OK via setScreenShareEnabled
        await local.setScreenShareEnabled(true);
      } else {
        // Android/iOS : vérifier la permission FOREGROUND_SERVICE (Android 14+)
        // On laisse setScreenShareEnabled gérer le MediaProjection manager natif
        // mais on wrap dans un try/catch pour éviter le crash hard
        try {
          await local.setScreenShareEnabled(true).timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw TimeoutException(
                'Délai écoulé pour le partage d\'écran. L\'utilisateur a-t-il annulé ?',
              );
            },
          );
        } on TimeoutException {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Le partage d\'écran a expiré. Réessayez.'),
                backgroundColor: AppColors.error,
              ),
            );
          }
          return; // Ne pas crash
        } on PlatformException catch (e) {
          // Cas : utilisateur clique "Annuler" dans le dialog MediaProjection
          logger.w('Screen share cancelled by user: ${e.code} ${e.message}');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Partage annulé : ${e.message ?? e.code}'),
                backgroundColor: AppColors.surfaceElevated,
              ),
            );
          }
          return; // Ne pas crash
        }
      }

      if (!mounted) return;

      setState(() => _screenSharing = true);
      context.read<MeetingStateProvider>().setScreenSharing(true);
      logger.i('Screen share started successfully');
    } catch (e, stackTrace) {
      logger.e('Screen share START failed', error: e, stackTrace: stackTrace);
      if (mounted) {
        setState(() => _screenSharing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Échec du partage d\'écran: ${e.toString()}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      _isScreenSharingStarting = false;
    }
  }
  // ===========================================================================
  // RAISE HAND
  // ===========================================================================

  Future<void> _toggleRaiseHand() async {
    final next = !_handRaised;

    try {
      await _db
          .collection(AppConfig.meetingsCollection)
          .doc(widget.meetingId)
          .collection('presence')
          .doc(widget.userId)
          .set({
            'handRaised': next,
            'userId': widget.userId,
            'userName': widget.userName,
          }, SetOptions(merge: true));

      await _sendData({
        'type': next ? 'raise_hand' : 'lower_hand',
        'identity': widget.userId,
      });

      // Métadonnées participant : les tuiles vidéo (SpeakerCard) lisent
      // `hand_raised` pour afficher le badge « Main levée ».
      final local = _room?.localParticipant;

      if (local != null) {
        // setMetadata renvoie void (livekit_client <= 2.6.x) ou Future<void>
        // (>= 2.7) selon la version résolue : pas de await, compatible avec
        // les deux signatures.
        local.setMetadata(
          jsonEncode({'hand_raised': next, 'name': widget.userName}),
        );
      }

      if (!mounted) return;

      setState(() {
        _handRaised = next;
      });

      if (next) {
        _announce('Vous avez levé la main.');
      }
    } catch (e) {
      logger.w('Raise hand failed', error: e);
    }
  }

  // ===========================================================================
  // MUTE ALL
  // ===========================================================================

  Future<void> _muteAllOthers() async {
    if (!widget.isHost && widget.userId != _organizerId) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Muter tout le monde ?',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Cette action demandera aux autres participants de couper leur microphone.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Muter'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    await _sendData({'type': 'mute_all', 'identity': widget.userId});
  }

  // ===========================================================================
  // CAPTIONS
  // ===========================================================================

  Future<void> _toggleCaptions() async {
    if (_liveCaptions) {
      try {
        await _speech.stop();
      } catch (e) {
        logger.w('Speech recognition stop failed', error: e);
      }

      if (!mounted) return;

      setState(() {
        _liveCaptions = false;
        _currentTranscription = '';
      });

      return;
    }

    try {
      final available = await _speech.initialize();

      if (!available) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'La reconnaissance vocale n’est pas disponible sur cet appareil.',
              ),
            ),
          );
        }

        return;
      }

      if (!mounted) return;

      setState(() {
        _liveCaptions = true;
      });

      await _speech.listen(
        listenOptions: stt.SpeechListenOptions(
          localeId: 'fr_FR',
          partialResults: true,
          cancelOnError: false,
        ),
        onResult: (result) {
          if (!mounted) return;

          setState(() {
            _currentTranscription = result.recognizedWords;
          });
        },
      );
    } catch (e, stackTrace) {
      logger.w('Speech recognition failed', error: e, stackTrace: stackTrace);

      if (mounted) {
        setState(() {
          _liveCaptions = false;
          _currentTranscription = '';
        });
      }
    }
  }

  // ===========================================================================
  // VOICE ASSISTANT
  // ===========================================================================

  Future<void> _announce(String text) async {
    if (!_voiceAssistant) {
      return;
    }

    try {
      await _tts.setLanguage('fr-FR');

      await _tts.setPitch(1.0);

      await _tts.speak(text);
    } catch (e) {
      logger.w('TTS failed', error: e);
    }
  }

  // ===========================================================================
  // TIMER
  // ===========================================================================

  void _startTimer() {
    _callTimer?.cancel();

    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      setState(() {
        _secondsElapsed++;
      });

      if (_isPro) return;

      final limit = AppConfig.freeMeetingDurationMinutes * 60;

      if (_secondsElapsed == limit - 300) {
        _announce(
          'Attention, votre appel gratuit se terminera dans 5 minutes.',
        );
      }

      if (_secondsElapsed >= limit && !_paywallShown) {
        _paywallShown = true;

        _showPaywall();
      }
    });
  }

  String _formatElapsedDuration() {
    final hours = _secondsElapsed ~/ 3600;

    final minutes = (_secondsElapsed % 3600) ~/ 60;

    final seconds = _secondsElapsed % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // ===========================================================================
  // PAYWALL
  // ===========================================================================

  void _showPaywall() {
    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Temps écoulé',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'La limite de la réunion gratuite est atteinte.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);

                _leave();
              },
              child: const Text('Quitter'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);

                // Page d'abonnement (anciennement appel direct à
                // startPayment : l'utilisateur voit désormais l'offre).
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProScreen()),
                );
              },
              child: const Text('Devenir Pro'),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // RECONNECT
  // ===========================================================================

  Future<void> _attemptReconnect() async {
    if (!mounted || _isConnecting) {
      return;
    }

    if (_reconnectAttempts >= AppConfig.maxReconnectAttempts) {
      setState(() {
        _isReconnecting = false;
        _error = 'La connexion à la conférence a été interrompue.';
      });

      return;
    }

    _reconnectAttempts++;

    setState(() {
      _isReconnecting = true;
    });

    await Future<void>.delayed(AppConfig.reconnectDelay);

    if (!mounted) return;

    try {
      await _connect();

      if (!mounted) return;

      setState(() {
        _isReconnecting = false;
      });
    } catch (e) {
      logger.w('Reconnect attempt failed', error: e);

      if (mounted) {
        unawaited(_attemptReconnect());
      }
    }
  }

  // ===========================================================================
  // LEAVE
  // ===========================================================================

  Future<void> _confirmLeave() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Quitter la réunion ?',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Voulez-vous quitter cette conférence ?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Rester'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Quitter'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      await _leave();
    }
  }

  Future<void> _leave() async {
    try {
      await MeetingService().saveMeetingHistoryForUser(
        meetingId: widget.meetingId,
        userId: widget.userId,
        title: widget.meetingName,
        durationSeconds: _secondsElapsed,
        endMeeting: false,
      );

      await MeetingService().removePresence(widget.meetingId, widget.userId);
    } catch (e) {
      logger.w('Meeting cleanup failed', error: e);
    }

    // Si c'est moi qui enregistrais, clôturer l'enregistrement.
    await _stopRecordingIfMine();

    await _disposeRoom();

    if (!mounted) return;

    Navigator.of(context).pop();
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _buildError();
    }

    if (_loading) {
      return _buildLoading();
    }

    // Raccourcis clavier Zoom (Alt+A micro, Alt+V caméra, Alt+S partage…).
    return _shortcuts.buildKeyboardShortcutHandler(
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // Conference view (layouts vidéo + overlays). Les barres de
            // contrôles propres à cette vue sont désactivées ici : c'est cet
            // écran qui pilote réellement LiveKit.
            Positioned.fill(
              child: CruxConferenceView(
                showOverlayControls: false,
                showNetworkStats: _showNetworkStats,
              ),
            ),

          _buildTopBar(),

          if (_currentTranscription.isNotEmpty) _buildCaptions(),

          _buildBottomBar(),

          if (_showChat) _buildChatPanel(),

          if (_showParticipants) _buildParticipantsPanel(),

          if (_showNotes) _buildNotesPanel(),

          if (_showPolls) _buildPollsPanel(),

          if (_isReconnecting) _buildReconnectBanner(),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // LOADING
  // ===========================================================================

  Widget _buildLoading() {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
              color: AppColors.primary,
              strokeWidth: 2,
            ),
            const SizedBox(height: 20),
            Text(
              'Connexion au webinaire...',
              style: GoogleFonts.poppins(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              'Jusqu’à $_targetParticipants participants',
              style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // ERROR
  // ===========================================================================

  Widget _buildError() {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.error, size: 64),
              const SizedBox(height: 20),
              Text(
                _error ?? 'Erreur inconnue',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _loading = true;
                  });

                  _initialize();
                },
                child: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // TOP BAR
  // ===========================================================================

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.meetingName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Webinaire • '
                      '$_participantCountLabel',
                      style: GoogleFonts.poppins(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isMeetingRecording) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fiber_manual_record,
                        size: 12,
                        color: Colors.white,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'REC',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              NetworkQualityBars(
                stats:
                    _lastRttMs > 0
                        ? NetworkStats(
                          latencyMs: _lastRttMs.toDouble(),
                          jitterMs: 0,
                          packetLossPercent: 0,
                          bitrateKbps: 0,
                        )
                        : null,
                onTap:
                    () => setState(() {
                      _showNetworkStats = !_showNetworkStats;
                    }),
              ),
              const SizedBox(width: 8),
              _TopPill(
                icon: Icons.timer_outlined,
                text: _formatElapsedDuration(),
              ),
              const SizedBox(width: 8),
              _TopPill(
                icon: Icons.people_outline,
                text: _participantCount.toString(),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Quitter',
                onPressed: _confirmLeave,
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _participantCountLabel {
    if (_participantCount >= 1000) {
      final value = _participantCount / 1000;

      return '${value.toStringAsFixed(1)}K participants';
    }

    return '$_participantCount participants';
  }

  int get _participantCount {
    final room = _room;

    if (room == null) {
      return _remoteParticipants.length + 1;
    }

    return room.remoteParticipants.length + 1;
  }

  // ===========================================================================
  // CAPTIONS
  // ===========================================================================

  Widget _buildCaptions() {
    return Positioned(
      left: 24,
      right: 24,
      bottom: 115,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(14),
            color: Colors.black.withValues(alpha: 0.65),
            child: Text(
              _currentTranscription,
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // BOTTOM BAR
  // ===========================================================================

  Widget _buildBottomBar() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white10),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ControlButton(
                  icon: _micOn ? Icons.mic : Icons.mic_off,
                  active: _micOn,
                  onTap: _toggleMic,
                  onLongPress: _showMeetingSettings,
                ),
                _ControlButton(
                  icon: _camOn ? Icons.videocam : Icons.videocam_off,
                  active: _camOn,
                  onTap: _toggleCamera,
                  onLongPress: _showMeetingSettings,
                ),
                _ControlButton(
                  icon: Icons.poll_outlined,
                  onTap: () {
                    setState(() {
                      _showPolls = true;
                    });
                  },
                ),
                _ControlButton(
                  icon: Icons.sentiment_satisfied_alt_outlined,
                  onTap: _showReactionsPicker,
                ),
                _ControlButton(
                  icon: Icons.chat_bubble_outline,
                  badge: _unreadChat,
                  onTap: () {
                    setState(() {
                      _showChat = true;
                      _unreadChat = 0;
                      _lastSeenChatCount = _chatMessages.length;
                    });
                  },
                ),
                _ControlButton(
                  icon: Icons.people_outline,
                  onTap: () {
                    setState(() {
                      _showParticipants = true;
                    });
                  },
                ),
                _ControlButton(
                  icon: Icons.screen_share_outlined,
                  active: _screenSharing,
                  onTap: _toggleScreenShare,
                ),
                _ControlButton(
                  icon: Icons.back_hand_outlined,
                  active: _handRaised,
                  onTap: _toggleRaiseHand,
                ),
                _ControlButton(
                  icon: Icons.closed_caption_outlined,
                  active: _liveCaptions,
                  onTap: _toggleCaptions,
                ),
                _ControlButton(
                  icon: Icons.note_alt_outlined,
                  onTap: () {
                    setState(() {
                      _showNotes = true;
                    });
                  },
                ),
                _ControlButton(icon: Icons.more_horiz, onTap: _showMoreOptions),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // CHAT PANEL
  // ===========================================================================

  Widget _buildChatPanel() {
    return _Panel(
      title: 'Chat',
      onClose: () {
        setState(() {
          _showChat = false;
        });
      },
      child: Column(
        children: [
          Expanded(
            child:
                _chatMessages.isEmpty
                    ? const Center(
                      child: Text(
                        'Aucun message',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _chatMessages.length,
                      itemBuilder: (_, index) {
                        final message = _chatMessages[index];

                        return _ChatBubble(
                          message: message,
                          isMe: message.senderId == widget.userId,
                        );
                      },
                    ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Écrire un message...',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _sendChat(),
                  ),
                ),
                IconButton(
                  tooltip: 'Partager un fichier',
                  onPressed: _shareChatFile,
                  icon: const Icon(Icons.attach_file, color: Colors.white60),
                ),
                IconButton(
                  onPressed: _sendChat,
                  icon: const Icon(Icons.send, color: AppColors.primary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PARTICIPANTS PANEL
  // ===========================================================================

  Widget _buildParticipantsPanel() {
    final participants = <RemoteParticipant>[..._remoteParticipants];

    return _Panel(
      title: 'Participants ($_participantCount)',
      onClose: () {
        setState(() {
          _showParticipants = false;
        });
      },
      child: Column(
        children: [
          if (_isModerator)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _muteAllOthers,
                      icon: const Icon(Icons.mic_off, size: 18),
                      label: const Text('Muter tous'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Baisser toutes les mains',
                    onPressed: _lowerAllHands,
                    style: IconButton.styleFrom(backgroundColor: Colors.white10),
                    icon: Icon(
                      Icons.waving_hand,
                      color:
                          _raisedHands.isEmpty ? Colors.white38 : Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip:
                        _meetingLocked
                            ? 'Déverrouiller la réunion'
                            : 'Verrouiller la réunion',
                    onPressed: _toggleLockMeeting,
                    style: IconButton.styleFrom(backgroundColor: Colors.white10),
                    icon: Icon(
                      _meetingLocked ? Icons.lock : Icons.lock_open,
                      color: _meetingLocked ? Colors.orange : Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Terminer pour tous',
                    onPressed: _endMeetingForAll,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.error.withValues(alpha: 0.2),
                    ),
                    icon: const Icon(
                      Icons.cancel_presentation,
                      color: AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child:
                participants.isEmpty
                    ? const Center(
                      child: Text(
                        'Aucun participant distant',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                    : ListView.builder(
                      itemCount: participants.length,
                      itemBuilder: (_, index) {
                        final p = participants[index];

                        final raised = _raisedHands.contains(p.identity);

                        final isCoHost = _coHosts.contains(p.identity);

                        final isOrganizer = p.identity == _organizerId;

                        return ListTile(
                          onTap:
                              _isModerator
                                  ? () => _showParticipantActions(p)
                                  : null,
                          leading: _Avatar(name: p.name),
                          title: Text(
                            p.name.isNotEmpty ? p.name : 'Participant',
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            isOrganizer
                                ? 'Organisateur'
                                : (isCoHost ? 'Co-hôte' : p.identity),
                            style: TextStyle(
                              color:
                                  isOrganizer || isCoHost
                                      ? AppColors.primary
                                      : Colors.white38,
                              fontSize: 10,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isOrganizer || isCoHost)
                                Icon(
                                  isOrganizer
                                      ? Icons.star
                                      : Icons.shield_outlined,
                                  color: AppColors.primary,
                                  size: 16,
                                ),
                              if (p.isMuted)
                                const Icon(
                                  Icons.mic_off,
                                  color: Colors.white38,
                                  size: 18,
                                ),
                              if (raised)
                                const Icon(
                                  Icons.back_hand,
                                  color: Colors.orange,
                                ),
                              if (_isModerator)
                                const Icon(
                                  Icons.more_vert,
                                  color: Colors.white38,
                                  size: 18,
                                ),
                            ],
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // NOTES
  // ===========================================================================

  Widget _buildNotesPanel() {
    return _Panel(
      title: 'Notes de réunion',
      onClose: () async {
        await NoteService.instance.saveMeetingNote(
          userId: widget.userId,
          meetingId: widget.meetingId,
          meetingName: widget.meetingName,
          content: _noteController.text,
        );

        if (!mounted) return;

        setState(() {
          _showNotes = false;
        });
      },
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: TextField(
          controller: _noteController,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(color: Colors.white, height: 1.5),
          decoration: const InputDecoration(
            hintText: 'Écrivez vos notes...',
            hintStyle: TextStyle(color: Colors.white24),
            border: InputBorder.none,
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // SONDAGES & Q&A (PollsService, temps réel Firestore)
  // ===========================================================================

  Widget _buildPollsPanel() {
    final service = PollsService.instance;

    return _Panel(
      title: 'Sondages & Q&A',
      onClose: () {
        setState(() {
          _showPolls = false;
        });
      },
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              indicatorColor: AppColors.primary,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white38,
              tabs: [Tab(text: 'Sondages'), Tab(text: 'Q&A')],
            ),
            Expanded(
              child: TabBarView(
                children: [_buildPollsTab(service), _buildQaTab(service)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPollsTab(PollsService service) {
    return Column(
      children: [
        if (_isModerator)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _showCreatePollDialog,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Créer un sondage'),
              ),
            ),
          ),
        Expanded(
          child: StreamBuilder<List<Poll>>(
            stream: service.pollsStream,
            initialData: service.activePolls,
            builder: (context, snapshot) {
              final polls = snapshot.data ?? const <Poll>[];

              if (polls.isEmpty) {
                return const Center(
                  child: Text(
                    'Aucun sondage pour le moment',
                    style: TextStyle(color: Colors.white38),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: polls.length,
                itemBuilder: (_, index) => _buildPollCard(polls[index], service),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPollCard(Poll poll, PollsService service) {
    final me = FirebaseAuth.instance.currentUser?.uid;

    final hasResponded = me != null && poll.responses.containsKey(me);

    final canVote = poll.isActive && !hasResponded;

    final totalVotes = poll.options.fold<int>(0, (total, opt) => total + opt.votes);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  poll.question,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                poll.isActive ? '${poll.totalResponses} rép.' : 'Terminé',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (canVote)
            ...poll.options.map((option) {
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  poll.allowMultipleAnswers
                      ? Icons.check_box_outlined
                      : Icons.radio_button_checked,
                  color: AppColors.primary,
                  size: 20,
                ),
                title: Text(
                  option.text,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                onTap: () {
                  if (poll.allowMultipleAnswers) {
                    _showVoteDialog(poll, service);

                    return;
                  }

                  _castVote(service, poll, [option.id]);
                },
              );
            })
          else
            ...poll.options.map((option) {
              final ratio = totalVotes > 0 ? option.votes / totalVotes : 0.0;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            option.text,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Text(
                          '${option.votes}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 6,
                        backgroundColor: Colors.white10,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              );
            }),
          if (canVote && poll.allowMultipleAnswers)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _showVoteDialog(poll, service),
                child: const Text('Choisir plusieurs options'),
              ),
            ),
          if (_isModerator && poll.isActive)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => service.endPoll(poll.id),
                child: const Text(
                  'Clôturer le sondage',
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _castVote(
    PollsService service,
    Poll poll,
    List<String> optionIds,
  ) async {
    try {
      await service.respondToPoll(
        pollId: poll.id,
        selectedOptionIds: optionIds,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Vote impossible : '
              '${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    }
  }

  void _showCreatePollDialog() {
    final questionCtrl = TextEditingController();

    final optionCtrls = <TextEditingController>[
      TextEditingController(),
      TextEditingController(),
    ];

    var anonymous = false;

    var allowMultiple = false;

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: const Text(
                'Nouveau sondage',
                style: TextStyle(color: Colors.white),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: questionCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Question…',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...List.generate(optionCtrls.length, (index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: optionCtrls[index],
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Option ${index + 1}…',
                            hintStyle: const TextStyle(color: Colors.white38),
                          ),
                        ),
                      );
                    }),
                    if (optionCtrls.length < 6)
                      TextButton.icon(
                        onPressed: () {
                          setDialogState(
                            () => optionCtrls.add(TextEditingController()),
                          );
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Ajouter une option'),
                      ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeTrackColor: AppColors.primary,
                      value: allowMultiple,
                      onChanged: (v) => setDialogState(() => allowMultiple = v),
                      title: const Text(
                        'Choix multiples',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeTrackColor: AppColors.primary,
                      value: anonymous,
                      onChanged: (v) => setDialogState(() => anonymous = v),
                      title: const Text(
                        'Vote anonyme',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Annuler'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final question = questionCtrl.text.trim();

                    final options =
                        optionCtrls
                            .map((c) => c.text.trim())
                            .where((t) => t.isNotEmpty)
                            .toList();

                    if (question.isEmpty || options.length < 2) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Une question et au moins 2 options sont requises.',
                          ),
                        ),
                      );

                      return;
                    }

                    Navigator.pop(dialogContext);

                    PollsService.instance
                        .createPoll(
                          meetingId: widget.meetingId,
                          question: question,
                          options:
                              options
                                  .map(
                                    (text) => PollOption(
                                      id: const Uuid().v4(),
                                      text: text,
                                    ),
                                  )
                                  .toList(),
                          allowMultipleAnswers: allowMultiple,
                          anonymous: anonymous,
                        )
                        .catchError((Object e) {
                          logger.w('Create poll failed', error: e);

                          return '';
                        });
                  },
                  child: const Text('Lancer'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showVoteDialog(Poll poll, PollsService service) {
    final selected = <String>{};

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              title: Text(
                poll.question,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children:
                    poll.options
                        .map(
                          (option) => CheckboxListTile(
                            dense: true,
                            activeColor: AppColors.primary,
                            value: selected.contains(option.id),
                            title: Text(
                              option.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            onChanged: (checked) {
                              setDialogState(() {
                                if (checked == true) {
                                  selected.add(option.id);
                                } else {
                                  selected.remove(option.id);
                                }
                              });
                            },
                          ),
                        )
                        .toList(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Annuler'),
                ),
                ElevatedButton(
                  onPressed:
                      selected.isEmpty
                          ? null
                          : () {
                            Navigator.pop(dialogContext);

                            _castVote(service, poll, selected.toList());
                          },
                  child: const Text('Voter'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildQaTab(PollsService service) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qaCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Poser une question…',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _askQuestion(service),
                ),
              ),
              IconButton(
                onPressed: () => _askQuestion(service),
                icon: const Icon(Icons.send, color: AppColors.primary),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<List<QAQuestion>>(
            stream: service.qaStream,
            initialData: service.qaQuestions,
            builder: (context, snapshot) {
              final questions = snapshot.data ?? const <QAQuestion>[];

              if (questions.isEmpty) {
                return const Center(
                  child: Text(
                    'Aucune question',
                    style: TextStyle(color: Colors.white38),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: questions.length,
                itemBuilder: (_, index) {
                  final q = questions[index];

                  final me = FirebaseAuth.instance.currentUser?.uid;

                  final voted = me != null && (q.upvoters ?? []).contains(me);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          q.question,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        if (q.answer != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Réponse : ${q.answer}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            InkWell(
                              onTap: () {
                                service.upvoteQuestion(q.id).catchError((
                                  Object e,
                                ) {
                                  logger.w('Upvote failed', error: e);
                                });
                              },
                              child: Row(
                                children: [
                                  Icon(
                                    voted
                                        ? Icons.thumb_up
                                        : Icons.thumb_up_alt_outlined,
                                    size: 16,
                                    color:
                                        voted
                                            ? AppColors.primary
                                            : Colors.white54,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${q.upvotes}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            if (_isModerator && q.answer == null)
                              TextButton(
                                onPressed:
                                    () => _showAnswerDialog(q, service),
                                child: const Text('Répondre'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _askQuestion(PollsService service) async {
    final text = _qaCtrl.text.trim();

    if (text.isEmpty) return;

    final validationError = InputValidator.validateChatMessage(text, 'fr');

    if (validationError != null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(validationError)));
      }
      return;
    }

    _qaCtrl.clear();

    try {
      await service.askQuestion(
        meetingId: widget.meetingId,
        question: text,
        anonymous: false,
      );
    } catch (e) {
      logger.w('Ask question failed', error: e);
    }
  }

  void _showAnswerDialog(QAQuestion question, PollsService service) {
    final answerCtrl = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Répondre', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: answerCtrl,
            style: const TextStyle(color: Colors.white),
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Votre réponse…',
              hintStyle: TextStyle(color: Colors.white38),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              onPressed: () {
                final answer = answerCtrl.text.trim();

                if (answer.isEmpty) return;

                Navigator.pop(dialogContext);

                service
                    .answerQuestion(
                      questionId: question.id,
                      answer: answer,
                      answeredBy: widget.userName,
                    )
                    .catchError((Object e) {
                      logger.w('Answer failed', error: e);
                    });
              },
              child: const Text('Envoyer'),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // INFOS DE LA RÉUNION (style Zoom)
  // ===========================================================================

  String get _shareCode {
    final code = (widget.meetingCode ?? '').trim();

    return code.isNotEmpty ? code : widget.meetingId;
  }

  void _showMeetingInfo() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Infos de la réunion',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.meetingName,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.tag, color: Colors.white54, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    _shareCode,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copier le code',
                    icon: const Icon(
                      Icons.copy_outlined,
                      size: 16,
                      color: Colors.white54,
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _shareCode));

                      if (!dialogContext.mounted) return;

                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(content: Text('Code copié.')),
                      );
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.link, color: Colors.white54, size: 16),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Lien d\'invitation',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copier le lien',
                    icon: const Icon(
                      Icons.copy_outlined,
                      size: 16,
                      color: Colors.white54,
                    ),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text: AppConfig.webJoinLink(widget.meetingId),
                        ),
                      );

                      if (!dialogContext.mounted) return;

                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(content: Text('Lien copié.')),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Fermer'),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // MORE OPTIONS
  // ===========================================================================

  void _showMoreOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline, color: Colors.white),
                  title: const Text(
                    'Infos de la réunion',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _showMeetingInfo();
                  },
                ),
                if (_isModerator)
                  ListTile(
                    leading: Icon(
                      _isMeetingRecording
                          ? Icons.stop_circle
                          : Icons.fiber_manual_record,
                      color: _isMeetingRecording ? AppColors.error : Colors.white,
                    ),
                    title: Text(
                      _isMeetingRecording
                          ? 'Arrêter l\'enregistrement'
                          : 'Enregistrer la réunion',
                      style: TextStyle(
                        color:
                            _isMeetingRecording
                                ? AppColors.error
                                : Colors.white,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);

                      _toggleRecording();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.tune, color: Colors.white),
                  title: const Text(
                    'Paramètres de la réunion',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _showMeetingSettings();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.dashboard_outlined,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Changer la disposition',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _setLayoutGallery(!_isGalleryLayout);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.closed_caption_outlined,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Sous-titres en direct',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _toggleCaptions();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.screen_share_outlined,
                    color: Colors.white,
                  ),
                  title: Text(
                    _screenSharing ? 'Arrêter le partage' : 'Partager l’écran',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _toggleScreenShare();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.volume_up_outlined,
                    color: Colors.white,
                  ),
                  title: Text(
                    _voiceAssistant
                        ? 'Désactiver l’assistant vocal'
                        : 'Activer l’assistant vocal',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    setState(() {
                      _voiceAssistant = !_voiceAssistant;
                    });
                  },
                ),
                if (_isModerator)
                  ListTile(
                    leading: Icon(
                      _meetingLocked ? Icons.lock_open : Icons.lock,
                      color: Colors.white,
                    ),
                    title: Text(
                      _meetingLocked
                          ? 'Déverrouiller la réunion'
                          : 'Verrouiller la réunion',
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(context);

                      _toggleLockMeeting();
                    },
                  ),
                if (_isModerator)
                  ListTile(
                    leading: const Icon(
                      Icons.cancel_presentation,
                      color: AppColors.error,
                    ),
                    title: const Text(
                      'Terminer pour tous',
                      style: TextStyle(color: AppColors.error),
                    ),
                    onTap: () {
                      Navigator.pop(context);

                      _endMeetingForAll();
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.copy_outlined, color: Colors.white),
                  title: const Text(
                    'Copier le lien',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _copyMeetingLink();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // LINK
  // ===========================================================================

  Future<void> _copyMeetingLink() async {
    final link = AppConfig.webJoinLink(widget.meetingId);

    await Clipboard.setData(ClipboardData(text: link));

    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Lien copié.')));
  }

  // ===========================================================================
  // RECONNECT BANNER
  // ===========================================================================

  Widget _buildReconnectBanner() {
    return Positioned(
      top: 80,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reconnexion à la conférence...',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// PANEL
// =============================================================================

class _Panel extends StatelessWidget {
  final String title;

  final Widget child;

  final VoidCallback onClose;

  const _Panel({
    required this.title,
    required this.child,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            color: Colors.black.withValues(alpha: 0.90),
            child: Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// CHAT MESSAGE
// =============================================================================

class _ChatMessage {
  final String senderId;

  final String sender;

  final String message;

  final DateTime? timestamp;

  final bool isPrivate;

  /// Pièce jointe (partage de fichier dans le chat).
  final String? fileUrl;

  final String? fileName;

  const _ChatMessage({
    required this.senderId,
    required this.sender,
    required this.message,
    required this.timestamp,
    required this.isPrivate,
    this.fileUrl,
    this.fileName,
  });
}

// =============================================================================
// CHAT BUBBLE
// =============================================================================

class _ChatBubble extends StatelessWidget {
  final _ChatMessage message;

  final bool isMe;

  const _ChatBubble({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final time =
        message.timestamp == null
            ? ''
            : '${message.timestamp!.hour.toString().padLeft(2, '0')}:'
                '${message.timestamp!.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe ? AppColors.primary : Colors.white10,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                message.sender,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            Text(
              message.message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            if (message.fileUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () async {
                    final uri = Uri.tryParse(message.fileUrl!);

                    if (uri == null) return;

                    try {
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    } catch (_) {
                      // Lancement impossible : silencieux côté UI.
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.insert_drive_file_outlined,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            message.fileName ?? 'Fichier',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.open_in_new,
                          color: Colors.white38,
                          size: 12,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (time.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  time,
                  style: const TextStyle(color: Colors.white38, fontSize: 9),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// TOP PILL
// =============================================================================

class _TopPill extends StatelessWidget {
  final IconData icon;

  final String text;

  const _TopPill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white70),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CONTROL BUTTON
// =============================================================================

class _ControlButton extends StatelessWidget {
  final IconData icon;

  final bool active;

  /// Badge de notification (ex. messages de chat non lus).
  final int badge;

  final VoidCallback onTap;

  /// Appui long (menu rapide, style Zoom).
  final VoidCallback? onLongPress;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.badge = 0,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? Colors.white10 : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                icon,
                color: active ? Colors.white : Colors.white60,
                size: 22,
              ),
              if (badge > 0)
                Positioned(
                  top: -6,
                  right: -8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: const BoxDecoration(
                      color: AppColors.error,
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                    ),
                    constraints: const BoxConstraints(minWidth: 16),
                    child: Text(
                      badge > 99 ? '99+' : '$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// AVATAR
// =============================================================================

class _Avatar extends StatelessWidget {
  final String name;

  final bool large;

  const _Avatar({required this.name}) : large = false;

  @override
  Widget build(BuildContext context) {
    final size = large ? 72.0 : 42.0;

    final initial =
        name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: AppColors.primaryGradient,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: large ? 28 : 17,
        ),
      ),
    );
  }
}
