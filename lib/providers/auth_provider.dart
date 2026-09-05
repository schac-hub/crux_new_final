import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../models/user_model.dart';
import '../services/auth_service.dart';

class CruxAuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final _logger = Logger();

  UserModel? _currentUser;
  bool _isLoading = false;
  String? _error;
  bool _isLoggedIn = false;

  StreamSubscription? _authSub;

  UserModel? get currentUser => _currentUser;

  bool get isLoading => _isLoading;

  String? get error => _error;

  bool get isLoggedIn => _isLoggedIn;

  CruxAuthProvider() {
    _authSub = _authService.authStateChanges.listen(
      (user) {
        if (user != null) {
          _currentUser = UserModel(
            uid: user.uid,
            email: user.email ?? '',
            name: user.displayName ?? 'Utilisateur',
          );

          _isLoggedIn = true;
        } else {
          _currentUser = null;
          _isLoggedIn = false;
        }

        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  // ===========================================================================
  // SIGN UP
  // ===========================================================================

  Future<bool> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      _setLoading(true);
      _clearError();

      final user = await _authService.signUp(
        email: email,
        password: password,
        name: name,
      );

      if (user != null) {
        _currentUser = user;
        _isLoggedIn = true;

        _logger.i(
          '✅ Inscription réussie',
        );

        notifyListeners();

        return true;
      }

      _setError(
        'Impossible de créer le compte.',
      );

      return false;
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Erreur inscription: ${e.code}',
      );

      _setError(
        _firebaseErrorMessage(e.code),
      );

      return false;
    } catch (e) {
      _logger.e(
        '❌ Erreur inscription: $e',
      );

      _setError(
        'Erreur inscription: $e',
      );

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // ===========================================================================
  // SIGN IN
  // ===========================================================================

  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    try {
      _setLoading(true);
      _clearError();

      final user = await _authService.signIn(
        email: email,
        password: password,
      );

      if (user != null) {
        _currentUser = user;
        _isLoggedIn = true;

        _logger.i(
          '✅ Connexion réussie',
        );

        notifyListeners();

        return true;
      }

      _setError(
        'Utilisateur non trouvé',
      );

      return false;
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Erreur connexion: ${e.code}',
      );

      _setError(
        _firebaseErrorMessage(e.code),
      );

      return false;
    } catch (e) {
      _logger.e(
        '❌ Erreur connexion: $e',
      );

      _setError(
        'Erreur connexion: $e',
      );

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // ===========================================================================
  // GOOGLE — SIGN IN
  // ===========================================================================

  Future<bool> signInWithGoogle() async {
    try {
      _setLoading(true);
      _clearError();

      final user =
          await _authService.signInWithGoogle();

      if (user != null) {
        _currentUser = user;
        _isLoggedIn = true;

        _logger.i(
          '✅ Connexion Google réussie',
        );

        notifyListeners();

        return true;
      }

      return false;
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Google auth error: ${e.code}',
      );

      _setError(
        _firebaseErrorMessage(e.code),
      );

      return false;
    } catch (e) {
      _logger.e(
        '❌ Connexion Google échouée: $e',
      );

      _setError(
        'Connexion Google échouée: $e',
      );

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // ===========================================================================
  // GOOGLE — SIGN UP
  // ===========================================================================

  Future<bool> signUpWithGoogle() async {
    try {
      _setLoading(true);
      _clearError();

      final user =
          await _authService.signUpWithGoogle();

      if (user != null) {
        _currentUser = user;
        _isLoggedIn = true;

        _logger.i(
          '✅ Inscription Google réussie',
        );

        notifyListeners();

        return true;
      }

      return false;
    } on FirebaseAuthException catch (e) {
      _logger.e(
        '❌ Google signup error: ${e.code}',
      );

      _setError(
        _firebaseErrorMessage(e.code),
      );

      return false;
    } catch (e) {
      _logger.e(
        '❌ Inscription Google échouée: $e',
      );

      _setError(
        'Inscription Google échouée: $e',
      );

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // ===========================================================================
  // SIGN OUT
  // ===========================================================================

  Future<void> signOut() async {
    try {
      _setLoading(true);
      _clearError();

      await _authService.signOut();

      _currentUser = null;
      _isLoggedIn = false;

      _logger.i(
        '✅ Déconnexion réussie',
      );

      notifyListeners();
    } catch (e) {
      _setError(
        'Erreur déconnexion: $e',
      );
    } finally {
      _setLoading(false);
    }
  }

  // ===========================================================================
  // PASSWORD RESET
  // ===========================================================================

  Future<bool> resetPassword(
    String email,
  ) async {
    try {
      _setLoading(true);
      _clearError();

      await _authService.resetPassword(email);

      notifyListeners();

      return true;
    } catch (e) {
      _setError(
        'Erreur réinitialisation: $e',
      );

      return false;
    } finally {
      _setLoading(false);
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  void _setLoading(
    bool value,
  ) {
    _isLoading = value;
    notifyListeners();
  }

  void _setError(
    String error,
  ) {
    _error = error;
    notifyListeners();
  }

  void _clearError() {
    _error = null;
  }

  String _firebaseErrorMessage(
    String code,
  ) {
    switch (code) {
      case 'email-already-in-use':
        return 'Cette adresse email est déjà utilisée.';

      case 'invalid-email':
        return 'Adresse email invalide.';

      case 'weak-password':
        return 'Le mot de passe est trop faible.';

      case 'user-not-found':
        return 'Utilisateur non trouvé.';

      case 'wrong-password':
      case 'invalid-credential':
        return 'Email ou mot de passe incorrect.';

      case 'user-disabled':
        return 'Ce compte est désactivé.';

      case 'too-many-requests':
        return 'Trop de tentatives. Réessayez plus tard.';

      case 'network-request-failed':
        return 'Erreur réseau. Vérifiez votre connexion.';

      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
        return 'Connexion Google annulée.';

      case 'popup-blocked':
        return 'Le navigateur a bloqué la fenêtre Google.';

      case 'account-exists-with-different-credential':
        return 'Un compte existe déjà avec une autre méthode de connexion.';

      case 'operation-not-allowed':
        return 'Cette méthode de connexion n’est pas activée.';

      default:
        return 'Erreur d’authentification: $code';
    }
  }
}
