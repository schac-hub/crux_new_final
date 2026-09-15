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
import 'package:image/image.dart' as img;
import 'package:livekit_client/livekit_client.dart' hide logger;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../meeting/minimized_meeting_overlay.dart';
import '../models/meeting_report_model.dart';
import '../models/user_model.dart';
import '../providers/meeting_state_provider.dart';
import '../services/file_sharing_service.dart';
import '../services/input_validator.dart';
import '../services/keyboard_shortcuts_service.dart';
import '../services/livekit_service.dart';
import '../services/meeting_service.dart';
import '../services/meeting_sounds_service.dart';
import '../services/noise_reduction_service.dart';
import '../services/note_service.dart';
import '../services/payment_service.dart';
import '../services/polls_service.dart';
import '../services/pro_service.dart';
import '../services/participant_photo_cache.dart';
import '../services/recording_service.dart';
import '../theme/colors.dart';
import '../utils/download_file.dart';
import '../utils/screen_share_support.dart';
import '../utils/web_audio_output.dart';
import '../utils/logger.dart';
import '../meeting/crux_conference_view.dart';
import '../meeting/entities/speaker_state.dart';
import '../meeting/reaction_bus.dart';
import '../screens/home_screen.dart';
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

  /// Sortie audio : haut-parleur (true) ou écouteur combiné (false).
  /// Uniquement pilotable sur mobile ; le web utilise le périphérique par
  /// défaut du navigateur.
  bool _speakerphoneOn = true;

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

  /// Nom d'affichage d'un participant : métadonnées d'abord (publiées dès la
  /// connexion), sinon le nom du token, sinon « Participant ». Sans cela le
  /// panneau affichait l'UID brut ou « Anonymous » à l'entrée.
  String _participantName(Participant p) {
    final metadata = p.metadata;

    if (metadata != null && metadata.isNotEmpty) {
      try {
        final decoded = jsonDecode(metadata);

        if (decoded is Map<String, dynamic>) {
          final name = decoded['name']?.toString();

          if (name != null && name.trim().isNotEmpty) return name.trim();
        }
      } catch (_) {}
    }

    return p.name.trim().isNotEmpty ? p.name.trim() : 'Participant';
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

  int _unreadPolls = 0;

  bool _isMeetingRecording = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _recordingSub;

  late final TextEditingController _qaCtrl;

  // ===========================================================================
  // EXPULSION / FIN FORCÉE (déconnexion immédiate, pas seulement un dialogue)
  // ===========================================================================

  /// Écoute `meetings/{id}/kicked/{uid}` : l'hôte écrit cette fiche au moment
  /// de l'expulsion → déconnexion LiveKit immédiate + voile plein écran.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _kickedSub;

  bool _removedByHost = false;

  bool _endedByHost = false;

  // ===========================================================================
  // SALLE D'ATTENTE (réunions privées : l'hôte admet les participants)
  // ===========================================================================

  bool _waitingRoomEnabled = false;

  bool _waitingForAdmission = false;

  bool _deniedAdmission = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _waitingSub;

  /// Réunion clôturée par l'hôte (statut `ended`) : entrée impossible.
  bool _meetingEnded = false;

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

  /// Statut Pro temps réel (activation d'un forfait pendant la réunion).
  StreamSubscription<bool>? _proSub;

  /// Écoute du document réunion : statut « ended » temps réel (hôte ou
  /// expiration du temps gratuit via MeetingStateProvider).
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _meetingStatusSub;

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

    // Sons de notification type Meet (chat, main levée, entrées/sorties).
    unawaited(MeetingSounds.instance.initialize());

    // Préférences audio (réduction de bruit, AEC, AGC) lues à la connexion.
    unawaited(NoiseReductionService.instance.initialize());

    // Initialize meeting state provider
    final meetingProvider = context.read<MeetingStateProvider>();
    // PROFIL LOCAL SANS PROVIDER : aucun provider UserModel n'est enregistré
    // dans main.dart — `context.read<UserModel>()` levait une
    // ProviderNotFoundException DANS initState → page blanche systématique
    // au lancement de réunion (le bug des « pages blanches »).
    final userModel = _localUser;
    meetingProvider.initializeMeeting(
      meetingId: widget.meetingId,
      meetingName: widget.meetingName,
      room: _room,
      userModel: userModel,
    );

    _initialize();
  }

  /// Profil de l'utilisateur local construit depuis les paramètres de
  /// l'écran + la photo Firebase Auth (pas de provider requis).
  UserModel get _localUser => UserModel(
    uid: widget.userId,
    email: widget.userEmail ?? '',
    name: widget.userName,
    profileImageUrl: FirebaseAuth.instance.currentUser?.photoURL,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // La mini-fenêtre ne doit jamais survivre à l'écran de réunion.
    MinimizedMeetingOverlay.instance.hide();

    _callTimer?.cancel();

    _latencyTimer?.cancel();

    _recordingSub?.cancel();

    _proSub?.cancel();

    _meetingStatusSub?.cancel();

    _kickedSub?.cancel();

    _waitingSub?.cancel();

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

      // Réunion clôturée par l'hôte : aucune entrée possible.
      if (_meetingEnded) {
        if (!mounted) return;

        setState(() {
          _loading = false;
          _error = 'Cette réunion a été terminée par l’hôte et n’est plus '
              'accessible.';
        });

        return;
      }

      // ── Salle d'attente (réunions privées) ──────────────────────────────
      // Sauf hôte/co-hôte : on attend l'admission de l'hôte AVANT toute
      // présence ou connexion LiveKit (référence Zoom/Meet).
      if (_waitingRoomEnabled && !_isModerator) {
        await _enterWaitingRoom();

        if (!mounted) return;

        if (_deniedAdmission || _waitingForAdmission) {
          return; // UI dédiée affichée ; la suite partira sur admission.
        }
      }

      await _finishJoin();
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

  /// Connexion effective : présence, LiveKit, listeners, timer.
  Future<void> _finishJoin() async {
    await _registerPresence();

    await _connect();

    _listenPresence();

    _listenChat();

    _listenKicked();

    _listenMeetingStatus();

    _listenRecordingState();

    _startTimer();

    _startLatencyMonitor();

    if (!mounted) return;

    setState(() {
      _loading = false;
    });
  }

  // ===========================================================================
  // SALLE D'ATTENTE
  // ===========================================================================

  Future<void> _enterWaitingRoom() async {
    try {
      await MeetingService().requestAdmission(
        widget.meetingId,
        widget.userId,
        widget.userName,
      );
    } catch (e) {
      logger.w('Waiting room registration failed', error: e);
      // Sans fiche en attente, impossible d'être admis : on laisse entrer
      // (comportement dégradé préférable à un blocage total).
      return;
    }

    if (!mounted) return;

    setState(() {
      _loading = false;
      _waitingForAdmission = true;
    });

    // L'admission = suppression de SA fiche ; le refus = decision 'denied'.
    _waitingSub = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .collection('waiting')
        .doc(widget.userId)
        .snapshots()
        .listen((snap) {
          if (!mounted || !_waitingForAdmission) return;

          if (!snap.exists) {
            // Admis : on passe en connexion effective.
            _waitingSub?.cancel();

            setState(() {
              _waitingForAdmission = false;
              _loading = true;
            });

            unawaited(
              _finishJoin().catchError((Object e) {
                logger.w('Join after admission failed', error: e);

                if (mounted) {
                  setState(() {
                    _loading = false;
                    _error = e.toString();
                  });
                }
              }),
            );

            return;
          }

          if (snap.data()?['decision'] == 'denied') {
            _waitingSub?.cancel();

            setState(() {
              _waitingForAdmission = false;
              _deniedAdmission = true;
            });
          }
        });
  }

  Widget _buildWaitingScreen() {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: const BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  widget.userName.trim().isEmpty
                      ? '?'
                      : widget.userName.trim().characters.first.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (!_deniedAdmission) ...[
                const CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2,
                ),
                const SizedBox(height: 24),
                Text(
                  'En attente de l’hôte…',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'L’hôte vous fera entrer dans « ${widget.meetingName} ».',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 28),
                OutlinedButton(
                  onPressed: () {
                    // Retrait de la fiche d'attente puis sortie.
                    _waitingSub?.cancel();

                    _db
                        .collection(AppConfig.meetingsCollection)
                        .doc(widget.meetingId)
                        .collection('waiting')
                        .doc(widget.userId)
                        .delete()
                        .catchError((Object e) {});

                    Navigator.of(context).pop();
                  },
                  child: const Text('Annuler'),
                ),
              ] else ...[
                const Icon(Icons.block, color: AppColors.error, size: 56),
                const SizedBox(height: 20),
                Text(
                  'Entrée refusée',
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'L’hôte ne vous a pas admis dans cette réunion.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: () {
                    // Nettoyage de SA fiche d'attente puis sortie.
                    _db
                        .collection(AppConfig.meetingsCollection)
                        .doc(widget.meetingId)
                        .collection('waiting')
                        .doc(widget.userId)
                        .delete()
                        .catchError((Object e) {});

                    Navigator.of(context).pop();
                  },
                  child: const Text('OK'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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

      // Statut Pro TEMPS RÉEL : si l'utilisateur active son forfait pendant
      // la réunion (paiement Wave validé), le paywall ne s'affichera pas et
      // la limite est levée sans quitter la réunion.
      _proSub = ProService()
          .proStream(widget.userId)
          .listen((value) {
            if (!mounted) return;

            if (_isPro != value) {
              setState(() => _isPro = value);

              if (value) {
                _paywallShown = false;

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Forfait actif ✓ — limite de durée levée.',
                    ),
                    backgroundColor: AppColors.success,
                  ),
                );
              }
            }
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

      _waitingRoomEnabled = data['waitingRoomEnabled'] == true;

      _meetingEnded = data['status'] == 'ended';

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
      photoUrl: FirebaseAuth.instance.currentUser?.photoURL,
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
                fileData: data['fileData']?.toString(),
                fileType: data['fileType']?.toString(),
              ),
            );
          }

          setState(() {
            // Son de notification (référence Meet) : seulement pour les
            // messages des AUTRES, jamais pour les siens.
            if (_chatInitialSync &&
                messages.length > _chatMessages.length &&
                messages.any(
                  (m) => m.senderId != widget.userId && m.message.isNotEmpty,
                )) {
              MeetingSounds.instance.play(MeetingSound.chatMessage);
            }

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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Message non envoyé : ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  // ===========================================================================
  // PARTAGE DE FICHIERS DANS LE CHAT (inline Firestore, sans Firebase Storage)
  // ===========================================================================

  /// Compresse une photo pour l'intégration inline (max 1280 px, JPEG 72).
  /// Pure Dart (`package:image`) : fonctionne aussi sur le web.
  Future<Uint8List> _compressChatImage(
    Uint8List source,
    String fileName,
  ) async {
    try {
      final decoded = img.decodeImage(source);

      if (decoded == null) return source;

      final maxDim = 1280;

      img.Image resized = decoded;

      if (decoded.width > maxDim || decoded.height > maxDim) {
        resized = img.copyResize(
          decoded,
          width:
              decoded.width >= decoded.height
                  ? maxDim
                  : null,
          height:
              decoded.height > decoded.width
                  ? maxDim
                  : null,
        );
      }

      // Les GIF animés ne passent pas par l'encodage JPEG (1 frame seulement).
      if (fileName.toLowerCase().endsWith('.gif')) {
        final png = Uint8List.fromList(img.encodePng(resized));

        if (png.length <= FileSharingService.maxInlineBytes) return png;
      }

      final jpeg = Uint8List.fromList(img.encodeJpg(resized, quality: 72));

      return jpeg.length < source.length ? jpeg : source;
    } catch (e) {
      logger.w('Image compression failed — envoi des octets d\'origine', error: e);
      return source;
    }
  }

  /// Partage d'un fichier (ou d'une photo) dans le chat : les octets sont
  /// intégrés inline dans le message Firestore (base64) — PAS de Firebase
  /// Storage (facturable). Fichiers volumineux : Cloudinary si configuré.
  Future<void> _shareChatFile({bool imageOnly = false}) async {
    try {
      final result =
          imageOnly
              ? await FilePicker.platform.pickFiles(
                type: FileType.image,
                withData: true,
              )
              : await FilePicker.platform.pickFiles(withData: true);

      if (!mounted || result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      var bytes = picked.bytes;
      var name = picked.name;

      if (bytes == null || bytes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fichier illisible.')),
        );
        return;
      }

      // Les photos sont compressées AVANT l'inline (pour passer sous la
      // limite Firestore et économiser les lectures).
      if (imageOnly && _ChatMessage.isImageName(name)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Optimisation de l\'image…')),
          );
        }

        bytes = await _compressChatImage(bytes, name);
      }

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Envoi en cours…')));

      final data = await FileSharingService.instance.shareFileBytes(
        meetingId: widget.meetingId,
        fileName: name,
        bytes: bytes,
        senderId: widget.userId,
        senderName: widget.userName,
      );

      final isImage = _ChatMessage.isImageName(data['fileName']?.toString());

      // Message de chat lié au fichier : inline (fileData) OU URL (Cloudinary).
      await _db
          .collection(AppConfig.meetingsCollection)
          .doc(widget.meetingId)
          .collection('chat')
          .add({
            'senderId': widget.userId,
            'sender': widget.userName,
            'message': '${isImage ? '📷' : '📎'} ${data['fileName']}',
            'text': '${isImage ? '📷' : '📎'} ${data['fileName']}',
            if (data['fileData'] != null) 'fileData': data['fileData'],
            if (data['fileUrl'] != null) 'fileUrl': data['fileUrl'],
            'fileName': data['fileName'],
            'fileSize': data['fileSize'],
            'fileType': data['fileType'],
            'timestamp': FieldValue.serverTimestamp(),
            'isPrivate': false,
          });

      await _sendData({
        'type': 'chat',
        'senderId': widget.userId,
        'sender': widget.userName,
        'message': '${isImage ? '📷' : '📎'} ${data['fileName']}',
      });
    } catch (e) {
      logger.w('File share failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Partage impossible : ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: AppColors.error,
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
        // On remonte la VRAIE cause (quota LiveKit Cloud atteint, HTTP 429/5xx,
        // réseau…) au lieu d'un message générique : c'est ce qui permet de
        // comprendre pourquoi un 3ᵉ participant ne peut pas rejoindre.
        throw Exception(
          'Connexion au serveur de réunion impossible : '
          '${LiveKitService.instance.lastError ?? 'erreur inconnue'}. '
          'Réessayez dans quelques instants.',
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
        // Nom + photo d'affichage IMMÉDIATS : le token sandbox met l'UID
        // Firebase comme nom (identity), donc les tuiles affichaient
        // « Anonymous » (ou l'UID brut) jusqu'au premier événement
        // metadata. La photo suit le même canal.
        if (mounted) {
          final profilePhoto = FirebaseAuth.instance.currentUser?.photoURL;

          local.setMetadata(
            jsonEncode({
              'name': widget.userName,
              if (profilePhoto != null && profilePhoto.isNotEmpty)
                'photo': profilePhoto,
              'hand_raised': _handRaised,
            }),
          );
        }

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

        // Son d'entrée (type Meet) : le compteur se rafraîchit via
        // _refreshParticipants et le pill du top bar.
        MeetingSounds.instance.play(MeetingSound.participantJoin);

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

        MeetingSounds.instance.play(MeetingSound.participantLeave);

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

        // Nouvelle piste audio : ré-applique l'état du haut-parleur
        // (mute/volume) — sinon un participant qui arrive après la coupure
        // du son restait audible.
        if (event.track is RemoteAudioTrack) {
          applyRemoteAudioOutput(_speakerphoneOn);
        }
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
      ..on<LocalTrackUnpublishedEvent>((event) {
        // Bouton « Arrêter le partage » du navigateur (barre Chrome) ou
        // MediaProjection arrêté côté système : on resynchronise l'état du
        // bouton, sinon il restait « partage actif » à tort.
        if (event.publication.source == TrackSource.screenShareVideo) {
          if (mounted) {
            setState(() => _screenSharing = false);
          }

          meetingProvider.setScreenSharing(false);
        }
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

    // PURGE DES FANTÔMES : après une reconnexion (expiration du token ~15 min
    // → nouveau salon LiveKit → nouveaux sid), les entrées de l'ANCIEN salon
    // restaient dans l'état d'affichage → DEUX profils d'une même personne.
    // Toute entrée qui n'appartient pas au salon ACTUEL est supprimée.
    final validSids = <String>{
      if (room.localParticipant != null) room.localParticipant!.sid,
      ...room.remoteParticipants.keys,
    };

    for (final sid in meetingProvider.participantStates.keys.toList()) {
      if (!validSids.contains(sid)) {
        meetingProvider.removeParticipant(sid);
      }
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
          // Déconnexion immédiate : plus d'audio/vidéo tant que le voile
          // n'a pas été validé par « OK ».
          _onForceExit(
            removedByHost: true,
            title: 'Retiré de la réunion',
            message: 'L’hôte vous a retiré de cette réunion.',
          );
        }

        return;
      }

      if (type == 'end_meeting') {
        final sender = event.participant?.identity;

        if (_isModeratorIdentity(sender) && !_isModerator) {
          _onForceExit(
            removedByHost: false,
            title: 'Réunion terminée',
            message: 'L’hôte a terminé la réunion pour tous les participants.',
          );
        }

        return;
      }

      if (type == 'poll_started') {
        // Un sondage vient d'être lancé : il devient visible de TOUS
        // immédiatement (le panneau s'ouvre automatiquement).
        if (mounted) {
          setState(() {
            _showPolls = true;
            _unreadPolls = 0;
          });

          MeetingSounds.instance.play(MeetingSound.pollStarted);

          _announce('Un nouveau sondage a été lancé.');
        }

        return;
      }

      if (type == 'question_asked') {
        if (mounted && !_showPolls) {
          setState(() => _unreadPolls++);

          MeetingSounds.instance.play(MeetingSound.chatMessage);

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '❓ Nouvelle question de ${decoded['sender'] ?? 'un participant'} '
                '(menu Plus → Sondages & Q&A)',
              ),
            ),
          );
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

        // Son « main levée » pour attirer l'attention (comme Meet/Zoom).
        if (identity != widget.userId) {
          MeetingSounds.instance.play(MeetingSound.handRaise);
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

      // Force la mise à jour de la tuile locale : sans cela l'avatar
      // persistait alors que la caméra venait de s'activer.
      context.read<MeetingStateProvider>().updateParticipant(local);
      _refreshParticipants();
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

      final captureOptions = CameraCaptureOptions(
        cameraPosition: next,
        params: _videoParamsForQuality(_videoQuality),
      );

      if (kIsWeb) {
        // Web (Chrome/Safari iOS inclus) : `facingMode` n'est re-lu qu'à
        // la (re)création de la piste. On éteint puis on relance la caméra
        // pour obtenir un vrai switch avant ↔ arrière.
        await local.setCameraEnabled(false);
        await local.setCameraEnabled(true, cameraCaptureOptions: captureOptions);
      } else {
        await local.setCameraEnabled(
          true,
          cameraCaptureOptions: captureOptions,
        );
      }
    } catch (e) {
      logger.w('Camera switch failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Impossible de changer de caméra. '
              'Autorisez l\'accès à la caméra ou reprenez la vidéo.',
            ),
          ),
        );
      }
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Main levée : comme sur Zoom, elle vit dans le menu réactions.
                ListTile(
                  leading: Icon(
                    Icons.back_hand,
                    color: _handRaised ? Colors.orange : Colors.white70,
                  ),
                  title: Text(
                    _handRaised ? 'Baisser la main' : 'Lever la main',
                    style: TextStyle(
                      color: _handRaised ? Colors.orange : Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);

                    _toggleRaiseHand();
                  },
                ),
                const Divider(color: Colors.white10, height: 20),
                // Le widget ferme lui-même la feuille après sélection.
                ReactionEmojis(onReactionSelected: _sendReactionString),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===========================================================================
  // HAUT-PARLEUR (sortie audio)
  // ===========================================================================

  // NOTE : la manipulation web des <audio> LiveKit vit dans
  // `utils/web_audio_output.dart` (import conditionnel) — `package:web`
  // ne doit JAMAIS être importé directement ici, sinon la build Android
  // échoue à compiler le moteur Dart.

  Future<void> _toggleSpeakerphone() async {
    final next = !_speakerphoneOn;

    if (kIsWeb) {
      // Web (Chrome/Safari/Firefox, iOS inclus) : coupe ou rétablit la
      // sortie des pistes audio distantes.
      applyRemoteAudioOutput(next);

      if (!mounted) return;

      setState(() => _speakerphoneOn = next);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next ? 'Haut-parleur activé.' : 'Son coupé (haut-parleur muet).',
          ),
        ),
      );

      return;
    }

    try {
      // API PORTABLE : `Hardware.setSpeakerphoneOn` existe dans toutes les
      // versions de livekit_client (la CI résout une version plus ancienne
      // que la locale, où `AudioManager` n'existe pas encore). Dépréciée en
      // local (2.11) mais fonctionnelle — ignore le warning.
      // ignore: deprecated_member_use
      await Hardware.instance.setSpeakerphoneOn(next);
    } catch (e) {
      logger.w('Speakerphone toggle failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sortie audio non disponible sur cet appareil.'),
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    setState(() => _speakerphoneOn = next);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          next
              ? 'Haut-parleur activé.'
              : 'Son sur l\'écouteur combiné.',
        ),
      ),
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
  /// Détecte aussi la fin de réunion décidée par l'hôte : tout le monde est
  /// alors déconnecté, même si le message data channel a été manqué.
  void _listenRecordingState() {
    _recordingSub = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .snapshots()
        .listen((snap) {
          if (!mounted) return;

          final data = snap.data();

          // Réunion clôturée par l'hôte : sortie forcée pour tous sauf les
          // modérateurs (l'hôte voit son rapport de fin).
          if (data?['status'] == 'ended' && !_isModerator) {
            _onForceExit(
              removedByHost: false,
              title: 'Réunion terminée',
              message: 'L’hôte a terminé la réunion pour tous les participants.',
            );

            return;
          }

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

    // 1. Message data channel (déconnexion immédiate chez la cible).
    await _sendData({'type': 'kick', 'target': identity});

    // 2. Fiche persistée dans Firestore : la cible est déconnectée même si le
    // paquet data a été perdu, et ne peut plus rejoindre cette réunion.
    try {
      await MeetingService().kickParticipant(
        widget.meetingId,
        identity,
        kickedBy: widget.userId,
      );
    } catch (e) {
      logger.w('Kick persistence failed', error: e);
    }
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

  /// Salle d'attente : l'hôte admet manuellement chaque nouveau participant
  /// (référence Zoom). Les modérateurs entrent toujours directement.
  Future<void> _toggleWaitingRoom() async {
    final next = !_waitingRoomEnabled;

    try {
      await MeetingService().setWaitingRoom(widget.meetingId, next);

      if (!mounted) return;

      setState(() => _waitingRoomEnabled = next);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            next
                ? 'Salle d\'attente activée : l\'hôte admettra les participants.'
                : 'Salle d\'attente désactivée.',
          ),
        ),
      );
    } catch (e) {
      logger.w('Waiting room toggle failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Salle d\'attente indisponible.')),
        );
      }
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

  /// Expulsion ou fin forcée : on coupe IMMÉDIATEMENT LiveKit (plus d'audio,
  /// plus de data, plus de participation) et on affiche un voile plein écran.
  /// L'ancien comportement (simple dialogue sur données appuyer « OK »)
  /// laissait le participant discuter et entendre la réunion.
  void _onForceExit({
    required bool removedByHost,
    required String title,
    required String message,
  }) {
    if (!mounted || _removedByHost || _endedByHost) return;

    setState(() {
      _removedByHost = removedByHost;
      _endedByHost = !removedByHost;
    });

    unawaited(_disposeRoom());

    _announce(message);
  }

  Widget _buildForceExitOverlay() {
    final removed = _removedByHost;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                removed ? Icons.person_remove : Icons.meeting_room,
                color: removed ? AppColors.error : Colors.orange,
                size: 64,
              ),
              const SizedBox(height: 24),
              Text(
                removed ? 'Retiré de la réunion' : 'Réunion terminée',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                removed
                    ? 'L’hôte vous a retiré de cette réunion. '
                        'Vous ne pouvez plus y accéder.'
                    : 'L’hôte a terminé la réunion pour tous les participants. '
                        'Elle n’est plus accessible.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _leave,
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Écoute la fiche d'expulsion écrite par l'hôte dans Firestore. Complète le
  /// message data channel : ça marche même si un paquet data a été perdu et
  /// bloque aussi la ré-entrée (la fiche persiste).
  void _listenKicked() {
    if (widget.userId.isEmpty) return;

    _kickedSub = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .collection('kicked')
        .doc(widget.userId)
        .snapshots()
        .listen((snap) {
          if (!mounted || !snap.exists) return;

          _onForceExit(
            removedByHost: true,
            title: 'Retiré de la réunion',
            message: 'L’hôte vous a retiré de cette réunion.',
          );
        });
  }

  /// Écoute le statut de la réunion en temps réel : quand le document passe
  /// à `status: 'ended'` (hôte, ou expiration du temps gratuit déclenchée
  /// par [MeetingStateProvider]), tout le monde est déconnecté et voit le
  /// voile « Réunion terminée ».
  void _listenMeetingStatus() {
    _meetingStatusSub = _db
        .collection(AppConfig.meetingsCollection)
        .doc(widget.meetingId)
        .snapshots()
        .listen((snap) {
          if (!mounted || !snap.exists) return;

          final status = snap.data()?['status']?.toString();

          if (status == 'ended') {
            _onForceExit(
              removedByHost: false,
              title: 'Réunion terminée',
              message: 'La réunion est terminée.',
            );
          }
        });
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
                    _participantName(p),
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
                      // Bouton retour : referme les paramètres et reprend
                      // directement le chat (demande utilisateur).
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Retour au chat',
                            onPressed: () {
                              Navigator.pop(sheetContext);

                              setState(() {
                                _showChat = true;
                                _unreadChat = 0;
                                _lastSeenChatCount = _chatMessages.length;
                              });
                            },
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Colors.white,
                            ),
                          ),
                          const Expanded(
                            child: Text(
                              'Paramètres de la réunion',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                              ),
                            ),
                          ),
                        ],
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
        try {
          // Web : getDisplayMedia — OK via setScreenShareEnabled
          await local.setScreenShareEnabled(true);
        } catch (e) {
          final message = e.toString().toLowerCase();

          logger.w('Screen share web start failed', error: e);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: AppColors.error,
                content: Text(
                  message.contains('permission') ||
                          message.contains('notallowed') ||
                          message.contains('denied')
                      ? 'Partage refusé : autorisez le partage d\'écran '
                          'dans la fenêtre du navigateur (choisissez un '
                          'onglet ou un écran).'
                      : message.contains('secure') ||
                          message.contains('display')
                      ? 'Le partage d\'écran nécessite une fenêtre '
                          'sécurisée (HTTPS) et un navigateur compatible '
                          '(Chrome, Edge, Firefox).'
                      : 'Partage d\'écran impossible : $e',
                ),
              ),
            );
          }

          return;
        }
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
      // `hand_raised` pour afficher le badge « Main levée ». On préserve
      // la photo : setMetadata remplace tout l'objet.
      final local = _room?.localParticipant;

      if (local != null && mounted) {
        final profilePhoto = FirebaseAuth.instance.currentUser?.photoURL;

        // setMetadata renvoie void (livekit_client <= 2.6.x) ou Future<void>
        // (>= 2.7) selon la version résolue : pas de await, compatible avec
        // les deux signatures.
        local.setMetadata(
          jsonEncode({
            'hand_raised': next,
            'name': widget.userName,
            if (profilePhoto != null && profilePhoto.isNotEmpty)
              'photo': profilePhoto,
          }),
        );
      }

      if (!mounted) return;

      setState(() {
        _handRaised = next;
      });

      if (next) {
        MeetingSounds.instance.play(MeetingSound.handRaise);

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

      // Battement de cœur (hôte) : maintient `endTime` dans le futur pour
      // que la réunion reste visible sur l'écran d'accueil tant qu'elle vit.
      if (widget.isHost && _secondsElapsed > 0 && _secondsElapsed % 600 == 0) {
        unawaited(
          MeetingService().pushMeetingEndTime(
            widget.meetingId,
            ahead: const Duration(minutes: 20),
          ),
        );
      }

      if (_isPro) return;

      final limit = AppConfig.freeMeetingDurationMinutes * 60;

      // Avertissements hôte : 10 minutes puis 5 minutes avant l'échéance,
      // avec son d'alerte dédié (l'hôte doit percevoir même sans écran).
      if (widget.isHost && _secondsElapsed == limit - 600) {
        _playFreeTierWarning(10);
      }

      if (widget.isHost && _secondsElapsed == limit - 300) {
        _playFreeTierWarning(5);
      }

      if (_secondsElapsed >= limit && !_paywallShown) {
        _paywallShown = true;

        _showPaywall();
      }
    });
  }

  /// Alerte « limite gratuite bientôt atteinte » (hôte uniquement) :
  /// son dédié + annonce vocale + bandeau.
  void _playFreeTierWarning(int minutesLeft) {
    MeetingSounds.instance.play(MeetingSound.limitWarning);

    _announce(
      'Attention, votre réunion gratuite se terminera dans '
      '$minutesLeft minutes.',
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '⏳ Limite gratuite bientôt atteinte — '
          '$minutesLeft minutes restantes. Prolongez pour 3 000 F ou '
          'passez au forfait Pro.',
        ),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 6),
      ),
    );
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
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text(
              'Temps écoulé',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'La limite de la réunion gratuite (1 h 45) est atteinte. '
              'Prolongez la réunion ou passez à un forfait pour continuer.',
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
              TextButton(
                onPressed: () {
                  Navigator.pop(context);

                  _continueMeetingWithWave();
                },
                child: const Text(
                  'Continuer — 3 000 F',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);

                  // Page d'abonnement : offres Pro (25 000 F) et
                  // Max (85 000 F), paiement Wave + vérification auto.
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProScreen()),
                  );
                },
                child: const Text('Devenir Pro'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Prolongation de la réunion en cours pour 3 000 F (Wave).
  ///
  /// Ouvre le lien Wave, lance la vérification automatique en boucle et,
  /// dès confirmation serveur : la limite locale est levée (l'appel
  /// continue) et `endTime` est repoussé dans Firestore.
  Future<void> _continueMeetingWithWave() async {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Paiement Wave 3 000 F — vérification automatique en cours…',
        ),
        backgroundColor: Colors.blueGrey,
      ),
    );

    final verified = await PaymentService().pollVerification(
      WaveProduct.meetingContinue,
      attempts: 20,
      meetingId: widget.meetingId,
    );

    if (!mounted) return;

    if (verified) {
      setState(() {
        // Lève la limite locale : le timer cesse d'afficher le paywall.
        _isPro = true;
        _paywallShown = false;
      });

      // Cohérence Firestore (endTime repoussé côté serveur déjà, on
      // s'assure que la réunion reste visible immédiatement).
      await MeetingService().pushMeetingEndTime(
        widget.meetingId,
        ahead: const Duration(hours: 3),
      );

      MeetingSounds.instance.play(MeetingSound.pollStarted);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '✅ Paiement confirmé — la réunion continue !',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Paiement non détecté — termine le paiement Wave puis '
              'relance la prolongation.',
            ),
            backgroundColor: Colors.orange,
          ),
        );

        _showPaywall();
      }
    }
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
    if (_removedByHost || _endedByHost) {
      return _buildForceExitOverlay();
    }

    if (_waitingForAdmission || _deniedAdmission) {
      return _buildWaitingScreen();
    }

    if (_error != null) {
      return _buildError();
    }

    if (_loading) {
      return _buildLoading();
    }

    // Raccourcis clavier Zoom (Alt+A micro, Alt+V caméra, Alt+S partage…).
    //
    // Le bouton système « retour » RÉDUIT la réunion en mini-fenêtre flottante
    // (la réunion reste active en arrière-plan) au lieu de la quitter.
    return _shortcuts.buildKeyboardShortcutHandler(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _minimizeMeeting();
        },
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
      ),
    );
  }

  // ===========================================================================
  // RÉDUCTION (mini-fenêtre flottante, réunion active en arrière-plan)
  // ===========================================================================

  void _minimizeMeeting() {
    final navigator = Navigator.of(context);

    MinimizedMeetingOverlay.instance.show(
      context: context,
      meetingName: widget.meetingName,
      participantCount: () => _participantCount,
      elapsedSeconds: () => _secondsElapsed,
      videoTrack: _pickMiniVideoTrack,
      onExpand: () {
        // Revenir : on referme l'écran d'accueil poussé par-dessus.
        navigator.pop();
      },
      onEnd: () {
        navigator.pop();

        unawaited(_leave());
      },
    );

    // L'écran de réunion reste monté SOUS l'accueil (route poussée) : LiveKit
    // et les listeners continuent de tourner en arrière-plan.
    navigator.push(
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          user: UserModel(
            uid: widget.userId,
            email: widget.userEmail ?? '',
            name: widget.userName,
          ),
        ),
      ),
    );
  }

  /// Meilleur flux vidéo pour la mini-fenêtre : partage d'écran d'abord, sinon
  /// la première caméra active (locale ou distante).
  VideoTrack? _pickMiniVideoTrack() {
    final room = _room;

    if (room == null) return null;

    final participants = <Participant?>[
      room.localParticipant,
      ...room.remoteParticipants.values,
    ];

    for (final source in [
      TrackSource.screenShareVideo,
      TrackSource.camera,
    ]) {
      for (final p in participants) {
        if (p == null) continue;

        final pub = p.getTrackPublicationBySource(source);

        final track = pub?.track;

        if (track is VideoTrack) return track;
      }
    }

    return null;
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
                tooltip: 'Réduire (réunion en arrière-plan)',
                onPressed: _minimizeMeeting,
                icon: const Icon(
                  Icons.picture_in_picture_alt,
                  color: Colors.white,
                ),
              ),
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
                // ── Essentiels (référence Zoom) : micro, caméra, partage,
                //    chat, participants, réactions, plus.
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
                // Partage d'écran : web UNIQUEMENT, et seulement si le
                // navigateur expose getDisplayMedia (Safari iOS ne l'a pas →
                // bouton masqué) ; sur mobile MediaProjection crashe l'app.
                if (kIsWeb && isScreenShareSupported)
                  _ControlButton(
                    icon: Icons.screen_share_outlined,
                    active: _screenSharing,
                    onTap: _toggleScreenShare,
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
                  icon: Icons.sentiment_satisfied_alt_outlined,
                  onTap: _showReactionsPicker,
                ),
                // ── Tout le reste (sondages, notes, sous-titres, main
                //    levée, paramètres…) vit dans le menu « Plus ».
                _ControlButton(
                  icon: Icons.more_horiz,
                  badge: _unreadPolls,
                  onTap: _showMoreOptions,
                ),
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
                  tooltip: 'Envoyer une photo',
                  onPressed: () => _shareChatFile(imageOnly: true),
                  icon: const Icon(Icons.image_outlined, color: Colors.white60),
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
          // Salle d'attente (modérateurs) : admettre / refuser, référence Zoom.
          if (_isModerator) _buildWaitingRoomSection(),
          Expanded(
            child:
                participants.isEmpty
                    ? ListView(
                      children: const [
                        SizedBox(height: 40),
                        Center(
                          child: Text(
                            'Vous êtes seul pour le moment.\n'
                            'Partagez le code ou le lien pour inviter.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ],
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
                          leading: _Avatar(
                            name: _participantName(p),
                            uid: p.identity,
                          ),
                          title: Text(
                            _participantName(p),
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
          // Moi-même : toujours visible, tout en bas de la liste.
          ListTile(
            leading: _Avatar(name: widget.userName, uid: widget.userId),
            title: Text(
              '${widget.userName} (Vous)',
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              _isModerator ? 'Modérateur' : 'Participant',
              style: const TextStyle(color: AppColors.primary, fontSize: 10),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_micOn)
                  const Icon(Icons.mic_off, color: Colors.white38, size: 18),
                if (!_camOn)
                  const Icon(
                    Icons.videocam_off,
                    color: Colors.white38,
                    size: 18,
                  ),
                if (_handRaised)
                  const Icon(Icons.back_hand, color: Colors.orange, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // SALLE D'ATTENTE — vue hôte (admettre / refuser)
  // ===========================================================================

  Widget _buildWaitingRoomSection() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: MeetingService().streamWaiting(widget.meetingId),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

        if (docs.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.hourglass_top,
                    color: Colors.orange,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Salle d\'attente (${docs.length})',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              ...docs.map((doc) {
                final name = doc.data()['name']?.toString() ?? 'Participant';

                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: _Avatar(name: name, uid: doc.id),
                  title: Text(
                    name,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Demande d\'accès',
                    style: TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton(
                        onPressed: () => MeetingService().admitParticipant(
                          widget.meetingId,
                          doc.id,
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.success,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 32),
                        ),
                        child: const Text(
                          'Admettre',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () => MeetingService().denyParticipant(
                          widget.meetingId,
                          doc.id,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error,
                          side: const BorderSide(color: AppColors.error),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 32),
                        ),
                        child: const Text(
                          'Refuser',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  // ===========================================================================
  // NOTES
  // ===========================================================================

  Widget _buildNotesPanel() {
    return _Panel(
      title: 'Notes de réunion',
      onClose: () async {
        await _saveNotes();

        if (!mounted) return;

        setState(() {
          _showNotes = false;
        });
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saveNotes,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Sauvegarder'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _exportNotes,
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Exporter'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
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
          ),
        ],
      ),
    );
  }

  Future<void> _saveNotes() async {
    try {
      await NoteService.instance.saveMeetingNote(
        userId: widget.userId,
        meetingId: widget.meetingId,
        meetingName: widget.meetingName,
        content: _noteController.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notes sauvegardées ✓ (visibles dans l\'historique)'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      logger.w('Save notes failed', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sauvegarde impossible : $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _exportNotes() async {
    final content = _noteController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Aucune note à exporter'),
          backgroundColor: AppColors.surfaceElevated,
        ),
      );
      return;
    }

    final header = 'CRUX — ${widget.meetingName}\n'
        'Code : ${widget.meetingCode ?? widget.meetingId}\n'
        'Date : ${DateTime.now().toLocal()}\n'
        '${'-' * 40}\n\n';

    try {
      final savedPath = await exportTextFile(
        'crux_notes_${widget.meetingId}.txt',
        header + content,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              savedPath != null
                  ? 'Notes exportées : $savedPath'
                  : 'Notes téléchargées ✓',
            ),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      logger.w('Export notes failed', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export impossible : $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
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

                    _createPoll(
                      question: question,
                      options: options,
                      allowMultiple: allowMultiple,
                      anonymous: anonymous,
                    );
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

  /// Création du sondage : erreurs AFFICHÉES à l'hôte (l'ancien code les
  /// avalait silencieusement) puis diffusion à tous les participants
  /// (ouverture automatique du panneau chez chacun).
  Future<void> _createPoll({
    required String question,
    required List<String> options,
    required bool allowMultiple,
    required bool anonymous,
  }) async {
    try {
      await PollsService.instance.createPoll(
        meetingId: widget.meetingId,
        question: question,
        options:
            options
                .map(
                  (text) => PollOption(id: const Uuid().v4(), text: text),
                )
                .toList(),
        allowMultipleAnswers: allowMultiple,
        anonymous: anonymous,
      );

      await _sendData({'type': 'poll_started', 'by': widget.userId});

      if (!mounted) return;

      setState(() {
        _showPolls = true;
        _unreadPolls = 0;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sondage lancé — visible par tous les participants ✓'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      logger.w('Create poll failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sondage impossible : ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
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

      // Notification temps réel aux autres participants (badge + toast).
      await _sendData({
        'type': 'question_asked',
        'sender': widget.userName,
      });
    } catch (e) {
      logger.w('Ask question failed', error: e);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Question impossible : ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
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
                ListTile(
                  leading: const Icon(Icons.poll_outlined, color: Colors.white),
                  title: const Text(
                    'Sondages & Q&A',
                    style: TextStyle(color: Colors.white),
                  ),
                  trailing:
                      _unreadPolls > 0
                          ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: const BoxDecoration(
                              color: AppColors.error,
                              borderRadius: BorderRadius.all(
                                Radius.circular(999),
                              ),
                            ),
                            child: Text(
                              '$_unreadPolls',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                          : null,
                  onTap: () {
                    Navigator.pop(context);

                    setState(() {
                      _showPolls = true;
                      _unreadPolls = 0;
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.note_alt_outlined,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Notes de réunion',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    setState(() {
                      _showNotes = true;
                    });
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.back_hand_outlined,
                    color: _handRaised ? Colors.orange : Colors.white,
                  ),
                  title: Text(
                    _handRaised ? 'Baisser la main' : 'Lever la main',
                    style: TextStyle(
                      color: _handRaised ? Colors.orange : Colors.white,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _toggleRaiseHand();
                  },
                ),
                ListTile(
                  leading: Icon(
                    _speakerphoneOn
                        ? Icons.speaker
                        : Icons.phone_in_talk_outlined,
                    color: Colors.white,
                  ),
                  title: Text(
                    _speakerphoneOn
                        ? 'Son : haut-parleur'
                        : 'Son : écouteur combiné',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _toggleSpeakerphone();
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
                    Icons.cameraswitch_outlined,
                    color: Colors.white,
                  ),
                  title: const Text(
                    'Changer de caméra (avant / arrière)',
                    style: TextStyle(color: Colors.white),
                  ),
                  trailing: Text(
                    _cameraPosition == CameraPosition.front
                        ? 'Avant'
                        : 'Arrière',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(context);

                    _switchCamera();
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
                if (kIsWeb && isScreenShareSupported)
                  ListTile(
                    leading: const Icon(
                      Icons.screen_share_outlined,
                      color: Colors.white,
                    ),
                    title: Text(
                      _screenSharing
                          ? 'Arrêter le partage'
                          : 'Partager l’écran',
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
                    leading: Icon(
                      Icons.hourglass_top,
                      color: _waitingRoomEnabled ? Colors.orange : Colors.white,
                    ),
                    title: Text(
                      _waitingRoomEnabled
                          ? 'Désactiver la salle d\'attente'
                          : 'Activer la salle d\'attente',
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      _waitingRoomEnabled
                          ? 'Les nouveaux participants entrent directement'
                          : 'L\'hôte admet chaque participant manuellement',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);

                      _toggleWaitingRoom();
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

  /// Octets inline (base64, SANS préfixe data:) — alternative gratuite à
  /// Firebase Storage : l'image vit dans le document de chat Firestore.
  final String? fileData;

  /// Type déclaré ('image' / 'document') par l'expéditeur.
  final String? fileType;

  const _ChatMessage({
    required this.senderId,
    required this.sender,
    required this.message,
    required this.timestamp,
    required this.isPrivate,
    this.fileUrl,
    this.fileName,
    this.fileData,
    this.fileType,
  });

  static const _imageExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
  ];

  /// Vrai si la pièce jointe est une image (aperçu inline dans la bulle).
  static bool isImageName(String? name) {
    if (name == null) return false;

    final lower = name.toLowerCase();

    return _imageExtensions.any(lower.endsWith);
  }

  bool get isImageAttachment =>
      fileType == 'image' || isImageName(fileName);

  /// Octets décodés de la pièce jointe inline (null si absent/invalide).
  Uint8List? get inlineBytes {
    final data = fileData;

    if (data == null || data.isEmpty) return null;

    try {
      return base64Decode(data);
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// CHAT BUBBLE
// =============================================================================

class _ChatBubble extends StatelessWidget {
  final _ChatMessage message;

  final bool isMe;

  const _ChatBubble({required this.message, required this.isMe});

  /// Ouvre la pièce jointe dans un nouvel onglet (web) / app externe.
  static Future<void> _openAttachment(String url) async {
    final uri = Uri.tryParse(url);

    if (uri == null) return;

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // Lancement impossible : silencieux côté UI.
    }
  }

  /// Visionneuse plein écran d'une photo inline partagée dans le chat,
  /// avec bouton d'enregistrement (téléchargement web / dossier Documents).
  static void _showImageViewer(BuildContext context, _ChatMessage message) {
    final bytes = message.inlineBytes;

    if (bytes == null) return;

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  tooltip: 'Enregistrer',
                  onPressed: () => _saveInlineAttachment(dialogContext, message),
                  icon: const Icon(Icons.download, color: Colors.white),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Enregistre la pièce jointe inline : téléchargement navigateur (web)
  /// ou fichier dans le dossier Documents (natif).
  static Future<void> _saveInlineAttachment(
    BuildContext context,
    _ChatMessage message,
  ) async {
    final bytes = message.inlineBytes;

    if (bytes == null) return;

    final name = message.fileName ?? 'crux_fichier';

    try {
      final savedPath = await exportBinaryFile(name, bytes);

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath != null ? 'Enregistré : $savedPath' : 'Téléchargé ✓',
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enregistrement impossible.'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

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
        // AppColors.primary est BLANC dans le thème Obsidian : un texte blanc
        // dessus était illisible (bulles « blanchies » sur web). On force des
        // contrastes explicites quel que soit le thème.
        decoration: BoxDecoration(
          color:
              isMe
                  ? AppColors.primary
                  : Colors.white.withValues(alpha: 0.10),
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
              style: TextStyle(
                color: isMe ? AppColors.textOnPrimary : Colors.white,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            // Aperçu inline pour les photos partagées dans le chat.
            // 1) Octets inline (base64, sans service de stockage).
            if (message.isImageAttachment && message.inlineBytes != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: GestureDetector(
                  onTap: () => _showImageViewer(context, message),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      message.inlineBytes!,
                      width: 240,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          width: 240,
                          height: 44,
                          color: Colors.black26,
                          alignment: Alignment.center,
                          child: const Text(
                            'Aperçu indisponible',
                            style: TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            // 2) Image servie par URL (Cloudinary — gros fichiers).
            if (message.isImageAttachment &&
                message.inlineBytes == null &&
                message.fileUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: GestureDetector(
                  onTap: () => _openAttachment(message.fileUrl!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      message.fileUrl!,
                      width: 240,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;

                        return Container(
                          width: 240,
                          height: 160,
                          color: Colors.white10,
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          width: 240,
                          height: 44,
                          color: Colors.black26,
                          alignment: Alignment.center,
                          child: const Text(
                            'Aperçu indisponible — toucher pour ouvrir',
                            style: TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            // Document inline : toucher pour télécharger/enregistrer.
            if (!message.isImageAttachment && message.inlineBytes != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () => _saveInlineAttachment(context, message),
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
                          Icons.download,
                          color: Colors.white38,
                          size: 14,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Document servi par URL (Cloudinary).
            if (!message.isImageAttachment &&
                message.inlineBytes == null &&
                message.fileUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: InkWell(
                  onTap: () => _openAttachment(message.fileUrl!),
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

  /// UID Firebase (= identité LiveKit) : permet d'afficher la VRAIE photo
  /// de profil au lieu des initiales.
  final String? uid;

  const _Avatar({required this.name, this.uid}) : large = false;

  @override
  Widget build(BuildContext context) {
    final size = large ? 72.0 : 42.0;

    final initial =
        name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

    final photo = uid == null || uid!.trim().isEmpty
        ? null
        : ParticipantPhotoCache.photoFor(uid!.trim());

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        gradient: AppColors.primaryGradient,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: photo == null
          ? Text(
              initial,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: large ? 28 : 17,
              ),
            )
          : FutureBuilder<Uint8List?>(
              future: photo,
              builder: (context, snap) {
                final bytes = snap.data;

                if (bytes == null) {
                  return Text(
                    initial,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: large ? 28 : 17,
                    ),
                  );
                }

                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  width: size,
                  height: size,
                  gaplessPlayback: true,
                );
              },
            ),
    );
  }
}
