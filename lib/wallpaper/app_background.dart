import '../utils/local_file.dart';
import 'dart:convert';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../theme/colors.dart';
import 'wallpaper_config.dart';

/// Enveloppe l'app entière. Dessine l'image choisie par l'utilisateur,
/// le flou (uniforme ou progressif) et le voile de contraste.
class AppBackground extends StatelessWidget {
  final WallpaperConfig config;
  final Widget child;

  const AppBackground({super.key, required this.config, required this.child});

  /// Décodage base64 mémoïsé : éviter de redécoder quelques centaines de Ko
  /// à chaque rebuild.
  static (String, Uint8List)? _b64Cache;

  static ImageProvider _resolveImage(WallpaperConfig config) {
    final b64 = config.imageBase64;
    if (b64 != null && b64.isNotEmpty) {
      final cached = _b64Cache;
      if (cached != null && cached.$1 == b64) return MemoryImage(cached.$2);
      try {
        final clean = b64.contains(',') ? b64.split(',').last : b64;
        final bytes = base64Decode(clean);
        _b64Cache = (b64, bytes);
        return MemoryImage(bytes);
      } catch (_) {
        // base64 corrompue : on retombe sur le fichier/asset.
      }
    }
    return localFileImage(config.imagePath ?? '') ??
        const AssetImage('assets/images/icon.png');
  }

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
        image: AppBackground._resolveImage(config),
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
          image: AppBackground._resolveImage(config),
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
              image: AppBackground._resolveImage(config),
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
