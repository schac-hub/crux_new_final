import 'dart:math';
import 'package:flutter/material.dart';
import '../../theme/colors.dart';

enum ReactionEmoji {
  thumbsUp('👍'),
  heart('❤️'),
  clapping('👏'),
  fire('🔥'),
  laugh('😂'),
  wow('😮'),
  sad('😢'),
  angry('😠');

  final String emoji;
  const ReactionEmoji(this.emoji);
}

class ReactionParticle {
  final String emoji;
  final Offset startPosition;
  final Offset velocity;
  final double scale;
  final double rotation;
  final Duration duration;
  final DateTime createdAt;

  ReactionParticle({
    required this.emoji,
    required this.startPosition,
    required this.velocity,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.duration = const Duration(seconds: 3),
  }) : createdAt = DateTime.now();

  bool get isExpired => DateTime.now().difference(createdAt) > duration;
}

class ReactionsOverlay extends StatefulWidget {
  final List<ReactionParticle> particles;
  final Function(ReactionEmoji)? onReactionTap;

  /// Affiche le sélecteur de réactions flottant. Peut être désactivé quand
  /// l'écran hôte fournit son propre sélecteur (ex. feuille modale).
  final bool showPicker;

  const ReactionsOverlay({
    super.key,
    this.particles = const [],
    this.showPicker = true,
    this.onReactionTap,
  });

  @override
  State<ReactionsOverlay> createState() => _ReactionsOverlayState();
}

class _ReactionsOverlayState extends State<ReactionsOverlay>
    with TickerProviderStateMixin {
  late AnimationController _particleController;
  final Random _random = Random();
  final List<ReactionParticle> _activeParticles = [];

  @override
  void initState() {
    super.initState();
    _particleController = AnimationController(
      duration: const Duration(milliseconds: 16),
      vsync: this,
    )..addListener(_updateParticles);
    _particleController.repeat();
  }

  @override
  void didUpdateWidget(ReactionsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _activeParticles.clear();
    _activeParticles.addAll(widget.particles);
  }

  @override
  void dispose() {
    _particleController.dispose();
    super.dispose();
  }

  void _updateParticles() {
    if (_activeParticles.isEmpty) return;

    setState(() {
      _activeParticles.removeWhere((particle) => particle.isExpired);
    });
  }

  void _addReaction(ReactionEmoji emoji) {
    final size = MediaQuery.of(context).size;
    final particle = ReactionParticle(
      emoji: emoji.emoji,
      startPosition: Offset(
        size.width * 0.3 + _random.nextDouble() * size.width * 0.4,
        size.height * 0.7,
      ),
      velocity: Offset(
        (_random.nextDouble() - 0.5) * 200,
        -(_random.nextDouble() * 300 + 200),
      ),
      scale: 0.8 + _random.nextDouble() * 0.4,
      rotation: _random.nextDouble() * 360,
      duration: Duration(milliseconds: 2000 + _random.nextInt(2000)),
    );

    setState(() {
      _activeParticles.add(particle);
    });

    widget.onReactionTap?.call(emoji);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Particle layer
        ..._activeParticles.map((particle) => _buildParticle(particle)),

        // Reaction picker (optionnel)
        if (widget.showPicker)
          Positioned(bottom: 100, right: 20, child: _buildReactionPicker()),
      ],
    );
  }

  Widget _buildParticle(ReactionParticle particle) {
    final progress =
        DateTime.now().difference(particle.createdAt).inMilliseconds /
        particle.duration.inMilliseconds;
    final progressClamped = progress.clamp(0.0, 1.0);

    final currentPosition =
        particle.startPosition + particle.velocity * progressClamped;
    final currentScale = particle.scale * (1 - progressClamped * 0.5);
    final currentRotation = particle.rotation * progressClamped;
    final opacity = 1.0 - progressClamped;

    return Positioned(
      left: currentPosition.dx,
      top: currentPosition.dy,
      child: Transform.rotate(
        angle: currentRotation * 3.14159 / 180,
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: currentScale,
            child: Text(particle.emoji, style: const TextStyle(fontSize: 32)),
          ),
        ),
      ),
    );
  }

  Widget _buildReactionPicker() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border, width: 1),
        boxShadow: AppColors.softShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children:
                ReactionEmoji.values.take(4).map((emoji) {
                  return _buildReactionButton(emoji);
                }).toList(),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children:
                ReactionEmoji.values.skip(4).map((emoji) {
                  return _buildReactionButton(emoji);
                }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildReactionButton(ReactionEmoji emoji) {
    return GestureDetector(
      onTap: () => _addReaction(emoji),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: 40,
        height: 40,
        decoration: const BoxDecoration(
          color: AppColors.surfaceVariant,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(emoji.emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

class QuickReactionsBar extends StatelessWidget {
  final Function(ReactionEmoji) onReaction;
  final bool isExpanded;

  const QuickReactionsBar({
    super.key,
    required this.onReaction,
    this.isExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isExpanded) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...ReactionEmoji.values.map((emoji) => _buildQuickButton(emoji)),
        ],
      ),
    );
  }

  Widget _buildQuickButton(ReactionEmoji emoji) {
    return GestureDetector(
      onTap: () => onReaction(emoji),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(emoji.emoji, style: const TextStyle(fontSize: 20)),
      ),
    );
  }
}
