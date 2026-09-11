import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:logger/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'https://www.googleapis.com/auth/userinfo.profile'],
  );
  final _logger = Logger();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static final AuthService _instance = AuthService._internal();

  factory AuthService() => _instance;

  AuthService._internal();

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserModel?> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      _logger.i('Sign up: $email');

      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      final user = userCredential.user;
      if (user == null) throw Exception('User creation failed');

      await user.updateDisplayName(name.trim());
      await user.reload();

      // Create/update Firestore user profile (non-blocking on auth flow)
      _updateFirestoreProfile(user.uid, name.trim(), user.email).catchError((e) {
        _logger.w('Firestore profile creation failed (non-blocking): $e');
      });

      _logger.i('Sign up successful');

      return UserModel(uid: user.uid, email: email.trim(), name: name.trim());
    } on FirebaseAuthException catch (e) {
      _logger.e('Auth error: ${e.code} — ${e.message}');
      rethrow;
    } catch (e) {
      _logger.e('Sign up failed: $e');
      rethrow;
    }
  }

  Future<UserModel?> signIn({
    required String email,
    required String password,
  }) async {
    try {
      _logger.i('Sign in: $email');

      final userCredential = await _auth
          .signInWithEmailAndPassword(email: email.trim(), password: password)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              throw Exception(
                'Délai de connexion dépassé. Vérifiez votre connexion internet.',
              );
            },
          );

      final user = userCredential.user;
      if (user == null) throw Exception('Sign in failed');

      // Update Firestore profile without blocking auth
      _updateFirestoreProfile(
        user.uid,
        user.displayName,
        user.email,
      ).catchError((e) {
        _logger.w('Firestore profile update failed (non-blocking): $e');
      });

      _logger.i('Sign in successful');

      return UserModel(
        uid: user.uid,
        email: user.email ?? '',
        name: user.displayName ?? 'User',
      );
    } on FirebaseAuthException catch (e) {
      _logger.e('Auth error: ${e.code} — ${e.message}');
      rethrow;
    } catch (e) {
      _logger.e('Sign in failed: $e');
      rethrow;
    }
  }

  /// CORRIGÉ (bug #6) : branche Web vs Mobile.
  /// Web : FirebaseAuth.signInWithPopup(GoogleAuthProvider())
  /// Mobile : GoogleSignIn → credential → signInWithCredential()
  Future<UserModel?> signInWithGoogle() async {
    try {
      _logger.i('Google Sign In...');

      User? user;

      if (kIsWeb) {
        // ── WEB : popup directe via Firebase Auth ──────────────────────
        final provider = GoogleAuthProvider()
          ..addScope('email')
          ..addScope('https://www.googleapis.com/auth/userinfo.profile')
          ..setCustomParameters({'prompt': 'select_account'});

        try {
          final cred = await _auth
              .signInWithPopup(provider)
              .timeout(const Duration(seconds: 30));
          user = cred.user;
        } on FirebaseAuthException catch (e) {
          // Popup bloquée par le navigateur ou environnement restreint :
          // on retente via redirection pleine page.
          if (e.code == 'popup-blocked' ||
              e.code == 'popup-closed-by-user' ||
              e.code == 'operation-not-supported-in-this-environment' ||
              e.code == 'cancelled-popup-request') {
            rethrow;
          }
          // Domaine non autorisé (ex. GitHub Pages non déclaré dans la
          // Firebase Console) : message explicite plutôt qu'une erreur brute.
          if (e.code == 'auth/unauthorized-domain' ||
              e.code == 'unauthorized-domain') {
            throw Exception(
              'Ce domaine n\'est pas autorisé dans Firebase. Ajoutez-le dans '
              'Authentication → Settings → Authorized domains.',
            );
          }
          rethrow;
        } on TimeoutException {
          // Popup trop lente : redirection complète en dernier recours.
          await _auth.signInWithRedirect(provider);
          return null; // Le résultat arrive après le rechargement de page.
        }
      } else {
        // ── ANDROID / iOS : GoogleSignIn → credential ─────────────────
        final googleUser = await _googleSignIn.signIn().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw Exception(
              'Délai Google Sign-In dépassé. Vérifiez votre connexion internet.',
            );
          },
        );
        if (googleUser == null) {
          _logger.w('Google sign in cancelled');
          return null;
        }

        final googleAuth = await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );

        final cred = await _auth
            .signInWithCredential(credential)
            .timeout(const Duration(seconds: 15));
        user = cred.user;
      }

      if (user == null) throw Exception('Google sign in failed');

      // Update Firestore profile without blocking auth
      _updateFirestoreProfile(
        user.uid,
        user.displayName,
        user.email,
      ).catchError((e) {
        _logger.w('Firestore profile update failed (non-blocking): $e');
      });

      _logger.i('Google sign in successful');

      return UserModel(
        uid: user.uid,
        email: user.email ?? '',
        name: user.displayName ?? 'User',
      );
    } on FirebaseAuthException catch (e) {
      _logger.e('Google auth error: ${e.code} — ${e.message}');
      rethrow;
    } catch (e) {
      _logger.e('Google sign in failed: $e');
      rethrow;
    }
  }

  Future<void> resetPassword(String email) async {
    try {
      _logger.i('Password reset: $email');
      await _auth.sendPasswordResetEmail(email: email.trim());
      _logger.i('Password reset email sent');
    } on FirebaseAuthException catch (e) {
      _logger.e('Reset error: ${e.code}');
      rethrow;
    } catch (e) {
      _logger.e('Password reset failed: $e');
      rethrow;
    }
  }

  /// Helper method to update Firestore user profile (non-blocking)
  Future<void> _updateFirestoreProfile(
    String uid,
    String? name,
    String? email,
  ) async {
    try {
      if (uid.isEmpty) return;

      final data = <String, dynamic>{'updatedAt': FieldValue.serverTimestamp()};

      if (name != null && name.trim().isNotEmpty) {
        data['name'] = name.trim();
      }

      if (email != null && email.trim().isNotEmpty) {
        data['email'] = email.trim();
      }

      // NOTE: isPro n'est jamais écrit ici — c'est volontaire.
      // La règle Firestore users/{uid} CREATE interdit isPro==true,
      // et UPDATE bloque toute modification isPro par l'utilisateur.
      await _firestore
          .collection('users')
          .doc(uid)
          .set(data, SetOptions(merge: true));
      _logger.i('Firestore profile updated for user: $uid');
    } catch (e) {
      _logger.w('Failed to update Firestore profile: $e');
      // Don't throw - this is non-blocking
    }
  }

  Future<void> signOut() async {
    try {
      _logger.i('Signing out...');
      await Future.wait([
        _googleSignIn.signOut().then((_) => null, onError: (_) => null),
        _auth.signOut(),
      ]);
      _logger.i('Sign out successful');
    } catch (e) {
      _logger.e('Sign out error: $e');
      // Local sign out should always succeed
    }
  }
}
