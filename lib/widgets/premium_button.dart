import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/premium_colors.dart';

class PremiumButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  final Color? textColor;
  final IconData? icon;
  final bool isLoading;
  final bool isFullWidth;
  final bool isPrimary;
  final double? width;
  final double? height;
  final EdgeInsets? padding;

  const PremiumButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
    this.textColor,
    this.icon,
    this.isLoading = false,
    this.isFullWidth = true,
    this.isPrimary = true,
    this.width,
    this.height,
    this.padding,
  });

  @override
  State<PremiumButton> createState() => _PremiumButtonState();
}

class _PremiumButtonState extends State<PremiumButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final bgColor =
        widget.backgroundColor ??
        (widget.isPrimary
            ? PremiumColors.flamePrimary
            : PremiumColors.icePrimary);
    final textColor = widget.textColor ?? PremiumColors.snowWhite;

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.isLoading ? null : widget.onPressed,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: widget.width,
          height: widget.height,
          padding:
              widget.padding ??
              const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            gradient:
                _isPressed
                    ? LinearGradient(
                      colors: [bgColor.withValues(alpha: 0.8), bgColor],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                    : LinearGradient(
                      colors: [bgColor, bgColor.withValues(alpha: 0.9)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
            borderRadius: BorderRadius.circular(16),
            // SANS surbrillance : glow coloré (fireGlow inclus) retiré.
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isLoading)
                SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(textColor),
                  ),
                )
              else if (widget.icon != null)
                Icon(widget.icon, color: textColor, size: 20),
              if (widget.icon != null && !widget.isLoading)
                const SizedBox(width: 12),
              Text(
                widget.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final finalWidget =
        widget.isFullWidth
            ? SizedBox(width: double.infinity, child: button)
            : button;

    return finalWidget
        .animate()
        .scale(begin: const Offset(0.98, 0.98), duration: 200.ms)
        .fadeIn();
  }
}
