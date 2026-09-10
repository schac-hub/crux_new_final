import '../utils/local_file.dart';

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallpaper_config.dart';

/// Gère la persistance des préférences de fond d'écran CRUX.
///
/// CORRECTIFS :
///   * `_prefs` n'est plus `late` : si `init()` n'a pas encore été appelé,
///     on renvoie la configuration par défaut au lieu de lancer une
///     LateInitializationError qui écran-noircissait l'application ;
///   * les fichiers importés sont nettoyés de façon asynchrone et tolérante
///     aux erreurs (un fichier verrouillé ne fait plus planter l'import) ;
///   * `importImage` conserve l'extension d'origine ;
///   * les accès fichiers passent par des helpers compatibles web (sur
///     navigateur, tout est no-op et le fond par défaut est utilisé).
class WallpaperManager {
  static const String _prefsKey = 'crux_wallpaper_config';
  static const String _folderName = 'wallpaper';

  SharedPreferences? _prefs;

  static final WallpaperManager _instance = WallpaperManager._internal();
  factory WallpaperManager() => _instance;
  WallpaperManager._internal();

  bool get isReady => _prefs != null;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Configuration persistée, ou celle par défaut si rien n'est lisible.
  WallpaperConfig get configOrDefault {
    final prefs = _prefs;
    if (prefs == null) return WallpaperConfig.defaultConfig;

    final json = prefs.getString(_prefsKey);
    if (json == null || json.isEmpty) return WallpaperConfig.defaultConfig;

    try {
      final config = WallpaperConfig.fromJsonString(json);
      // L'image a pu être supprimée par le système : on ne référence jamais
      // un fichier absent (sinon le rendu jette une exception au build).
      // Sur web, localFileExists est toujours false : seule la base64 compte.
      if (config.hasFileImage &&
          !localFileExists(config.imagePath!) &&
          !config.hasBase64Image) {
        return WallpaperConfig.defaultConfig;
      }
      return config;
    } catch (_) {
      return WallpaperConfig.defaultConfig;
    }
  }

  /// Ancien nom conservé pour compatibilité.
  WallpaperConfig get config => configOrDefault;

  Future<String> _wallpaperDirPath() async {
    final base = await getApplicationDocumentsDirectory();
    final path = '${base.path}/$_folderName';
    if (!await localDirExists(path)) {
      await createLocalDir(path);
    }
    return path;
  }

  /// Importe l'image sélectionnée depuis ses octets (XFile.readAsBytes —
  /// fonctionne sur web comme en natif).
  ///
  /// En natif : écrit un fichier stable dans le stockage interne (l'URI du
  /// picker expire en fin de processus) et renvoie son chemin.
  /// Sur web : renvoie null — pas de système de fichiers, l'appelant
  /// persiste alors l'image en base64 dans la configuration.
  Future<String?> importImageBytes(Uint8List bytes, {String ext = 'jpg'}) async {
    if (kIsWeb) return null;

    final dirPath = await _wallpaperDirPath();

    if (ext.length > 5) ext = 'jpg';
    final target =
        '$dirPath/wallpaper_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await writeLocalFileBytes(target, bytes);

    // Nettoyage des anciens fonds pour ne pas remplir le stockage.
    await for (final entityPath in listLocalDirPaths(dirPath)) {
      if (entityPath == target) continue;
      await deleteLocalFile(entityPath);
    }

    return target;
  }

  Future<void> save(WallpaperConfig config) async {
    await init();
    await _prefs!.setString(_prefsKey, config.toJsonString());
  }

  Future<void> reset() async {
    await init();
    if (!kIsWeb) {
      try {
        final dirPath = await _wallpaperDirPath();
        await deleteLocalDir(dirPath);
      } catch (_) {
        // Rien à supprimer.
      }
    }
    await _prefs!.remove(_prefsKey);
  }
}
