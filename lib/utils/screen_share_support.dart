library;
/// Détection du support du partage d'écran (getDisplayMedia).
///
/// Safari iOS (iPhone/iPad) n'expose PAS `getDisplayMedia` : le bouton
/// « Partager l'écran » ne doit alors pas s'afficher (au lieu de produire
/// une erreur opaque). Sur natif, la plateforme gère elle-même le support.
export 'screen_share_support_stub.dart'
    if (dart.library.js_interop) 'screen_share_support_web.dart';
