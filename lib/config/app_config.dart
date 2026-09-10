import 'package:flutter/foundation.dart';

class AppConfig {
  AppConfig._();

  // ===========================================================================
  // APPLICATION
  // ===========================================================================

  static const String firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'crux-3c6be',
  );

  static const String appBaseUrl = String.fromEnvironment(
    'APP_BASE_URL',
    defaultValue: 'https://crux-3c6be.web.app',
  );

  static const String appVersion = '2.39.0';

  // ===========================================================================
  // LIVEKIT
  // ===========================================================================

  /// URL WebSocket LiveKit Cloud.
  ///
  /// IMPORTANT :
  /// Cette valeur ne doit PAS être le endpoint HTTP du token server.
  /// Elle sera obtenue dynamiquement depuis la réponse du sandbox API.
  static const String livekitWssUrl = String.fromEnvironment(
    'LIVEKIT_WSS_URL',
    defaultValue: 'wss://crux-6l6num.sandbox.livekit.io',
  );

  /// LiveKit Sandbox ID pour l'API cloud-api.livekit.io
  static const String livekitSandboxId = String.fromEnvironment(
    'LIVEKIT_SANDBOX_ID',
    defaultValue: 'crux-6l6num',
  );

  /// Endpoint HTTP/HTTPS du serveur qui génère les tokens LiveKit.
  ///
  /// Utilise l'API LiveKit Sandbox pour obtenir serverUrl et participantToken
  static const String livekitTokenEndpoint = String.fromEnvironment(
    'LIVEKIT_TOKEN_SERVER_URL',
    defaultValue: String.fromEnvironment(
      'LIVEKIT_TOKEN_ENDPOINT',
      defaultValue:
          'https://cloud-api.livekit.io/api/sandbox/connection-details',
    ),
  );

  // ===========================================================================
  // LARGE CONFERENCE / WEBINAR
  // ===========================================================================

  /// Objectif d'audience CRUX.
  ///
  /// Cette constante représente la capacité visée par l'architecture
  /// applicative. La capacité réelle dépend du cluster LiveKit utilisé.
  static const int webinarMinimumParticipants = 10000;

  /// Capacité maximale cible configurée côté application.
  static const int maxParticipantsLarge = 8000;

  /// Nombre de vidéos réellement rendues simultanément.
  ///
  /// Même avec 5 000 participants dans la room, le navigateur ne doit
  /// jamais essayer d'afficher 5 000 flux vidéo.
  static const int maxVisibleVideoTiles = 10;

  /// Alias conservé pour les autres écrans CRUX.
  static const int livekitVisibleTileCap = 10;

  /// Nombre maximum de personnes considérées comme speakers/stage.
  static const int maxStageParticipants = 10;

  /// Nombre de messages conservés localement.
  static const int maxLocalChatMessages = 200;

  // ===========================================================================
  // STANDARD / AUTRES MODES
  // ===========================================================================

  static const int maxParticipantsStandard = 1000;

  // ===========================================================================
  // TIMEOUTS
  // ===========================================================================

  static const Duration tokenTimeout = Duration(seconds: 30);

  static const Duration roomConnectionTimeout = Duration(seconds: 45);

  static const Duration reconnectDelay = Duration(seconds: 5);

  static const Duration retryBackoff = Duration(seconds: 2);

  static const int maxReconnectAttempts = 8;

  // ===========================================================================
  // FREE
  // ===========================================================================

  static const int freeMeetingDurationMinutes = 45;

  // ===========================================================================
  // FIRESTORE
  // ===========================================================================

  static const String meetingsCollection = 'meetings';

  static const String usersCollection = 'users';

  static const String messagesCollection = 'messages';

  // ===========================================================================
  // LINKS
  // ===========================================================================

  static const String deepLinkScheme = 'crux';

  static const String deepLinkHost = 'join';

  static String deepLink(String meetingId) {
    return '$deepLinkScheme://$deepLinkHost/$meetingId';
  }

  static String webJoinLink(String meetingId) {
    return '$appBaseUrl/join/$meetingId';
  }

  static String? parseMeetingId(String link) {
    final uri = Uri.tryParse(link.trim());

    if (uri == null) {
      return null;
    }

    if (uri.scheme == deepLinkScheme) {
      if (uri.pathSegments.isEmpty) {
        return null;
      }

      return uri.pathSegments.last;
    }

    if (uri.pathSegments.isEmpty) {
      return null;
    }

    return uri.pathSegments.last;
  }

  // ===========================================================================
  // DIAGNOSTICS
  // ===========================================================================

  static bool get isLiveKitConfigured {
    return livekitWssUrl.startsWith('wss://') &&
        livekitTokenEndpoint.startsWith('http');
  }

  static String get configDiagnostics {
    return '''
CRUX LiveKit configuration

WSS:
$livekitWssUrl

Token endpoint:
$livekitTokenEndpoint

Webinar target:
$webinarMinimumParticipants

Large room target:
$maxParticipantsLarge

Visible video tiles:
$maxVisibleVideoTiles

Stage participants:
$maxStageParticipants
''';
  }

  static void printDiagnostics() {
    if (!kDebugMode) {
      return;
    }

    debugPrint(configDiagnostics);
  }
}
