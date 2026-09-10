import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import '../providers/meeting_state_provider.dart';
import 'entities/speaker_state.dart';
import 'entities/participant_display.dart';
import 'layout/conference_layout_engine.dart';
import 'reaction_bus.dart';
import 'widgets/speaker_card.dart';
import 'widgets/live_feed_item.dart';
import 'widgets/network_stats_overlay.dart';
import 'controls/contextual_controls_bar.dart';
import 'widgets/reactions_overlay.dart';
import '../theme/animations/conference_animations.dart';
import '../theme/colors.dart';
import '../theme/conference_theme.dart';

class CruxConferenceView extends StatefulWidget {
  /// Affiche la barre de contrôles + le sélecteur de réactions embarqués.
  ///
  /// À désactiver lorsque la vue est intégrée dans un écran qui pilote
  /// déjà LiveKit et fournit ses propres contrôles
  /// (ex. LargeConferenceScreen), sinon deux barres se superposent.
  final bool showOverlayControls;

  /// Affiche l'overlay de statistiques réseau (fps, latence…).
  final bool showNetworkStats;

  const CruxConferenceView({
    super.key,
    this.showOverlayControls = true,
    this.showNetworkStats = true,
  });

  @override
  State<CruxConferenceView> createState() => _CruxConferenceViewState();
}

