import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'wallpaper_provider.dart';
import '../theme/colors.dart';
import 'glass_surface.dart';
import 'wallpaper_config.dart';

/// Écran de sélection du fond d'écran CRUX.
/// L'aperçu EST le fond réel : ce que vous voyez est ce que vous obtenez.
///
/// CORRECTIFS :
///   * l'aperçu passe par WallpaperProvider → toute l'app se met à jour en
///     direct (avant, l'accueil gardait l'ancien fond) ;
///   * « Appliquer » est toujours actif (on peut aussi enregistrer le retour
///     au fond CRUX par défaut) ;
///   * la configuration d'origine est restaurée si l'on quitte sans appliquer ;
///   * gestion d'erreur sur l'import (permission refusée, fichier illisible).
class WallpaperPickerScreen extends StatefulWidget {
  const WallpaperPickerScreen({super.key});

  @override
  State<WallpaperPickerScreen> createState() => _WallpaperPickerScreenState();
}

class _WallpaperPickerScreenState extends State<WallpaperPickerScreen> {
  final _picker = ImagePicker();

  late final WallpaperProvider _provider;
  late final WallpaperConfig _initial;
  bool _applied = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _provider = context.read<WallpaperProvider>();
    _initial = _provider.config;
  }

  @override
  void dispose() {
    // Quitter sans appliquer ne doit rien changer.
    if (!_applied) _provider.preview(_initial);
    super.dispose();
  }

  Future<void> _pickImage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        imageQuality: 85,
      );
      if (picked == null) return;

      // readAsBytes() fonctionne sur web (blob:) comme en natif : plus de
      // chemin de fichier, donc plus de MissingPluginException sur web.
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) throw Exception('Image illisible');

      final name = picked.name;
      final ext = name.contains('.')
          ? name.split('.').last.toLowerCase()
          : 'jpg';

      await _provider.importAndApplyBytes(bytes, ext: ext);
      _applied = true;
    } catch (e) {
      if (mounted) _snack('Import impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          backgroundColor: AppColors.surfaceElevated,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild à chaque changement d'aperçu.
    final draft = context.watch<WallpaperProvider>().config;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Fond d\'écran'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: AppColors.textPrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GlassSurface(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LabeledSlider(
                        label: 'Floutage',
                        value: draft.blurRadius,
                        max: WallpaperConfig.maxBlur,
                        display: '${draft.blurRadius.round()} dp',
                        enabled: draft.hasImage,
                        onChanged:
                            (v) => _provider.preview(
                              draft.copyWith(blurRadius: v),
                            ),
                      ),
                      _LabeledSlider(
                        label: 'Assombrissement',
                        value: draft.scrim,
                        max: WallpaperConfig.maxScrim,
                        display:
                            '${(draft.scrim / WallpaperConfig.maxScrim * 100).round()} %',
                        enabled: draft.hasImage,
                        onChanged:
                            (v) => _provider.preview(draft.copyWith(scrim: v)),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Flou progressif',
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(color: AppColors.textPrimary),
                                ),
                                Text(
                                  'Flou en haut, net en bas — améliore la lisibilité',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: draft.progressiveBlur,
                            onChanged:
                                draft.hasImage
                                    ? (v) => _provider.preview(
                                      draft.copyWith(progressiveBlur: v),
                                    )
                                    : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _pickImage,
                      icon:
                          _busy
                              ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.image_outlined),
                      label: Text(
                        draft.hasImage
                            ? 'Changer la photo'
                            : 'Choisir une photo',
                      ),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      await _provider.reset();
                      _applied = true;
                      if (mounted) _snack('Fond CRUX par défaut restauré.');
                    },
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    child: const Icon(Icons.restore),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () async {
                  await _provider.apply(_provider.config);
                  _applied = true;
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: const Text('Appliquer'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  final String label;
  final double value;
  final double max;
  final String display;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.display,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: AppColors.textPrimary),
            ),
            Text(
              display,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
        Slider(
          value: value.clamp(0.0, max),
          max: max,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}
