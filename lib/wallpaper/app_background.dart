import '../utils/local_file.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/colors.dart';
import 'wallpaper_config.dart';

/// Enveloppe l'app entière. Dessine l'image choisie par l'utilisateur,
/// le flou (uniforme ou progressif) et le voile de contraste.
class AppBackground extends StatelessWidget {
  final WallpaperConfig config;
  final Widget child;

  const AppBackground({super.key, required this.config, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (config.hasImage) ...[
            if (config.progressiveBlur)
              _ProgressiveBlurBackground(config: config)
            else
              _UniformBlurBackground(config: config),
            // Voile : garantit le contraste du texte quelle que soit l'image
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: config.scrim * 1.1),
                    Colors.black.withValues(alpha: config.scrim * 0.6),
                    Colors.black.withValues(alpha: config.scrim * 1.2),
                  ],
                ),
              ),
            ),
          ],
          child,
        ],
      ),
    );
  }
}

class _UniformBlurBackground extends StatelessWidget {
  final WallpaperConfig config;

  const _UniformBlurBackground({required this.config});

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(
        sigmaX: config.blurRadius,
        sigmaY: config.blurRadius,
      ),
      child: Image(
        image: localFileImage(config.imagePath!) ?? const AssetImage('assets/images/icon.png'),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }
}

class _ProgressiveBlurBackground extends StatelessWidget {
  final WallpaperConfig config;

  const _ProgressiveBlurBackground({required this.config});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Couche nette dessous
        Image(
          image: localFileImage(config.imagePath!) ?? const AssetImage('assets/images/icon.png'),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
        // Couche floue dessus, masquée en dégradé : flou en haut, net en bas
        ShaderMask(
          shaderCallback:
              (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black, Colors.black, Colors.transparent],
                stops: [0.0, 0.45, 1.0],
              ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: config.blurRadius,
              sigmaY: config.blurRadius,
            ),
            child: Image(
              image: localFileImage(config.imagePath!) ?? const AssetImage('assets/images/icon.png'),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        ),
      ],
    );
  }
}
