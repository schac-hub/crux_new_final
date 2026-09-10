import 'dart:convert';

class WallpaperConfig {
  /// Chemin du fichier copié dans le stockage interne de l'app (natif).
  /// null = pas d'image fichier.
  final String? imagePath;

  /// Image encodée en base64, persistée dans SharedPreferences : support
  /// du fond personnalisé sur web (pas de système de fichiers) et fallback
  /// si le fichier natif disparaît.
  final String? imageBase64;

  /// Rayon de flou en dp, 0..maxBlur. iOS utilise ~15-30 pour l'écran d'accueil.
  final double blurRadius;

  /// Flou progressif : très flou en haut, net en bas (comportement iOS 26).
  final bool progressiveBlur;

  /// Voile sombre par-dessus l'image, garantit le contraste du texte. 0.0..0.8
  final double scrim;

  static const double maxBlur = 50.0;
  static const double maxScrim = 0.8;

  const WallpaperConfig({
    this.imagePath,
    this.imageBase64,
    this.blurRadius = 0.0,
    this.progressiveBlur = false,
    this.scrim = 0.35,
  });

  bool get hasFileImage => imagePath != null && imagePath!.isNotEmpty;
  bool get hasBase64Image => imageBase64 != null && imageBase64!.isNotEmpty;
  bool get hasImage => hasFileImage || hasBase64Image;

  static const WallpaperConfig defaultConfig = WallpaperConfig();

  WallpaperConfig copyWith({
    String? imagePath,
    String? imageBase64,
    double? blurRadius,
    bool? progressiveBlur,
    double? scrim,
  }) {
    return WallpaperConfig(
      imagePath: imagePath ?? this.imagePath,
      imageBase64: imageBase64 ?? this.imageBase64,
      blurRadius: blurRadius ?? this.blurRadius,
      progressiveBlur: progressiveBlur ?? this.progressiveBlur,
      scrim: scrim ?? this.scrim,
    );
  }

  Map<String, dynamic> toJson() => {
    'imagePath': imagePath,
    'imageBase64': imageBase64,
    'blurRadius': blurRadius,
    'progressiveBlur': progressiveBlur,
    'scrim': scrim,
  };

  factory WallpaperConfig.fromJson(Map<String, dynamic> json) =>
      WallpaperConfig(
        imagePath: json['imagePath'] as String?,
        imageBase64: json['imageBase64'] as String?,
        blurRadius: (json['blurRadius'] as num?)?.toDouble() ?? 0.0,
        progressiveBlur: json['progressiveBlur'] as bool? ?? false,
        scrim: (json['scrim'] as num?)?.toDouble() ?? 0.35,
      );

  String toJsonString() => jsonEncode(toJson());

  factory WallpaperConfig.fromJsonString(String json) =>
      WallpaperConfig.fromJson(jsonDecode(json));
}
