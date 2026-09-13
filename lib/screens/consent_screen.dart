import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../theme/colors.dart';
import '../models/user_model.dart';

class ConsentScreen extends StatefulWidget {
  final UserModel user;
  const ConsentScreen({super.key, required this.user});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _termsAccepted = false;
  bool _privacyAccepted = false;
  bool _loading = false;

  Future<void> _onContinue() async {
    if (!_termsAccepted || !_privacyAccepted) return;
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('crux_terms_accepted', true);
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/home', arguments: widget.user);
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark =
        themeProvider.themeMode == ThemeMode.dark ||
        (themeProvider.themeMode == ThemeMode.system &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors:
                isDark
                    ? const [
                      Color(0xFF0F0F1A),
                      Color(0xFF1A1A2E),
                      Color(0xFF16213E),
                    ]
                    : const [
                      Color(0xFFF5F7FA),
                      Color(0xFFEEEEFF),
                      Color(0xFFF8F0FF),
                    ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 24),
                // Logo / App name
                ShaderMask(
                  shaderCallback:
                      (bounds) =>
                          AppColors.primaryGradient.createShader(bounds),
                  blendMode: BlendMode.srcIn,
                  child: const Icon(Icons.video_call_rounded, size: 64),
                ),
                const SizedBox(height: 12),
                ShaderMask(
                  shaderCallback:
                      (bounds) =>
                          AppColors.primaryGradient.createShader(bounds),
                  blendMode: BlendMode.srcIn,
                  child: Text(
                    'CRUX',
                    style: GoogleFonts.poppins(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 4,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Premium Video Conference',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black45,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 40),

                // Terms of Use section
                _ConsentCard(
                  isDark: isDark,
                  title: 'Conditions d\'utilisation',
                  icon: Icons.gavel_rounded,
                  points: const [
                    'Vous devez avoir au moins 13 ans pour utiliser CRUX.',
                    'Les réunions ne peuvent pas être utilisées à des fins illégales ou nuisibles.',
                    'Vous êtes responsable de toute activité sur votre compte.',
                    'CRUX se réserve le droit de suspendre tout compte en violation des règles.',
                  ],
                ),
                const SizedBox(height: 16),

                // Privacy Policy section
                _ConsentCard(
                  isDark: isDark,
                  title: 'Politique de confidentialité',
                  icon: Icons.privacy_tip_rounded,
                  points: const [
                    'Vos données personnelles (email, nom) sont stockées de façon sécurisée.',
                    'Nous ne vendons jamais vos données à des tiers.',
                    'Les enregistrements de réunion restent privés et accessibles uniquement par vous.',
                    'Vous pouvez supprimer votre compte et vos données à tout moment.',
                  ],
                ),
                const SizedBox(height: 32),

                // Checkboxes
                _CheckboxRow(
                  isDark: isDark,
                  value: _termsAccepted,
                  label: 'J\'accepte les Conditions d\'utilisation',
                  onChanged: (v) => setState(() => _termsAccepted = v ?? false),
                ),
                const SizedBox(height: 12),
                _CheckboxRow(
                  isDark: isDark,
                  value: _privacyAccepted,
                  label: 'J\'accepte la Politique de confidentialité',
                  onChanged:
                      (v) => setState(() => _privacyAccepted = v ?? false),
                ),
                const SizedBox(height: 36),

                // Continue button
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: AnimatedOpacity(
                    opacity: (_termsAccepted && _privacyAccepted) ? 1.0 : 0.45,
                    duration: const Duration(milliseconds: 250),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient:
                            (_termsAccepted && _privacyAccepted)
                                ? AppColors.primaryGradient
                                : const LinearGradient(
                                  colors: [Colors.grey, Colors.grey],
                                ),
                        borderRadius: BorderRadius.circular(16),
                        // SANS surbrillance : glow coloré retiré.
                      ),
                      child: ElevatedButton(
                        onPressed:
                            (_termsAccepted && _privacyAccepted && !_loading)
                                ? _onContinue
                                : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child:
                            _loading
                                ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                                : Text(
                                  'Continuer',
                                  style: GoogleFonts.poppins(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConsentCard extends StatelessWidget {
  final bool isDark;
  final String title;
  final IconData icon;
  final List<String> points;

  const _ConsentCard({
    required this.isDark,
    required this.title,
    required this.icon,
    required this.points,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:
            isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color:
              isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.07),
        ),
        boxShadow: [
          BoxShadow(
            color:
                isDark
                    ? Colors.black.withValues(alpha: 0.2)
                    : Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ShaderMask(
                shaderCallback:
                    (bounds) => AppColors.primaryGradient.createShader(bounds),
                blendMode: BlendMode.srcIn,
                child: Icon(icon, size: 22),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...points.map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      p,
                      style: GoogleFonts.poppins(
                        fontSize: 12.5,
                        color: isDark ? Colors.white70 : Colors.black54,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckboxRow extends StatelessWidget {
  final bool isDark;
  final bool value;
  final String label;
  final ValueChanged<bool?> onChanged;

  const _CheckboxRow({
    required this.isDark,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              gradient: value ? AppColors.primaryGradient : null,
              color: value ? null : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color:
                    value
                        ? Colors.transparent
                        : isDark
                        ? Colors.white38
                        : Colors.black26,
                width: 2,
              ),
            ),
            child:
                value
                    ? const Icon(Icons.check, color: Colors.white, size: 16)
                    : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color:
                    isDark
                        ? Colors.white.withValues(alpha: 0.87)
                        : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
