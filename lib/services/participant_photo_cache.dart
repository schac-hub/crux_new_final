import 'dart:typed_data';

import 'user_service.dart';

/// Cache mémoire des photos de profil résolues par UID Firebase.
///
/// En réunion, l'identité LiveKit d'un participant est son UID Firebase :
/// on peut donc retrouver sa photo dans `users/{uid}.photoBase64` sans
/// alourdir les métadonnées LiveKit. Chaque UID n'est lu qu'une seule fois
/// (le résultat — même « pas de photo » — est mis en cache).
class ParticipantPhotoCache {
  ParticipantPhotoCache._();

  static final _cache = <String, Uint8List?>{};
  static final _inFlight = <String, Future<Uint8List?>>{};

  /// Photo de profil de l'utilisateur [uid], ou null s'il n'en a pas.
  static Future<Uint8List?> photoFor(String uid) {
    if (_cache.containsKey(uid)) {
      return Future.value(_cache[uid]);
    }
    return _inFlight.putIfAbsent(uid, () async {
      Uint8List? bytes;
      try {
        final profile = await UserService.instance.getProfile(uid);
        bytes = UserService.decodePhoto(profile?['photoBase64'] as String?);
      } catch (_) {
        bytes = null;
      }
      _cache[uid] = bytes;
      _inFlight.remove(uid);
      return bytes;
    });
  }

  /// Force une relecture après un changement de photo.
  static void invalidate(String uid) {
    _cache.remove(uid);
  }
}
