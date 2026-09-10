import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserService {
  UserService._();
  static final UserService instance = UserService._();

  final _db = FirebaseFirestore.instance;
  static const _localPhotoKey = 'crux_local_photo_path';
  static const _cachedPhotoKey = 'crux_photo_b64';

  /// Write name and/or photo to the shared Firestore users collection.
  Future<void> saveProfile({
    required String uid,
    String? name,
    String? photoBase64,
  }) async {
    final data = <String, dynamic>{'updatedAt': FieldValue.serverTimestamp()};
    if (name != null) data['name'] = name;
    if (photoBase64 != null) data['photoBase64'] = photoBase64;
    await _db.collection('users').doc(uid).set(data, SetOptions(merge: true));
  }

  /// Fetch a user's public profile once.
  Future<Map<String, dynamic>?> getProfile(String uid) async {
    try {
      final snap = await _db.collection('users').doc(uid).get();
      return snap.exists ? snap.data() : null;
    } catch (_) {
      return null;
    }
  }

  /// Stream a user's profile for real-time updates
  Stream<Map<String, dynamic>?> streamProfile(String uid) {
    return _db.collection('users').doc(uid).snapshots().map((snap) {
      return snap.exists ? snap.data() : null;
    });
  }

  /// Get the local photo path for the current user
  Future<String?> getLocalPhotoPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_localPhotoKey);
  }

  /// Set the local photo path for the current user
  Future<void> setLocalPhotoPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localPhotoKey, path);
  }

  /// Remove the local photo path
  Future<void> removeLocalPhotoPath() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localPhotoKey);
  }

  /// Cache local de la photo en base64 (SharedPreferences) : affichage
  /// instantané hors-ligne sur web comme en natif, sans système de fichiers.
  Future<String?> getCachedPhotoBase64() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cachedPhotoKey);
  }

  Future<void> setCachedPhotoBase64(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedPhotoKey, value);
  }

  Future<void> clearCachedPhotoBase64() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedPhotoKey);
  }

  /// Decode a base64 photo string to raw bytes (returns null on failure).
  static Uint8List? decodePhoto(String? base64Str) {
    if (base64Str == null || base64Str.isEmpty) return null;
    try {
      final clean =
          base64Str.contains(',') ? base64Str.split(',').last : base64Str;
      return base64Decode(clean);
    } catch (_) {
      return null;
    }
  }
}
