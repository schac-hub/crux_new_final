import 'package:flutter/material.dart';

/// CRUX — palette unique « Obsidian Mono ».
/// Fonds obsidienne, accent blanc/argent. Vert / rouge / cyan = information uniquement.
class AppColors {
  AppColors._();

  // ── Obsidienne ────────────────────────────────────────────────────────
  // Allégées « légèrement » : le noir #05070A était trop profond à l'écran
  // (app + web) — on garde l'esprit obsidienne avec plus de respiration.
  static const Color _black = Color(0xFF10141B);
  static const Color _charcoal = Color(0xFF171C25);
  static const Color _darkGray2 = Color(0xFF1C212A);
  static const Color _darkGray3 = Color(0xFF232936);
  static const Color _darkGray4 = Color(0xFF282E3A);
  static const Color _darkGray5 = Color(0xFF2E3441);

  // ── Argent / blanc ────────────────────────────────────────────────────
  static const Color _white = Color(0xFFF7F8FA);
  static const Color _lightGray = Color(0xFFD8DCE3);
  static const Color _mediumGray = Color(0xFF8B929E);
  static const Color _gray = Color(0xFF6B7280);

  // ── Accents fonctionnels (information uniquement) ─────────────────────
  static const Color _cyan = Color(0xFF0099BB);
  static const Color _green = Color(0xFF00AA55);
  static const Color _red = Color(0xFFBB3333);
  static const Color _orange = Color(0xFFDD7722);
  static const Color _amber = Color(0xFFCCAA33);

  static const Color cyan = _cyan;
  static const Color green = _green;
  static const Color red = _red;
  static const Color orange = _orange;
  static const Color amber = _amber;

  static const Color primary = _white;
  static const Color primaryLight = Color(0xFFFFFFFF);
  static const Color primaryDark = _lightGray;
  static const Color secondary = _mediumGray;
  static const Color tertiary = _gray;

  static const Color background = _black;
  static const Color surface = _charcoal;
  static const Color surfaceVariant = _darkGray2;
  static const Color surfaceElevated = _darkGray3;
  static const Color cardBackground = _darkGray4;
  static const Color cardBackgroundAlt = _darkGray5;

  static const Color textPrimary = _white;
  static const Color textSecondary = _mediumGray;
  static const Color textTertiary = _gray;
  static const Color textDisabled = Color(0xFF3A414C);
  static const Color textOnPrimary = _black;

  static const Color border = Color(0xFF282F3B);
  static const Color borderSubtle = Color(0xFF1D242E);
  static const Color borderFocused = Color(0xFF4A5058);
  static const Color divider = Color(0xFF1D242E);

  static const Color success = _green;
  static const Color successSurface = Color(0xFF0A1A0F);
  static const Color error = _red;
  static const Color errorSurface = Color(0xFF1A0A0A);
  static const Color warning = _orange;
  static const Color warningSurface = Color(0xFF1A1410);
  static const Color info = _lightGray;
  static const Color infoSurface = Color(0xFF0F1214);

  static const Color micActive = _green;
  static const Color micMuted = _red;
  static const Color cameraActive = _green;
  static const Color cameraOff = _mediumGray;
  static const Color screenShareActive = _cyan;
  static const Color recordingActive = _red;
  static const Color handRaised = _amber;
  static const Color liveDot = _cyan;

  static const Color networkExcellent = _green;
  static const Color networkGood = _amber;
  static const Color networkPoor = _orange;
  static const Color networkCritical = _red;

  static const Color proBadge = _lightGray;
  static const Color proBadgeSurface = Color(0xFF0F1419);

  static const double radiusCard = 16;
  static const double radiusField = 14;
  static const double radiusButton = 18;

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_white, _lightGray],
  );

  static const LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [_charcoal, _black],
  );

  static const RadialGradient logoHalo = RadialGradient(
    colors: [Color(0x14D8DCE3), Color(0x00FFFFFF)],
    radius: 0.75,
  );

  static const LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_darkGray4, _darkGray3],
  );

  static const LinearGradient glassGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x08F7F8FA), Color(0x02F7F8FA)],
  );

  static const LinearGradient dangerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFBB3333), Color(0xFF440000)],
  );

  static const LinearGradient liveGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_cyan, Color(0xFF006688)],
  );

  static Color overlayLight = _white.withValues(alpha: 0.03);
  static Color overlayMedium = _white.withValues(alpha: 0.06);
  static Color overlayStrong = _white.withValues(alpha: 0.10);
  static Color scrim = _black.withValues(alpha: 0.85);

  static List<BoxShadow> get softShadow => [
    BoxShadow(
      color: _black.withValues(alpha: 0.6),
      blurRadius: 20,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> get glowShadow => [
    BoxShadow(
      color: _white.withValues(alpha: 0.04),
      blurRadius: 24,
      spreadRadius: -4,
    ),
  ];

  static Color primaryWithOpacity(double opacity) =>
      _white.withValues(alpha: opacity);
  static Color whiteWithOpacity(double opacity) =>
      _white.withValues(alpha: opacity);
  static Color errorWithOpacity(double opacity) =>
      _red.withValues(alpha: opacity);
  static Color liveWithOpacity(double opacity) =>
      _cyan.withValues(alpha: opacity);
}
