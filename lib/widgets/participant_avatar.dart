import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/participant_photo_cache.dart';
import '../theme/colors.dart';

/// Avatar de participant : affiche la vraie photo de profil (résolue via
/// l'UID Firebase = identité LiveKit) et retombe sur les initiales si elle
/// n'est pas encore chargée ou inexistante.
class ParticipantAvatar extends StatelessWidget {
  final String? identity;
  final String initials;
  final double fontSize;

  const ParticipantAvatar({
    super.key,
    required this.identity,
    required this.initials,
    this.fontSize = 32,
  });

  @override
  Widget build(BuildContext context) {
    final uid = identity?.trim() ?? '';
    if (uid.isEmpty) return _initials();

    return FutureBuilder<Uint8List?>(
      future: ParticipantPhotoCache.photoFor(uid),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return _initials();
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        );
      },
    );
  }

  Widget _initials() => Container(
    color: AppColors.surfaceVariant,
    alignment: Alignment.center,
    child: Text(
      initials,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    ),
  );
}
