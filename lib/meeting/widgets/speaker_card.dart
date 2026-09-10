import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../../theme/colors.dart';
import '../../widgets/participant_avatar.dart';
import '../entities/participant_display.dart';

class SpeakerCard extends StatelessWidget {
  final ParticipantDisplayState participantState;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isPinned;
  final bool isDominantSpeaker;

  const SpeakerCard({
    super.key,
    required this.participantState,
    this.onTap,
    this.onLongPress,
    this.isPinned = false,
    this.isDominantSpeaker = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppColors.radiusCard),
          border: Border.all(
            color: isDominantSpeaker ? AppColors.primary : AppColors.border,
            width: isDominantSpeaker ? 2 : 1,
          ),
          boxShadow:
              isDominantSpeaker
                  ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.3),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ]
                  : AppColors.softShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppColors.radiusCard),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildVideoContent(),
              _buildOverlay(),
              _buildBadges(),
              if (participantState.hasHandRaised) _buildHandRaisedIndicator(),
              if (isPinned) _buildPinnedIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoContent() {
    if (participantState.isVideoEnabled) {
      final videoPublications =
          participantState.participant.videoTrackPublications;
      if (videoPublications.isNotEmpty) {
        final videoTrack = videoPublications.first.track;
        if (videoTrack != null && videoTrack is VideoTrack) {
          return VideoTrackRenderer(videoTrack);
        }
      }
      return _buildAvatarPlaceholder();
    } else {
      return _buildAvatarPlaceholder();
    }
  }

  Widget _buildAvatarPlaceholder() {
    return ParticipantAvatar(
      identity: participantState.participant.identity,
      initials: participantState.initials,
      fontSize: 48,
    );
  }

  Widget _buildOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              participantState.displayName,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (participantState.isScreenSharing)
              const Text(
                'Partage d\'écran',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadges() {
    return Positioned(
      top: 12,
      right: 12,
      child: Row(
        children: [
          if (!participantState.isAudioActive) _buildAudioBadge(),
          if (participantState.isVideoEnabled) _buildVideoBadge(),
        ],
      ),
    );
  }

  Widget _buildAudioBadge() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: AppColors.error,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.mic_off, size: 16, color: AppColors.textPrimary),
    );
  }

  Widget _buildVideoBadge() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(
        color: AppColors.success,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.videocam, size: 16, color: AppColors.textPrimary),
    );
  }

  Widget _buildHandRaisedIndicator() {
    return Positioned(
      top: 12,
      left: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.handRaised,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.back_hand, size: 16, color: AppColors.textPrimary),
            SizedBox(width: 4),
            Text(
              'Main levée',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedIndicator() {
    return Positioned(
      bottom: 12,
      right: 12,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.push_pin,
          size: 16,
          color: AppColors.textOnPrimary,
        ),
      ),
    );
  }
}
