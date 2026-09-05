import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/error_handler_service.dart';
import '../providers/locale_provider.dart';
import '../providers/auth_provider.dart';
import '../l10n/app_translations.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({
    super.key,
  });

  @override
  State<SignUpScreen> createState() =>
      _SignUpScreenState();
}

class _SignUpScreenState
    extends State<SignUpScreen> {
  final _nameController =
      TextEditingController();

  final _emailController =
      TextEditingController();

  final _passwordController =
      TextEditingController();

  final _confirmPasswordController =
      TextEditingController();

  final _errorHandler =
      ErrorHandlerService();

  bool _isLoading = false;
  bool _isGoogleLoading = false;

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

  // ===========================================================================
  // EMAIL SIGN UP
  // ===========================================================================

  Future<void> _signUp() async {
    final lang =
        context
            .read<LocaleProvider>()
            .locale
            .languageCode;

    setState(() {
      _nameError = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
    });

    final name =
        _nameController.text.trim();

    final email =
        _emailController.text.trim();

    final pass =
        _passwordController.text;

    final confirm =
        _confirmPasswordController.text;

    bool hasError = false;

    if (name.isEmpty) {
      setState(() {
        _nameError =
            AppTranslations.t(
          'val_name_required',
          lang,
        );
      });

      hasError = true;
    }

    if (email.isEmpty ||
        !RegExp(
          r'^[^@]+@[^@]+\.[^@]+',
        ).hasMatch(email)) {
      setState(() {
        _emailError =
            AppTranslations.t(
          'val_email_invalid',
          lang,
        );
      });

      hasError = true;
    }

    if (pass.isEmpty ||
        pass.length < 6) {
      setState(() {
        _passwordError =
            AppTranslations.t(
          'val_min_6',
          lang,
        );
      });

      hasError = true;
    }

    if (confirm != pass) {
      setState(() {
        _confirmError =
            AppTranslations.t(
          'val_pwd_mismatch',
          lang,
        );
      });

      hasError = true;
    }

    if (hasError) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final success =
          await context
              .read<CruxAuthProvider>()
              .signUp(
                email: email,
                password: pass,
                name: name,
              );

      if (!success &&
          mounted) {
        final error =
            context
                .read<CruxAuthProvider>()
                .error;

        if (error != null &&
            error.contains(
              'déjà utilisée',
            )) {
          setState(() {
            _emailError =
                AppTranslations.t(
              'auth_email_used',
              lang,
            );
          });
        } else if (error != null) {
          _errorHandler.showError(
            context,
            error,
          );
        }
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) {
        return;
      }

      if (e.code ==
          'email-already-in-use') {
        setState(() {
          _emailError =
              AppTranslations.t(
            'auth_email_used',
            lang,
          );
        });
      } else {
        _errorHandler.showError(
          context,
          e.message ??
              e.code,
        );
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      final msg =
          e.toString()
              .replaceFirst(
        'Exception: ',
        '',
      );

      _errorHandler.showError(
        context,
        msg,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ===========================================================================
  // GOOGLE SIGN UP
  // ===========================================================================

  Future<void> _signUpWithGoogle() async {
    setState(() {
      _isGoogleLoading = true;
      _isLoading = true;
      _nameError = null;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
    });

    try {
      final success =
          await context
              .read<CruxAuthProvider>()
              .signUpWithGoogle();

      if (!success &&
          mounted) {
        final error =
            context
                .read<CruxAuthProvider>()
                .error;

        if (error != null &&
            error.isNotEmpty) {
          _errorHandler.showError(
            context,
            error,
          );
        } else {
          _errorHandler.showError(
            context,
            'Inscription Google annulée.',
          );
        }
      }

      // La navigation reste gérée par AuthWrapper,
      // comme dans le fonctionnement actuel de CRUX.
    } on FirebaseAuthException catch (e) {
      if (!mounted) {
        return;
      }

      String message;

      switch (e.code) {
        case 'popup-closed-by-user':
        case 'cancelled-popup-request':
          message =
              'Inscription Google annulée.';
          break;

        case 'popup-blocked':
          message =
              'La fenêtre Google a été bloquée par le navigateur.';
          break;

        case 'account-exists-with-different-credential':
          message =
              'Cette adresse possède déjà un compte avec une autre méthode de connexion.';
          break;

        case 'operation-not-allowed':
          message =
              'La connexion Google n’est pas activée dans Firebase.';
          break;

        case 'network-request-failed':
          message =
              'Erreur réseau. Vérifiez votre connexion internet.';
          break;

        default:
          message =
              'Inscription Google échouée: ${e.code}';
      }

      _errorHandler.showError(
        context,
        message,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      _errorHandler.showError(
        context,
        'Inscription Google échouée.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleLoading = false;
          _isLoading = false;
        });
      }
    }
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final lang =
        context
            .watch<LocaleProvider>()
            .locale
            .languageCode;

    final busy =
        _isLoading ||
        _isGoogleLoading;

    return Scaffold(
      body: Container(
        decoration:
            const BoxDecoration(
          gradient:
              LinearGradient(
            begin:
                Alignment.topCenter,
            end:
                Alignment.bottomCenter,
            colors: [
              Color(
                0xFF0A0E1A,
              ),
              Color(
                0xFF121624,
              ),
              Color(
                0xFF020205,
              ),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment:
                    Alignment.topLeft,
                child: IconButton(
                  icon:
                      const Icon(
                    Icons
                        .arrow_back_ios_new,
                    color:
                        Colors.white,
                    size: 20,
                  ),
                  onPressed:
                      busy
                          ? null
                          : () =>
                              Navigator.pop(
                                context,
                              ),
                ),
              ),
              Expanded(
                child: Center(
                  child:
                      SingleChildScrollView(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal: 32,
                    ),
                    child:
                        Column(
                      mainAxisAlignment:
                          MainAxisAlignment
                              .center,
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration:
                              BoxDecoration(
                            borderRadius:
                                BorderRadius
                                    .circular(
                              15,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors
                                    .black
                                    .withValues(
                                  alpha:
                                      0.3,
                                ),
                                blurRadius:
                                    12,
                                offset:
                                    const Offset(
                                  0,
                                  6,
                                ),
                              ),
                            ],
                          ),
                          child:
                              ClipRRect(
                            borderRadius:
                                BorderRadius
                                    .circular(
                              15,
                            ),
                            child:
                                Image.asset(
                              'assets/images/icon.png',
                              fit: BoxFit
                                  .cover,
                            ),
                          ),
                        ),
                        const SizedBox(
                          height: 24,
                        ),
                        ShaderMask(
                          shaderCallback:
                              (bounds) =>
                                  const LinearGradient(
                            colors: [
                              Color(
                                0xFF00E5FF,
                              ),
                              Color(
                                0xFF7C5CFF,
                              ),
                            ],
                          ).createShader(
                            bounds,
                          ),
                          child:
                              Text(
                            'CRUX',
                            style:
                                GoogleFonts
                                    .spaceGrotesk(
                              fontSize:
                                  32,
                              fontWeight:
                                  FontWeight
                                      .bold,
                              color:
                                  Colors
                                      .white,
                              letterSpacing:
                                  4,
                            ),
                          ),
                        ),
                        const SizedBox(
                          height: 8,
                        ),
                        Text(
                          AppTranslations
                              .t(
                            'create_account',
                            lang,
                          ).toUpperCase(),
                          style:
                              GoogleFonts
                                  .spaceGrotesk(
                            fontSize: 11,
                            color:
                                const Color(
                              0xFF8A8FA3,
                            ),
                            letterSpacing:
                                2,
                            fontWeight:
                                FontWeight
                                    .w500,
                          ),
                        ),
                        const SizedBox(
                          height: 40,
                        ),
                        _buildTextField(
                          controller:
                              _nameController,
                          hint:
                              AppTranslations
                                  .t(
                            'full_name',
                            lang,
                          ),
                          icon:
                              Icons
                                  .person_outline,
                          errorText:
                              _nameError,
                        ),
                        const SizedBox(
                          height: 16,
                        ),
                        _buildTextField(
                          controller:
                              _emailController,
                          hint:
                              AppTranslations
                                  .t(
                            'email',
                            lang,
                          ),
                          icon:
                              Icons
                                  .email_outlined,
                          errorText:
                              _emailError,
                        ),
                        const SizedBox(
                          height: 16,
                        ),
                        _buildTextField(
                          controller:
                              _passwordController,
                          hint:
                              AppTranslations
                                  .t(
                            'password',
                            lang,
                          ),
                          icon:
                              Icons
                                  .lock_outline,
                          obscure:
                              !_showPassword,
                          errorText:
                              _passwordError,
                          suffix:
                              IconButton(
                            icon:
                                Icon(
                              _showPassword
                                  ? Icons
                                      .visibility
                                  : Icons
                                      .visibility_off,
                              color:
                                  Colors
                                      .white38,
                              size:
                                  20,
                            ),
                            onPressed: () {
                              setState(() {
                                _showPassword =
                                    !_showPassword;
                              });
                            },
                          ),
                        ),
                        const SizedBox(
                          height: 16,
                        ),
                        _buildTextField(
                          controller:
                              _confirmPasswordController,
                          hint:
                              AppTranslations
                                  .t(
                            'confirm_password',
                            lang,
                          ),
                          icon:
                              Icons
                                  .lock_outline,
                          obscure:
                              !_showConfirmPassword,
                          errorText:
                              _confirmError,
                          suffix:
                              IconButton(
                            icon:
                                Icon(
                              _showConfirmPassword
                                  ? Icons
                                      .visibility
                                  : Icons
                                      .visibility_off,
                              color:
                                  Colors
                                      .white38,
                              size:
                                  20,
                            ),
                            onPressed: () {
                              setState(() {
                                _showConfirmPassword =
                                    !_showConfirmPassword;
                              });
                            },
                          ),
                        ),
                        const SizedBox(
                          height: 32,
                        ),
                        _buildPrimaryButton(
                          onPressed:
                              busy
                                  ? null
                                  : _signUp,
                          label:
                              AppTranslations
                                  .t(
                            'signup',
                            lang,
                          ),
                          loading:
                              _isLoading &&
                              !_isGoogleLoading,
                        ),
                        const SizedBox(
                          height: 16,
                        ),
                        Row(
                          children: [
                            const Expanded(
                              child:
                                  Divider(
                                color:
                                    Colors
                                        .white24,
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets
                                      .symmetric(
                                horizontal:
                                    12,
                              ),
                              child:
                                  Text(
                                'ou',
                                style:
                                    GoogleFonts
                                        .spaceGrotesk(
                                  fontSize:
                                      13,
                                  color:
                                      Colors
                                          .white38,
                                ),
                              ),
                            ),
                            const Expanded(
                              child:
                                  Divider(
                                color:
                                    Colors
                                        .white24,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(
                          height: 16,
                        ),
                        SizedBox(
                          width:
                              double.infinity,
                          height: 54,
                          child:
                              OutlinedButton
                                  .icon(
                            onPressed:
                                busy
                                    ? null
                                    : _signUpWithGoogle,
                            icon:
                                _isGoogleLoading
                                    ? const SizedBox(
                                        width:
                                            20,
                                        height:
                                            20,
                                        child:
                                            CircularProgressIndicator(
                                          strokeWidth:
                                              2,
                                          color:
                                              Colors.white,
                                        ),
                                      )
                                    : const Icon(
                                        Icons
                                            .account_circle_outlined,
                                        size:
                                            22,
                                      ),
                            label:
                                const Text(
                              'S’inscrire avec Google',
                              style:
                                  TextStyle(
                                fontWeight:
                                    FontWeight
                                        .w600,
                              ),
                            ),
                            style:
                                OutlinedButton
                                    .styleFrom(
                              foregroundColor:
                                  Colors
                                      .white,
                              side:
                                  BorderSide(
                                color: Colors
                                    .white
                                    .withValues(
                                  alpha:
                                      0.18,
                                ),
                              ),
                              shape:
                                  RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius
                                        .circular(
                                  16,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(
                          height: 32,
                        ),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .center,
                          children: [
                            Text(
                              AppTranslations
                                  .t(
                                'have_account',
                                lang,
                              ),
                              style:
                                  GoogleFonts
                                      .poppins(
                                color:
                                    Colors
                                        .white38,
                                fontSize:
                                    14,
                              ),
                            ),
                            const SizedBox(
                              width: 4,
                            ),
                            GestureDetector(
                              onTap:
                                  busy
                                      ? null
                                      : () =>
                                          Navigator.pop(
                                            context,
                                          ),
                              child:
                                  Text(
                                AppTranslations
                                    .t(
                                  'login',
                                  lang,
                                ),
                                style:
                                    GoogleFonts
                                        .poppins(
                                  color:
                                      Colors
                                          .white,
                                  fontSize:
                                      14,
                                  fontWeight:
                                      FontWeight
                                          .bold,
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

  // ===========================================================================
  // TEXT FIELD
  // ===========================================================================

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
          decoration:
              BoxDecoration(
            color:
                Colors.white
                    .withValues(
              alpha: 0.05,
            ),
            borderRadius:
                BorderRadius.circular(
              16,
            ),
            border:
                Border.all(
              color: errorText != null
                  ? Colors
                      .redAccent
                      .withValues(
                    alpha: 0.5,
                  )
                  : Colors
                      .white
                      .withValues(
                    alpha: 0.1,
                  ),
            ),
          ),
          child: TextField(
            controller:
                controller,
            obscureText:
                obscure,
            style:
                GoogleFonts.poppins(
              color:
                  Colors.white,
              fontSize:
                  15,
            ),
            decoration:
                InputDecoration(
              hintText:
                  hint,
              hintStyle:
                  GoogleFonts
                      .poppins(
                color:
                    Colors
                        .white24,
                fontSize:
                    15,
              ),
              prefixIcon:
                  Icon(
                icon,
                color:
                    Colors
                        .white38,
                size:
                    20,
              ),
              suffixIcon:
                  suffix,
              border:
                  InputBorder
                      .none,
              contentPadding:
                  const EdgeInsets
                      .symmetric(
                horizontal:
                    16,
                vertical:
                    16,
              ),
            ),
          ),
        ),
        if (errorText != null)
          Padding(
            padding:
                const EdgeInsets
                    .only(
              left: 16,
              top: 8,
            ),
            child:
                Text(
              errorText,
              style:
                  GoogleFonts
                      .poppins(
                color:
                    Colors
                        .redAccent,
                fontSize:
                    12,
              ),
            ),
          ),
      ],
    );
  }

  // ===========================================================================
  // PRIMARY BUTTON
  // ===========================================================================

  Widget _buildPrimaryButton({
    required VoidCallback? onPressed,
    required String label,
    bool loading = false,
  }) {
    return SizedBox(
      width:
          double.infinity,
      height: 56,
      child:
          ElevatedButton(
        onPressed:
            onPressed,
        style:
            ElevatedButton.styleFrom(
          backgroundColor:
              Colors.white,
          foregroundColor:
              Colors.black,
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(
              16,
            ),
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
                  color:
                      Colors.black,
                ),
              )
            : Text(
                label.toUpperCase(),
                style:
                    GoogleFonts.poppins(
                  fontWeight:
                      FontWeight
                          .bold,
                  letterSpacing:
                      1.5,
                ),
              ),
      ),
    );
  }
}
