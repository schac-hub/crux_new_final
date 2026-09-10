import '../utils/io_compat.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/colors.dart';
import '../wallpaper/glass_surface.dart';
import 'virtual_background_controller.dart';
import 'virtual_background_mode.dart';

/// Bandeau compact de sélection du fond vidéo virtuel (segmentation MLKit).
/// Affiché entre la grille de participants et la barre de contrôles.
class BackgroundPanel extends StatelessWidget {
  final VirtualBackgroundController controller;

  const BackgroundPanel({super.key, required this.controller});

  Future<void> _pickImage(BuildContext context) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked != null) {
      controller.setMode(VirtualBackgroundImage(File(picked.path)));
    }
  }

  void _showColorPicker(BuildContext context) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Choisir une couleur de fond'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ColorOption(
                    color: Colors.blue,
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundColor(Colors.blue),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _ColorOption(
                    color: Colors.green,
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundColor(Colors.green),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _ColorOption(
                    color: Colors.purple,
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundColor(Colors.purple),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _ColorOption(
                    color: Colors.orange,
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundColor(Colors.orange),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _ColorOption(
                    color: Colors.teal,
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundColor(Colors.teal),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _ColorOption(
                    color: Colors.red,
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundColor(Colors.red),
                      );
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
    );
  }

  void _showGradientPicker(BuildContext context) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Choisir un dégradé'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GradientOption(
                    colors: [Colors.blue, Colors.purple],
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundGradient([
                          Colors.blue,
                          Colors.purple,
                        ]),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _GradientOption(
                    colors: [Colors.green, Colors.teal],
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundGradient([
                          Colors.green,
                          Colors.teal,
                        ]),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _GradientOption(
                    colors: [Colors.orange, Colors.red],
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundGradient([
                          Colors.orange,
                          Colors.red,
                        ]),
                      );
                      Navigator.pop(context);
                    },
                  ),
                  _GradientOption(
                    colors: [Colors.pink, Colors.purple],
                    onTap: () {
                      controller.setMode(
                        const VirtualBackgroundGradient([
                          Colors.pink,
                          Colors.purple,
                        ]),
                      );
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = controller.mode;

    return GlassSurface(
      borderRadius: 16,
      child: SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            _BgOption(
              label: 'Aucun',
              icon: Icons.block,
              selected: mode is VirtualBackgroundNone,
              onTap: () => controller.setMode(const VirtualBackgroundNone()),
            ),
            const SizedBox(width: 8),
            _BgOption(
              label: 'Flou léger',
              icon: Icons.blur_on,
              selected: mode is VirtualBackgroundBlurLight,
              onTap:
                  () => controller.setMode(const VirtualBackgroundBlurLight()),
            ),
            const SizedBox(width: 8),
            _BgOption(
              label: 'Flou moyen',
              icon: Icons.blur_on,
              selected: mode is VirtualBackgroundBlurMedium,
              onTap:
                  () => controller.setMode(const VirtualBackgroundBlurMedium()),
            ),
            const SizedBox(width: 8),
            _BgOption(
              label: 'Flou fort',
              icon: Icons.blur_circular,
              selected: mode is VirtualBackgroundBlurStrong,
              onTap:
                  () => controller.setMode(const VirtualBackgroundBlurStrong()),
            ),
            const SizedBox(width: 8),
            _BgOption(
              label: 'Couleur',
              icon: Icons.format_color_fill,
              selected: mode is VirtualBackgroundColor,
              onTap: () => _showColorPicker(context),
            ),
            const SizedBox(width: 8),
            _BgOption(
              label: 'Dégradé',
              icon: Icons.gradient,
              selected: mode is VirtualBackgroundGradient,
              onTap: () => _showGradientPicker(context),
            ),
            const SizedBox(width: 8),
            _BgOption(
              label: 'Image',
              icon: Icons.image,
              selected: mode is VirtualBackgroundImage,
              onTap: () => _pickImage(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _BgOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _BgOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color:
              selected
                  ? AppColors.primary.withValues(alpha: 0.2)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorOption extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;

  const _ColorOption({required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 2),
        ),
      ),
    );
  }
}

class _GradientOption extends StatelessWidget {
  final List<Color> colors;
  final VoidCallback onTap;

  const _GradientOption({required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 60,
        height: 60,
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 2),
        ),
      ),
    );
  }
}
