import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../theme/colors.dart';

/// Étape de RECADRAGE après sélection d'une photo de fond d'écran.
///
/// L'utilisateur glisse et zoome l'image dans le cadre ; « Appliquer »
/// découpe exactement la zone visible (calcul en coordonnées image), la
/// redimensionne à 1920 px de large et renvoie les octets JPEG.
///
/// Fonctionne sur web comme en natif : le découpage passe par
/// `package:image` (pur Dart), pas par dart:ui Image (non lisible en
/// octets sur web).
class WallpaperCropScreen extends StatefulWidget {
  final Uint8List bytes;

  const WallpaperCropScreen({super.key, required this.bytes});

  @override
  State<WallpaperCropScreen> createState() => _WallpaperCropScreenState();
}

class _WallpaperCropScreenState extends State<WallpaperCropScreen> {
  /// Zoom utilisateur (1 = image ajustée au cadre, jusqu'à 4x).
  double _zoom = 1;

  Offset _offset = Offset.zero;

  bool _processing = false;

  Size _imageSize = Size.zero;

  /// Dernières contraintes du cadre de prévisualisation (pour le clamp).
  BoxConstraints? _lastBox;

  @override
  void initState() {
    super.initState();
    _decodeSize();
  }

  Future<void> _decodeSize() async {
    try {
      // decodeImage est synchrone (package:image, pur Dart).
      final decoded = img.decodeImage(widget.bytes);

      if (decoded == null) return;

      if (mounted) {
        setState(() => _imageSize = Size(
              decoded.width.toDouble(),
              decoded.height.toDouble(),
            ));
      }
    } catch (_) {
      // Taille inconnue : le recadrage utilisera les dimensions du widget.
    }
  }

  void _resetView() {
    setState(() {
      _zoom = 1;
      _offset = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Recadrer la photo'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
        actions: [
          IconButton(
            tooltip: 'Réinitialiser',
            onPressed: _resetView,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Glisse et zoome pour cadrer la zone à utiliser comme fond.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                  child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final firstLayout = _lastBox == null;
                      _lastBox = constraints;
                      if (firstLayout) {
                        // Centre l'image dans le cadre au premier affichage.
                        _clampOffset(constraints);
                      }

                      return GestureDetector(
                        onPanUpdate: _onPan(constraints),
                        onDoubleTap: _resetView,
                        child: Container(
                          width: constraints.maxWidth,
                          height: constraints.maxHeight,
                          color: Colors.black,
                          child: Stack(
                            children: [
                              Positioned(
                                left: _offset.dx,
                                top: _offset.dy,
                                width:
                                    _displayWidth(constraints) ?? double.nan,
                                height:
                                    _displayHeight(constraints) ?? double.nan,
                                child: Image.memory(
                                  widget.bytes,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, __, ___) => const Center(
                                    child: Text(
                                      'Image illisible',
                                      style: TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.zoom_out, size: 18),
                  Expanded(
                    child: Slider(
                      value: _zoom,
                      min: 1,
                      max: 4,
                      onChanged: (v) {
                        setState(() {
                          _zoom = v;
                          _clampOffset(_lastBox);
                        });
                      },
                    ),
                  ),
                  const Icon(Icons.zoom_in, size: 18),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _processing ? null : _applyCrop,
                  icon: _processing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(_processing ? 'Traitement…' : 'Appliquer le recadrage'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── GÉOMÉTRIE ──────────────────────────────────────────────────────────

  /// Taille affichée de l'image à zoom 1 (ajustée « cover » dans le cadre).
  Size? _coverSize(BoxConstraints box) {
    Size natural = _imageSize;

    if (natural == Size.zero) {
      // Taille intrinsèque inconnue : décodage différé impossible ici,
      // on retombe sur un ratio 16/9 raisonnable.
      natural = const Size(1920, 1080);
    }

    final scale = math.max(box.maxWidth / natural.width,
        box.maxHeight / natural.height);

    return Size(natural.width * scale, natural.height * scale);
  }

  double? _displayWidth(BoxConstraints box) {
    final cover = _coverSize(box);

    return cover == null ? null : cover.width * _zoom;
  }

  double? _displayHeight(BoxConstraints box) {
    final cover = _coverSize(box);

    return cover == null ? null : cover.height * _zoom;
  }

  GestureDragUpdateCallback _onPan(BoxConstraints box) {
    return (DragUpdateDetails details) {
      setState(() {
        _offset += details.delta;
        _clampOffset(box);
      });
    };
  }

  /// L'image doit toujours COUVRIR le cadre (pas de vide sur les bords).
  void _clampOffset(BoxConstraints? box) {
    if (box == null) return;

    final cover = _coverSize(box);

    if (cover == null) return;

    final w = cover.width * _zoom;
    final h = cover.height * _zoom;

    var dx = _offset.dx;
    var dy = _offset.dy;

    final maxX = 0.0;
    final minX = box.maxWidth - w;

    final maxY = 0.0;
    final minY = box.maxHeight - h;

    dx = w <= box.maxWidth ? (box.maxWidth - w) / 2 : dx.clamp(minX, maxX);
    dy = h <= box.maxHeight ? (box.maxHeight - h) / 2 : dy.clamp(minY, maxY);

    _offset = Offset(dx, dy);
  }

  // ── DÉCOUPE ────────────────────────────────────────────────────────────

  Future<void> _applyCrop() async {
    setState(() => _processing = true);

    try {
      final box = _lastBox;

      if (box == null) throw Exception('Cadre indisponible');

      final natural =
          _imageSize == Size.zero ? const Size(1920, 1080) : _imageSize;

      final base = math.max(
        box.maxWidth / natural.width,
        box.maxHeight / natural.height,
      );

      // Pixels écran par pixel image (cover × zoom utilisateur).
      final totalScale = base * _zoom;

      final x0 = (-_offset.dx / totalScale).clamp(0.0, natural.width);
      final y0 = (-_offset.dy / totalScale).clamp(0.0, natural.height);

      var w = math.min(box.maxWidth / totalScale, natural.width - x0);
      var h = math.min(box.maxHeight / totalScale, natural.height - y0);

      // 2) Décodage + découpe + redimensionnement (pur Dart, web inclus).
      final decoded = img.decodeImage(widget.bytes);

      if (decoded == null) throw Exception('Décodage impossible');

      var cropped = img.copyCrop(
        decoded,
        x: x0.round(),
        y: y0.round(),
        width: w.round().clamp(1, decoded.width),
        height: h.round().clamp(1, decoded.height),
      );

      const targetWidth = 1920;

      if (cropped.width > targetWidth) {
        cropped = img.copyResize(
          cropped,
          width: targetWidth,
          height: (targetWidth * cropped.height / cropped.width).round(),
        );
      }

      final out = Uint8List.fromList(img.encodeJpg(cropped, quality: 88));

      if (!mounted) return;

      Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Recadrage impossible : $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }
}
