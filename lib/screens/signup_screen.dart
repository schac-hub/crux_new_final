import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../services/error_handler_service.dart';
import '../providers/locale_provider.dart';
import '../providers/auth_provider.dart';
import '../l10n/app_translations.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() =>
      _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController =
      TextEditingController();

  final _errorHandler = ErrorHandlerService();

  bool _isLoading = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;

  String? _nameError;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final lang =
        context.read<LocaleProvider>().locale.languageCode;

    setState(() {
      _nameError = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
    });

    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final pass = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    bool hasError = false;

    if (name.isEmpty) {
      setState(() {
        _nameError = AppTranslations.t(
          'val_name_required',
          lang,
        );
      });
      hasError = true;
    }

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _emailError = AppTranslations.t(
          'val_email_invalid',
          lang,
        );
      });
      hasError = true;
    }

    if (pass.isEmpty || pass.length < 6) {
      setState(() {
        _passwordError = AppTranslations.t(
          'val_min_6',
          lang,
        );
      });
      hasError = true;
    }

    if (confirm != pass) {
      setState(() {
        _confirmError = AppTranslations.t(
          'val_pwd_mismatch',
          lang,
        );
      });
      hasError = true;
    }

    if (hasError) return;

    setState(() => _isLoading = true);

    try {
      final success =
          await Provider.of<CruxAuthProvider>(
        context,
        listen: false,
      ).signUp(
        email: email,
        password: pass,
        name: name,
      );

      if (mounted && success) {
        // Navigation handled by AuthWrapper in main.dart.
      }
    } catch (e) {
      if (!mounted) return;

      final msg =
          e.toString().replaceFirst(
                'Exception: ',
                '',
              );

      if (msg.contains('email-already-in-use')) {
        setState(() {
          _emailError = AppTranslations.t(
            'auth_email_used',
            lang,
          );
        });
      } else {
        _errorHandler.showError(
          context,
          msg,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang =
        context.watch<LocaleProvider>().locale.languageCode;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0A0E1A),
              Color(0xFF121624),
              Color(0xFF020205),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () =>
                      Navigator.pop(context),
                ),
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 32,
                    ),
                    child: Column(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(15),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: 0.3),
                                blurRadius: 12,
                                offset:
                                    const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius:
                                BorderRadius.circular(15),
                            child: Image.asset(
                              'assets/images/icon.png',
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        ShaderMask(
                          shaderCallback: (bounds) =>
                              const LinearGradient(
                            colors: [
                              Color(0xFF00E5FF),
                              Color(0xFF7C5CFF),
                            ],
                          ).createShader(bounds),
                          child: Text(
                            'CRUX',
                            style:
                                GoogleFonts.spaceGrotesk(
                              fontSize: 32,
                              fontWeight:
                                  FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppTranslations.t(
                            'create_account',
                            lang,
                          ).toUpperCase(),
                          style:
                              GoogleFonts.spaceGrotesk(
                            fontSize: 11,
                            color:
                                const Color(0xFF8A8FA3),
                            letterSpacing: 2,
                            fontWeight:
                                FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 40),
                        _buildTextField(
                          controller:
                              _nameController,
                          hint: AppTranslations.t(
                            'full_name',
                            lang,
                          ),
                          icon:
                              Icons.person_outline,
                          errorText:
                              _nameError,
                        ),
                        const SizedBox(height: 16),
                        _buildTextField(
                          controller:
                              _emailController,
                          hint: AppTranslations.t(
                            'email',
                            lang,
                          ),
                          icon:
                              Icons.email_outlined,
                          errorText:
                              _emailError,
                        ),
                        const SizedBox(height: 16),
                        _buildTextField(
                          controller:
                              _passwordController,
                          hint: AppTranslations.t(
                            'password',
                            lang,
                          ),
                          icon:
                              Icons.lock_outline,
                          obscure:
                              !_showPassword,
                          errorText:
                              _passwordError,
                          suffix: IconButton(
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              color: Colors.white38,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() {
                                _showPassword =
                                    !_showPassword;
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildTextField(
                          controller:
                              _confirmPasswordController,
                          hint: AppTranslations.t(
                            'confirm_password',
                            lang,
                          ),
                          icon:
                              Icons.lock_outline,
                          obscure:
                              !_showConfirmPassword,
                          errorText:
                              _confirmError,
                          suffix: IconButton(
                            icon: Icon(
                              _showConfirmPassword
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                              color: Colors.white38,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() {
                                _showConfirmPassword =
                                    !_showConfirmPassword;
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 40),
                        _buildPrimaryButton(
                          onPressed: _isLoading
                              ? null
                              : _signUp,
                          label: AppTranslations.t(
                            'signup',
                            lang,
                          ),
                          loading: _isLoading,
                        ),
                        const SizedBox(height: 32),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Text(
                              AppTranslations.t(
                                'have_account',
                                lang,
                              ),
                              style:
                                  GoogleFonts.poppins(
                                color:
                                    Colors.white38,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () =>
                                  Navigator.pop(
                                context,
                              ),
                              child: Text(
                                AppTranslations.t(
                                  'login',
                                  lang,
                                ),
                                style:
                                    GoogleFonts.poppins(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight:
                                      FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    String? errorText,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(
              alpha: 0.05,
            ),
            borderRadius:
                BorderRadius.circular(16),
            border: Border.all(
              color: errorText != null
                  ? Colors.redAccent.withValues(
                      alpha: 0.5,
                    )
                  : Colors.white.withValues(
                      alpha: 0.1,
                    ),
            ),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscure,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 15,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.poppins(
                color: Colors.white24,
                fontSize: 15,
              ),
              prefixIcon: Icon(
                icon,
                color: Colors.white38,
                size: 20,
              ),
              suffixIcon: suffix,
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
            ),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(
              left: 16,
              top: 8,
            ),
            child: Text(
              errorText,
              style: GoogleFonts.poppins(
                color: Colors.redAccent,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPrimaryButton({
    required VoidCallback? onPressed,
    required String label,
    bool loading = false,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child:
                    CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : Text(
                label.toUpperCase(),
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
      ),
    );
  }
}
