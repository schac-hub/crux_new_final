import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';

class CruxAuthProvider extends ChangeNotifier {
  final AuthService _authService = AuthService();

  User? get currentUser => _authService.currentUser;

  bool get isAuthenticated => _authService.isAuthenticated;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _errorMessage;

  // Compatibilité avec les écrans existants de CRUX.
  String? get error => _errorMessage;
  String? get errorMessage => _errorMessage;

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }

  void _setError(String message) {
    _errorMessage = message;
  }

  Future<bool> signUp({
    required String email,
    required String password,
    String? name,
    String? displayName,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      await _authService.signUp(
        email: email,
        password: password,
        displayName: name ?? displayName,
      );

      _setLoading(false);
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _setError(_firebaseErrorMessage(e));
      _setLoading(false);
      notifyListeners();
      return false;
    } catch (e) {
      _setError('Une erreur est survenue : $e');
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      await _authService.signIn(
        email: email,
        password: password,
      );

      _setLoading(false);
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _setError(_firebaseErrorMessage(e));
      _setLoading(false);
      notifyListeners();
      return false;
    } catch (e) {
      _setError('Une erreur est survenue : $e');
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  Future<bool> signInWithGoogle() async {
    _setLoading(true);
    _clearError();

    try {
      final user = await _authService.signInWithGoogle();

      _setLoading(false);
      notifyListeners();

      return user != null;
    } on FirebaseAuthException catch (e) {
      _setError(_firebaseErrorMessage(e));
      _setLoading(false);
      notifyListeners();
      return false;
    } catch (e) {
      _setError('Connexion Google impossible : $e');
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  Future<bool> signUpWithGoogle() async {
    _setLoading(true);
    _clearError();

    try {
      final user = await _authService.signUpWithGoogle();

      _setLoading(false);
      notifyListeners();

      return user != null;
    } on FirebaseAuthException catch (e) {
      _setError(_firebaseErrorMessage(e));
      _setLoading(false);
      notifyListeners();
      return false;
    } catch (e) {
      _setError('Inscription Google impossible : $e');
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    _setLoading(true);
    _clearError();

    try {
      await _authService.signOut();
    } catch (e) {
      _setError('Erreur lors de la déconnexion : $e');
    } finally {
      _setLoading(false);
      notifyListeners();
    }
  }

  Future<bool> resetPassword(String email) async {
    _setLoading(true);
    _clearError();

    try {
      await _authService.resetPassword(email);

      _setLoading(false);
      notifyListeners();

      return true;
    } on FirebaseAuthException catch (e) {
      _setError(_firebaseErrorMessage(e));
      _setLoading(false);
      notifyListeners();
      return false;
    } catch (e) {
      _setError('Impossible d’envoyer le lien : $e');
      _setLoading(false);
      notifyListeners();
      return false;
    }
  }

  String _firebaseErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Adresse e-mail invalide.';

      case 'user-disabled':
        return 'Ce compte a été désactivé.';

      case 'user-not-found':
        return 'Aucun compte ne correspond à cette adresse e-mail.';

      case 'wrong-password':
      case 'invalid-credential':
        return 'E-mail ou mot de passe incorrect.';

      case 'email-already-in-use':
        return 'Cette adresse e-mail est déjà utilisée.';

      case 'weak-password':
        return 'Le mot de passe est trop faible.';

      case 'operation-not-allowed':
        return 'Cette méthode de connexion n’est pas activée.';

      case 'account-exists-with-different-credential':
        return 'Un compte existe déjà avec une autre méthode de connexion.';

      case 'popup-closed-by-user':
        return 'La fenêtre Google a été fermée.';

      case 'popup-blocked':
        return 'La fenêtre Google a été bloquée par le navigateur.';

      case 'cancelled-popup-request':
        return 'La connexion Google a été annulée.';

      case 'network-request-failed':
        return 'Problème de connexion réseau.';

     default:
        return e.message ?? 'Une erreur Firebase est survenue.';
    }
  }
}
