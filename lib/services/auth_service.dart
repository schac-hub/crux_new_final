import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:logger/logger.dart';

import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const [
      'email',
      'https://www.googleapis.com/auth/userinfo.profile',
    ],
  );

  final _logger = Logger();

  static final AuthService _instance = AuthService._internal();

  factory AuthService() => _instance;

  AuthService._internal();

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ===========================================================================
  // EMAIL / PASSWORD — SIGN UP
  // ===========================================================================

  Future<UserModel?> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      _logger.i('📝 Sign up: $email');

      final userCredential =
          await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      final user = userCredential.user;

      if (user == null) {
        throw Exception('User creation failed');
      }

      final cleanName = name.trim();

      if (cleanName.isNotEmpty) {
        await user.updateDisplayName(cleanName);
        await user.reload();
      }

      final refreshedUser = _auth.currentUser ?? user;

      _logger.i('✅ Sign up successful');

      return UserModel(
        uid: refreshedUser.uid,
        email: refreshedUser.email ?? email.trim(),
        name: refreshedUser.displayName ?? cleanName,
      );
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Auth error: ${e.code} — ${e.message}',
      );
      rethrow;
    } catch (e) {
      _logger.e('❌ Sign up failed: $e');
      rethrow;
    }
  }

  // ===========================================================================
  // EMAIL / PASSWORD — SIGN IN
  // ===========================================================================

  Future<UserModel?> signIn({
    required String email,
    required String password,
  }) async {
    try {
      _logger.i('🔑 Sign in: $email');

      final userCredential =
          await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception(
            'Délai de connexion dépassé. '
            'Vérifiez votre connexion internet.',
          );
        },
      );

      final user = userCredential.user;

      if (user == null) {
        throw Exception('Sign in failed');
      }

      _logger.i('✅ Sign in successful');

      return UserModel(
        uid: user.uid,
        email: user.email ?? '',
        name: user.displayName ?? 'User',
      );
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Auth error: ${e.code} — ${e.message}',
      );
      rethrow;
    } catch (e) {
      _logger.e('❌ Sign in failed: $e');
      rethrow;
    }
  }

  // ===========================================================================
  // GOOGLE AUTH
  // ===========================================================================

  Future<UserModel?> _authenticateWithGoogle() async {
    try {
      _logger.i('🔑 Google authentication starting...');

      // -----------------------------------------------------------------------
      // WEB
      //
      // Firebase gère directement le popup Google sur le Web.
      // -----------------------------------------------------------------------

      if (kIsWeb) {
        final googleProvider = GoogleAuthProvider();

        googleProvider.setCustomParameters({
          'prompt': 'select_account',
        });

        final userCredential =
            await _auth.signInWithPopup(
          googleProvider,
        );

        final user = userCredential.user;

        if (user == null) {
          throw Exception(
            'Google authentication returned no user.',
          );
        }

        _logger.i(
          '✅ Google authentication successful on Web',
        );

        return UserModel(
          uid: user.uid,
          email: user.email ?? '',
          name: user.displayName ?? 'User',
        );
      }

      // -----------------------------------------------------------------------
      // ANDROID / IOS / AUTRES PLATEFORMES NATIVES
      // -----------------------------------------------------------------------

      await _googleSignIn.signOut().catchError(
        (_) {},
      );

      final googleUser = await _googleSignIn.signIn().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception(
            'Délai Google Sign-In dépassé. '
            'Vérifiez votre connexion internet.',
          );
        },
      );

      if (googleUser == null) {
        _logger.w(
          '⚠️ Google authentication cancelled',
        );
        return null;
      }

      final googleAuth =
          await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential =
          await _auth.signInWithCredential(
        credential,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception(
            'Délai authentification dépassé. '
            'Vérifiez votre connexion internet.',
          );
        },
      );

      final user = userCredential.user;

      if (user == null) {
        throw Exception(
          'Google sign in failed',
        );
      }

      _logger.i(
        '✅ Google authentication successful on native',
      );

      return UserModel(
        uid: user.uid,
        email: user.email ?? googleUser.email,
        name: user.displayName ??
            googleUser.displayName ??
            'User',
      );
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Google auth error: ${e.code} — ${e.message}',
      );
      rethrow;
    } catch (e) {
      _logger.e(
        '❌ Google sign in failed: $e',
      );
      rethrow;
    }
  }

  // ===========================================================================
  // GOOGLE — SIGN IN
  // ===========================================================================

  Future<UserModel?> signInWithGoogle() async {
    return _authenticateWithGoogle();
  }

  // ===========================================================================
  // GOOGLE — SIGN UP
  //
  // Avec Firebase, le même flux Google crée automatiquement le compte si
  // l'adresse n'existe pas encore.
  // ===========================================================================

  Future<UserModel?> signUpWithGoogle() async {
    return _authenticateWithGoogle();
  }

  // ===========================================================================
  // PASSWORD RESET
  // ===========================================================================

  Future<void> resetPassword(
    String email,
  ) async {
    try {
      _logger.i(
        '🔄 Password reset: $email',
      );

      await _auth.sendPasswordResetEmail(
        email: email.trim(),
      );

      _logger.i(
        '✅ Password reset email sent',
      );
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Reset error: ${e.code}',
      );
      rethrow;
    } catch (e) {
      _logger.e(
        '❌ Password reset failed: $e',
      );
      rethrow;
    }
  }

  // ===========================================================================
  // SIGN OUT
  // ===========================================================================

  Future<void> signOut() async {
    try {
      _logger.i('👋 Signing out...');

      if (!kIsWeb) {
        await _googleSignIn.signOut().catchError(
          (_) {},
        );
      }

      await _auth.signOut();

      _logger.i(
        '✅ Sign out successful',
      );
    } catch (e) {
      _logger.e(
        '⚠️ Sign out error: $e',
      );

      // On conserve le comportement actuel :
      // la déconnexion Firebase doit rester prioritaire.
      try {
        await _auth.signOut();
      } catch (_) {}
    }
  }
}
