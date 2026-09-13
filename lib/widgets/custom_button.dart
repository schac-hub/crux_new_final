import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/colors.dart';

class CustomButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  final Color? textColor;
  final IconData? icon;
  final bool isLoading;
  final bool isFullWidth;
  final EdgeInsets? padding;
  final double? borderRadius;

  const CustomButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
    this.textColor,
    this.icon,
    this.isLoading = false,
    this.isFullWidth = true,
    this.padding,
    this.borderRadius,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.backgroundColor ?? AppColors.primary;
    final textColor = widget.textColor ?? Colors.white;
    final borderRadius = widget.borderRadius ?? 12.0;

    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.isLoading ? null : widget.onPressed,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(
          padding:
              widget.padding ??
              const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          // SANS surbrillance : les glows colorés (BoxShadow) ralentissaient
          // le rendu et étaient explicitement retirés de l'UI.
          decoration: BoxDecoration(
            color:
                widget.isLoading
                    ? bgColor.withValues(alpha: 0.6)
                    : _isPressed
                    ? bgColor.withValues(alpha: 0.8)
                    : bgColor,
            borderRadius: BorderRadius.circular(borderRadius),
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
                const SizedBox(width: 8),
              Text(
                widget.label,
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return widget.isFullWidth
        ? SizedBox(width: double.infinity, child: button)
        : button;
  }
}
