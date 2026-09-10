library;
/// Couche de compatibilité dart:io pour CRUX.
///
/// Le projet est compilé pour Android/iOS ET pour le web. Le web n'expose
/// pas dart:io : chaque fichier qui en a besoin importe cette couche, qui
/// bascule automatiquement vers les vraies APIs (mobile/desktop) ou vers
/// des stubs no-op (web).
export 'io_compat_web.dart' if (dart.library.io) 'io_compat_native.dart';
