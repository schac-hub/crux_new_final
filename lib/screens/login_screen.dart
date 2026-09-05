import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../theme/colors.dart';
import '../utils/logger.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
  });

  @override
  State<LoginScreen> createState() =>
      _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl =
      TextEditingController();

  final _formKey =
      GlobalKey<FormState>();

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();

    _shakeController =
        AnimationController(
      vsync: this,
      duration:
          const Duration(milliseconds: 500),
    );

    _shakeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _shakeController,
        curve: Curves.elasticOut,
      ),
    );
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  void _shakeError(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    setState(() {
      _error = message;
    });

    _shakeController.forward(
      from: 0,
    );

    HapticFeedback.mediumImpact();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!
        .validate()) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final success =
          await context
              .read<CruxAuthProvider>()
              .signIn(
                email:
                    _emailCtrl.text.trim(),
                password:
                    _passwordCtrl.text,
              );

      if (!success &&
          mounted) {
        final providerError =
            context
                .read<CruxAuthProvider>()
                .error;

        _shakeError(
          providerError ??
              'Erreur de connexion. Vérifiez vos identifiants.',
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        _shakeError(
          _friendlyAuthError(
            e.code,
          ),
        );
      }
    } catch (e) {
      logger.e(
        'Login error: $e',
      );

      if (mounted) {
        _shakeError(
          'Erreur de connexion. '
          'Vérifiez votre connexion internet.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final success =
          await context
              .read<CruxAuthProvider>()
              .signInWithGoogle();

      if (!success &&
          mounted) {
        final providerError =
            context
                .read<CruxAuthProvider>()
                .error;

        _shakeError(
          providerError ??
              'Connexion Google annulée.',
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        _shakeError(
          _friendlyAuthError(
            e.code,
          ),
        );
      }
    } catch (e) {
      logger.e(
        'Google sign-in error: $e',
      );

      if (mounted) {
        _shakeError(
          'Connexion Google échouée.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _resetPassword() async {
    final email =
        _emailCtrl.text.trim();

    if (email.isEmpty) {
      _shakeError(
        'Entrez votre email d’abord.',
      );
      return;
    }

    try {
      await AuthService()
          .resetPassword(email);

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              'Email de réinitialisation envoyé à $email',
            ),
            backgroundColor:
                AppColors.surface,
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        _shakeError(
          _friendlyAuthError(
            e.code,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        _shakeError(
          'Impossible d’envoyer '
          'l’email de réinitialisation.',
        );
      }
    }
  }

  String _friendlyAuthError(
    String code,
  ) {
    switch (code) {
      case 'user-not-found':
        return 'Utilisateur non trouvé';

      case 'wrong-password':
      case 'invalid-credential':
        return 'Email ou mot de passe incorrect';

      case 'user-disabled':
        return 'Compte désactivé';

      case 'too-many-requests':
        return 'Trop de tentatives. Réessayez plus tard';

      case 'network-request-failed':
        return 'Erreur réseau. Vérifiez votre connexion';

      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
        return 'Connexion Google annulée';

      case 'popup-blocked':
        return 'La fenêtre Google a été bloquée par le navigateur';

      case 'account-exists-with-different-credential':
        return 'Ce compte existe déjà avec une autre méthode de connexion';

      case 'invalid-email':
        return 'Email invalide';

      case 'operation-not-allowed':
        return 'Méthode de connexion non activée';

      default:
        return 'Erreur d’authentification: $code';
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding:
                const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxWidth: 400,
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .stretch,
                  children: [
                    const SizedBox(
                      height: 16,
                    ),
                    Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration:
                            BoxDecoration(
                          gradient:
                              AppColors
                                  .primaryGradient,
                          borderRadius:
                              BorderRadius
                                  .circular(
                            20,
                          ),
                        ),
                        child:
                            const Icon(
                          Icons
                              .videocam_rounded,
                          color: AppColors
                              .textOnPrimary,
                          size: 36,
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 24,
                    ),
                    Text(
                      'Bienvenue sur CRUX',
                      textAlign:
                          TextAlign.center,
                      style: GoogleFonts
                          .spaceGrotesk(
                        fontSize: 26,
                        fontWeight:
                            FontWeight.w800,
                        color: AppColors
                            .textPrimary,
                      ),
                    ),
                    const SizedBox(
                      height: 6,
                    ),
                    Text(
                      'Connectez-vous pour continuer',
                      textAlign:
                          TextAlign.center,
                      style: GoogleFonts
                          .spaceGrotesk(
                        fontSize: 14,
                        color: AppColors
                            .textSecondary,
                      ),
                    ),
                    const SizedBox(
                      height: 36,
                    ),
                    TextFormField(
                      controller:
                          _emailCtrl,
                      keyboardType:
                          TextInputType
                              .emailAddress,
                      textInputAction:
                          TextInputAction
                              .next,
                      autocorrect: false,
                      style: GoogleFonts
                          .spaceGrotesk(
                        fontSize: 15,
                        color: AppColors
                            .textPrimary,
                      ),
                      decoration:
                          const InputDecoration(
                        labelText:
                            'Adresse email',
                        prefixIcon:
                            Icon(
                          Icons
                              .email_outlined,
                        ),
                      ),
                      validator: (v) {
                        if (v == null ||
                            v.trim()
                                .isEmpty) {
                          return 'Email requis';
                        }

                        if (!RegExp(
                          r'^[^@]+@[^@]+\.[^@]+',
                        ).hasMatch(
                          v.trim(),
                        )) {
                          return 'Email invalide';
                        }

                        return null;
                      },
                    ),
                    const SizedBox(
                      height: 12,
                    ),
                    TextFormField(
                      controller:
                          _passwordCtrl,
                      obscureText:
                          _obscurePassword,
                      textInputAction:
                          TextInputAction
                              .done,
                      onFieldSubmitted:
                          (_) => _signIn(),
                      style: GoogleFonts
                          .spaceGrotesk(
                        fontSize: 15,
                        color: AppColors
                            .textPrimary,
                      ),
                      decoration:
                          InputDecoration(
                        labelText:
                            'Mot de passe',
                        prefixIcon:
                            const Icon(
                          Icons
                              .lock_outline_rounded,
                        ),
                        suffixIcon:
                            IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons
                                    .visibility_outlined
                                : Icons
                                    .visibility_off_outlined,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscurePassword =
                                  !_obscurePassword;
                            });
                          },
                        ),
                      ),
                      validator: (v) {
                        if (v == null ||
                            v.isEmpty) {
                          return 'Mot de passe requis';
                        }

                        if (v.length <
                            6) {
                          return 'Minimum 6 caractères';
                        }

                        return null;
                      },
                    ),
                    Align(
                      alignment:
                          Alignment.centerRight,
                      child:
                          TextButton(
                        onPressed:
                            _loading
                                ? null
                                : _resetPassword,
                        child: Text(
                          'Mot de passe oublié ?',
                          style: GoogleFonts
                              .spaceGrotesk(
                            fontSize: 13,
                            color: AppColors
                                .primary,
                          ),
                        ),
                      ),
                    ),
                    if (_error != null)
                      AnimatedBuilder(
                        animation:
                            _shakeAnimation,
                        builder:
                            (_, child) {
                          return Transform
                              .translate(
                            offset:
                                Offset(
                              8 *
                                  (0.5 -
                                          _shakeAnimation
                                              .value)
                                      .abs() *
                                  (1 -
                                      _shakeAnimation
                                          .value),
                              0,
                            ),
                            child:
                                child,
                          );
                        },
                        child:
                            Container(
                          margin:
                              const EdgeInsets.only(
                            bottom: 8,
                          ),
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration:
                              BoxDecoration(
                            color: AppColors
                                .errorSurface,
                            borderRadius:
                                BorderRadius
                                    .circular(
                              10,
                            ),
                            border:
                                Border.all(
                              color:
                                  AppColors
                                      .error
                                      .withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                          child:
                              Row(
                            children: [
                              const Icon(
                                Icons
                                    .warning_amber_rounded,
                                color: AppColors
                                    .error,
                                size: 16,
                              ),
                              const SizedBox(
                                width: 8,
                              ),
                              Expanded(
                                child:
                                    Text(
                                  _error!,
                                  style: GoogleFonts
                                      .spaceGrotesk(
                                    fontSize:
                                        13,
                                    color:
                                        AppColors.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(
                      height: 4,
                    ),
                    ElevatedButton(
                      onPressed:
                          _loading
                              ? null
                              : _signIn,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(
                                color: AppColors
                                    .textOnPrimary,
                                strokeWidth:
                                    2.5,
                              ),
                            )
                          : const Text(
                              'Se connecter',
                            ),
                    ),
                    const SizedBox(
                      height: 16,
                    ),
                    Row(
                      children: [
                        const Expanded(
                          child: Divider(
                            color:
                                AppColors
                                    .divider,
                          ),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 12,
                          ),
                          child: Text(
                            'ou',
                            style: GoogleFonts
                                .spaceGrotesk(
                              fontSize: 13,
                              color: AppColors
                                  .textTertiary,
                            ),
                          ),
                        ),
                        const Expanded(
                          child: Divider(
                            color:
                                AppColors
                                    .divider,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 16,
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _loading
                              ? null
                              : _signInWithGoogle,
                      icon: const Icon(
                        Icons
                            .account_circle_outlined,
                        size: 21,
                      ),
                      label: const Text(
                        'Continuer avec Google',
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
                          'Pas encore de compte ? ',
                          style: GoogleFonts
                              .spaceGrotesk(
                            fontSize: 14,
                            color: AppColors
                                .textSecondary,
                          ),
                        ),
                        TextButton(
                          onPressed:
                              _loading
                                  ? null
                                  : () =>
                                      Navigator.pushReplacementNamed(
                                        context,
                                        '/signup',
                                      ),
                          style:
                              TextButton.styleFrom(
                            padding:
                                EdgeInsets.zero,
                            minimumSize:
                                Size.zero,
                            tapTargetSize:
                                MaterialTapTargetSize
                                    .shrinkWrap,
                          ),
                          child:
                              Text(
                            'Créer un compte',
                            style:
                                GoogleFonts
                                    .spaceGrotesk(
                              fontSize: 14,
                              fontWeight:
                                  FontWeight
                                      .w700,
                              color: AppColors
                                  .primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: 16,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