class _CruxConferenceViewState extends State<CruxConferenceView>
    with TickerProviderStateMixin {
  late AnimationController _speakerAnimationController;
  late AnimationController _layoutAnimationController;
  final ScrollController _feedScrollController = ScrollController();
  final List<ReactionParticle> _reactionParticles = [];
  Timer? _particlePruneTimer;

  @override
  void initState() {
    super.initState();
    _speakerAnimationController = AnimationController(
      duration: ConferenceTheme.speakerTransition,
      vsync: this,
    );
    _layoutAnimationController = AnimationController(
      duration: ConferenceTheme.layoutChange,
      vsync: this,
    );

    // Réactions locales ET distantes arrivent par le même bus.
    ReactionBus.instance.addListener(_onReactionPublished);

    // Les particules expirées sont purgées régulièrement (sinon la liste
    // grossit indéfiniment pendant une longue réunion).
    _particlePruneTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (!mounted) return;

      final before = _reactionParticles.length;

      _reactionParticles.removeWhere((particle) => particle.isExpired);

      if (_reactionParticles.length != before) {
        setState(() {});
      }
    });
  }

  void _onReactionPublished() {
    if (!mounted) return;

    final emoji = ReactionBus.instance.lastEmoji;

    if (emoji == null) return;

    setState(() {
      final size = MediaQuery.of(context).size;
      final index = _reactionParticles.length;
      _reactionParticles.add(
        ReactionParticle(
          emoji: emoji,
          startPosition: Offset(
            size.width * 0.3 + (size.width * 0.4 / 8) * (index % 8),
            size.height * 0.7,
          ),
          velocity: Offset(
            (size.width * 0.4 / 8) * ((index % 8) - 4),
            -200 - (index % 3) * 50,
          ),
          scale: 0.8 + (index % 5) * 0.1,
          rotation: (index * 45) % 360,
          duration: const Duration(seconds: 3),
        ),
      );
    });
  }

  @override
  void dispose() {
    ReactionBus.instance.removeListener(_onReactionPublished);
    _particlePruneTimer?.cancel();
    _speakerAnimationController.dispose();
    _layoutAnimationController.dispose();
    _feedScrollController.dispose();
    super.dispose();
  }

  void _handleControlAction(ControlAction action) {
    final provider = context.read<MeetingStateProvider>();

    switch (action) {
      case ControlAction.mic:
        provider.toggleMic();
        break;
      case ControlAction.camera:
        provider.toggleCamera();
        break;
      case ControlAction.handRaise:
        provider.toggleHandRaise();
        break;
      case ControlAction.screenShare:
        provider.toggleScreenShare();
        break;
      case ControlAction.reactions:
        // Show reactions picker
        break;
      case ControlAction.settings:
        // Navigate to settings
        break;
      case ControlAction.leave:
        // Leave meeting
        break;
    }
  }

  void _addReaction(ReactionEmoji emoji) {
    // Le passage par le bus centralise la création de particules.
    ReactionBus.instance.publish(emoji.emoji);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Consumer<MeetingStateProvider>(
        builder: (context, provider, child) {
          final layoutEngine = ConferenceLayoutEngine(
            screenSize: MediaQuery.of(context).size,
            speakerState: provider.speakerState,
            feedConfig: provider.feedConfig,
            participantCount: provider.participantCount,
          );

          final layoutMetrics = layoutEngine.calculateLayout();

          return Stack(
            children: [
              // Main content area
              _buildMainContent(provider, layoutMetrics),

              // Network stats overlay
              if (widget.showNetworkStats)
                NetworkStatsOverlay(
                  fps: provider.fps,
                  latency: provider.latency,
                  bandwidth: provider.bandwidth,
                  jitter: provider.jitter,
                ),

              // Reactions overlay (particules locales + distantes)
              ReactionsOverlay(
                particles: _reactionParticles,
                showPicker: widget.showOverlayControls,
                onReactionTap: _addReaction,
              ),

              // Contextual controls (mode autonome uniquement)
              if (widget.showOverlayControls)
                Positioned(
                  left: layoutMetrics.controlsArea.left,
                  bottom: layoutMetrics.controlsArea.top,
                  child: ContextualControlsBar(
                    isMicEnabled: provider.isMicEnabled,
                    isCameraEnabled: provider.isCameraEnabled,
                    isHandRaised: provider.isHandRaised,
                    isScreenSharing: provider.isScreenSharing,
                    onControlAction: _handleControlAction,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMainContent(
    MeetingStateProvider provider,
    LayoutMetrics layoutMetrics,
  ) {
    switch (provider.speakerState.mode) {
      case SpeakerMode.single:
        return _buildSingleSpeakerLayout(provider, layoutMetrics);
      case SpeakerMode.dual:
        return _buildDualSpeakerLayout(provider, layoutMetrics);
      case SpeakerMode.screenshare:
        return _buildScreenshareLayout(provider, layoutMetrics);
      case SpeakerMode.gallery:
        return _buildGalleryLayout(provider, layoutMetrics);
    }
  }

  Widget _buildSingleSpeakerLayout(
    MeetingStateProvider provider,
    LayoutMetrics layoutMetrics,
  ) {
    final speakerState = provider.speakerState;

    ParticipantDisplayState? speakerParticipant;

    if (speakerState.hasSpeaker) {
      speakerParticipant = _getParticipantDisplayState(
        provider,
        speakerState.currentSpeaker!.sid,
      );
    }

    // Avant le premier orateur détecté, afficher le premier participant
    // (le local) au lieu d'une salle d'attente vide.
    speakerParticipant ??=
        provider.activeParticipants.isNotEmpty
            ? provider.activeParticipants.first
            : null;

    if (speakerParticipant == null) {
      return _buildWaitingRoom();
    }

    return Stack(
      children: [
        // Speaker container
        Positioned.fromRect(
          rect: layoutMetrics.speakerArea,
          child: ConferenceAnimations.speakerAppearance(
            controller: _speakerAnimationController,
            child: SpeakerCard(
              participantState: speakerParticipant,
              isPinned: speakerState.isPinned,
              isDominantSpeaker: speakerState.hasSpeaker,
              onTap:
                  () =>
                      provider.pinParticipant(speakerParticipant!.participantId),
              onLongPress: () => provider.unpinParticipant(),
            ),
          ),
        ),

        // Live feed
        if (layoutMetrics.feedVisible)
          Positioned.fromRect(
            rect: layoutMetrics.feedArea,
            child: _buildLiveFeed(provider),
          ),
      ],
    );
  }

  Widget _buildDualSpeakerLayout(
    MeetingStateProvider provider,
    LayoutMetrics layoutMetrics,
  ) {
    final speakerState = provider.speakerState;
    if (!speakerState.hasSpeaker || !speakerState.isDualSpeaker) {
      return _buildSingleSpeakerLayout(provider, layoutMetrics);
    }

    final primarySpeaker = _getParticipantDisplayState(
      provider,
      speakerState.currentSpeaker!.sid,
    );
    final secondarySpeaker =
        speakerState.secondarySpeaker != null
            ? _getParticipantDisplayState(
              provider,
              speakerState.secondarySpeaker!.sid,
            )
            : null;

    if (primarySpeaker == null) {
      return _buildWaitingRoom();
    }

    return Stack(
      children: [
        // Primary speaker
        Positioned.fromRect(
          rect: Rect.fromLTWH(
            layoutMetrics.speakerArea.left,
            layoutMetrics.speakerArea.top,
            layoutMetrics.speakerArea.width / 2,
            layoutMetrics.speakerArea.height,
          ),
          child: SpeakerCard(
            participantState: primarySpeaker,
            isPinned: speakerState.isPinned,
            isDominantSpeaker: true,
          ),
        ),

        // Secondary speaker
        if (secondarySpeaker != null)
          Positioned.fromRect(
            rect: Rect.fromLTWH(
              layoutMetrics.speakerArea.left +
                  layoutMetrics.speakerArea.width / 2,
              layoutMetrics.speakerArea.top,
              layoutMetrics.speakerArea.width / 2,
              layoutMetrics.speakerArea.height,
            ),
            child: SpeakerCard(
              participantState: secondarySpeaker,
              isDominantSpeaker: false,
            ),
          ),

        // Live feed
        if (layoutMetrics.feedVisible)
          Positioned.fromRect(
            rect: layoutMetrics.feedArea,
            child: _buildLiveFeed(provider),
          ),
      ],
    );
  }

  Widget _buildScreenshareLayout(
    MeetingStateProvider provider,
    LayoutMetrics layoutMetrics,
  ) {
    // Le partageur est désormais détecté réellement
    // (ConferenceLayoutController.updateParticipant / isScreenShareEnabled).
    ParticipantDisplayState? sharingParticipant;
    for (final p in provider.activeParticipants) {
      if (p.isScreenSharing) {
        sharingParticipant = p;
        break;
      }
    }

    // Rendu réel du flux de partage (screenShareVideo) quand souscrit,
    // sinon placeholder explicite.
    Widget shareContent;
    if (sharingParticipant != null) {
      final sharePub =
          sharingParticipant.participant.getTrackPublicationBySource(
            TrackSource.screenShareVideo,
          );
      final track = sharePub?.track;
      if (track is VideoTrack) {
        shareContent = VideoTrackRenderer(track);
      } else {
        shareContent = _buildScreensharePlaceholder(sharingParticipant);
      }
    } else {
      shareContent = _buildScreensharePlaceholder(null);
    }

    return Stack(
      children: [
        // Screen share container
        Positioned.fromRect(
          rect: layoutMetrics.speakerArea,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppColors.radiusCard),
            child: shareContent,
          ),
        ),

        // Live feed
        if (layoutMetrics.feedVisible)
          Positioned.fromRect(
            rect: layoutMetrics.feedArea,
            child: _buildLiveFeed(provider),
          ),
      ],
    );
  }

  Widget _buildScreensharePlaceholder(ParticipantDisplayState? sharer) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusCard),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.screen_share, size: 64, color: AppColors.primary),
            const SizedBox(height: 16),
            if (sharer != null)
              Text(sharer.displayName, style: ConferenceTheme.speakerNameStyle),
            const SizedBox(height: 8),
            const Text(
              'Partage d\'écran',
              style: ConferenceTheme.feedNameStyle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryLayout(
    MeetingStateProvider provider,
    LayoutMetrics layoutMetrics,
  ) {
    return Positioned.fromRect(
      rect: layoutMetrics.speakerArea,
      child: _buildParticipantGrid(provider, layoutMetrics),
    );
  }

  Widget _buildLiveFeed(MeetingStateProvider provider) {
    return Container(
      decoration: BoxDecoration(
        color: ConferenceTheme.feedBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        controller: _feedScrollController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: provider.activeParticipants.length,
        itemBuilder: (context, index) {
          final participant = provider.activeParticipants[index];
          return LiveFeedItem(
            participantState: participant,
            onTap: () => provider.pinParticipant(participant.participantId),
            showAudioIndicator: provider.feedConfig.showAudioIndicators,
            showBadges: provider.feedConfig.showBadges,
          );
        },
      ),
    );
  }

  Widget _buildParticipantGrid(
    MeetingStateProvider provider,
    LayoutMetrics layoutMetrics,
  ) {
    if (!layoutMetrics.isGridLayout) {
      return _buildWaitingRoom();
    }

    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: layoutMetrics.gridColumns!,
        childAspectRatio:
            (layoutMetrics.tileSize?.width ?? 100) /
            (layoutMetrics.tileSize?.height ?? 100),
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      padding: const EdgeInsets.all(8),
      itemCount: provider.activeParticipants.length,
      itemBuilder: (context, index) {
        final participant = provider.activeParticipants[index];
        return SpeakerCard(
          participantState: participant,
          onTap: () => provider.pinParticipant(participant.participantId),
        );
      },
    );
  }

  Widget _buildWaitingRoom() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 64, color: AppColors.textSecondary),
          SizedBox(height: 16),
          Text(
            'En attente de participants...',
            style: ConferenceTheme.speakerNameStyle,
          ),
        ],
      ),
    );
  }

  ParticipantDisplayState? _getParticipantDisplayState(
    MeetingStateProvider provider,
    String participantId,
  ) {
    return provider.participantStates[participantId];
  }
}
