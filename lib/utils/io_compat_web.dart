library;
/// Stubs web pour les APIs dart:io utilisées par CRUX.
///
/// Le navigateur n'a pas d'accès aux fichiers locaux : les opérations sont
/// des no-ops contrôlés (existsSync → false, copie/suppression ignorées).
/// Les fonctionnalités concernées (photos locales, fonds d'écran fichier,
/// enregistrements locaux) restent actives sur mobile/desktop.
class File {
  final String path;

  File(this.path);

  bool existsSync() => false;

  Future<File> copy(String newPath) async => File(newPath);

  Future<File> create({bool recursive = false}) async => this;

  Future<void> delete() async {}
}

class Directory {
  final String path;

  Directory(this.path);

  bool existsSync() => false;

  Future<Directory> create({bool recursive = false}) async => this;
}

class Platform {
  static bool get isAndroid => false;

  static bool get isIOS => false;

  static bool get isMacOS => false;

  static bool get isWindows => false;

  static bool get isLinux => false;
}
