import 'package:flutter/material.dart';

/// Badge du VRAI logo CRUX (assets/images/icon.png — la même image que
/// l'icône de l'app et l'écran d'inscription). Remplace les anciens
/// placeholders « C » et icônes caméra utilisés comme logo.
class AppLogoBadge extends StatelessWidget {
  final double size;

  final double? borderRadius;

  const AppLogoBadge({super.key, this.size = 64, this.borderRadius});

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? size * 0.28;

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: Colors.white,
      ),
      child: Image.asset(
        'assets/images/icon.png',
        fit: BoxFit.cover,
        width: size,
        height: size,
      ),
    );
  }
}
