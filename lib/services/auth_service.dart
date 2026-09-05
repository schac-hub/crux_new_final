import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const <String>[
      'email',
      'profile',
    ],
  );

  User? get currentUser => _auth.currentUser;

  bool get isAuthenticated => currentUser != null;

  Future<User?> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    final user = credential.user;

    if (user != null &&
        displayName != null &&
        displayName.trim().isNotEmpty) {
      await user.updateDisplayName(displayName.trim());
      await user.reload();
    }

    return _auth.currentUser;
  }

  Future<User?> signIn({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    return credential.user;
  }

  Future<User?> signInWithGoogle() async {
    return _authenticateWithGoogle();
  }

  Future<User?> signUpWithGoogle() async {
    return _authenticateWithGoogle();
  }

  Future<User?> _authenticateWithGoogle() async {
    if (kIsWeb) {
      final GoogleAuthProvider googleProvider = GoogleAuthProvider();

      googleProvider.setCustomParameters(
        <String, String>{
          'prompt': 'select_account',
        },
      );

      final UserCredential credential =
          await _auth.signInWithPopup(googleProvider);

      return credential.user;
    }

    GoogleSignInAccount? googleUser;

    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Une erreur locale Google ne doit pas empêcher la connexion.
    }

    googleUser = await _googleSignIn.signIn();

    if (googleUser == null) {
      return null;
    }

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;

    final OAuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final UserCredential userCredential =
        await _auth.signInWithCredential(credential);

    return userCredential.user;
  }

  Future<void> signOut() async {
    if (!kIsWeb) {
      try {
        await _googleSignIn.signOut();
      } catch (_) {
        // Une erreur locale Google ne doit pas bloquer Firebase.
      }
    }

    await _auth.signOut();
  }

  Future<void> resetPassword(String email) async {
    await _auth.sendPasswordResetEmail(
      email: email.trim(),
    );
  }

  Future<void> updateDisplayName(String displayName) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Aucun utilisateur connecté.',
      );
    }

    await user.updateDisplayName(displayName.trim());
    await user.reload();
  }

  Future<void> updatePhotoUrl(String photoUrl) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Aucun utilisateur connecté.',
      );
    }

    await user.updatePhotoURL(photoUrl.trim());
    await user.reload();
  }

  Future<void> updateEmail(String email) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Aucun utilisateur connecté.',
      );
    }

    await user.verifyBeforeUpdateEmail(email.trim());
  }

  Future<void> updatePassword(String password) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Aucun utilisateur connecté.',
      );
    }

    await user.updatePassword(password);
  }

  Future<void> deleteAccount() async {
    final user = _auth.currentUser;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Aucun utilisateur connecté.',
      );
    }

    await user.delete();
  }

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Stream<User?> get userChanges => _auth.userChanges();

    Future<void> reloadUser() async {
    await _auth.currentUser?.reload();
  }
}
