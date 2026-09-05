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

  static const String appVersion = '2.38.1';

  // ===========================================================================
  // LIVEKIT
  // ===========================================================================

  /// URL LiveKit par défaut.
  ///
  /// Le serveur sandbox peut toutefois retourner l'URL LiveKit réellement
  /// associée au sandbox. Celle-ci est alors utilisée dynamiquement.
  static const String livekitDefaultWssUrl = String.fromEnvironment(
    'LIVEKIT_WSS_URL',
    defaultValue: 'wss://crux-88fihb12.livekit.cloud',
  );

  static String _runtimeLivekitWssUrl = livekitDefaultWssUrl;

  /// URL WebSocket LiveKit réellement utilisée par l'application.
  static String get livekitWssUrl => _runtimeLivekitWssUrl;

  /// Permet au LiveKitService d'utiliser le serverUrl retourné par le sandbox.
  static void setLivekitWssUrl(String? serverUrl) {
    final value = serverUrl?.trim();

    if (value == null || value.isEmpty) {
      _runtimeLivekitWssUrl = livekitDefaultWssUrl;
      return;
    }

    _runtimeLivekitWssUrl = value;
  }

  /// Endpoint officiel du token server sandbox LiveKit.
  static const String livekitTokenEndpoint = String.fromEnvironment(
    'LIVEKIT_TOKEN_SERVER_URL',
    defaultValue:
        'https://cloud-api.livekit.io/api/sandbox/connection-details',
  );

  /// Identifiant du sandbox LiveKit.
  static const String livekitSandboxId = String.fromEnvironment(
    'LIVEKIT_SANDBOX_ID',
    defaultValue: 'crux-6l6num',
  );

  // ===========================================================================
  // LARGE CONFERENCE / WEBINAR
  // ===========================================================================

  static const int webinarMinimumParticipants = 10000;

  static const int maxParticipantsLarge = 8000;

  static const int maxVisibleVideoTiles = 10;

  static const int livekitVisibleTileCap = 10;

  static const int maxStageParticipants = 10;

  static const int maxLocalChatMessages = 200;

  // ===========================================================================
  // STANDARD / AUTRES MODES
  // ===========================================================================

  static const int maxParticipantsStandard = 1000;

  // ===========================================================================
  // TIMEOUTS
  // ===========================================================================

  static const Duration tokenTimeout = Duration(
    seconds: 30,
  );

  static const Duration roomConnectionTimeout = Duration(
    seconds: 45,
  );

  static const Duration reconnectDelay = Duration(
    seconds: 5,
  );

  static const Duration retryBackoff = Duration(
    seconds: 2,
  );

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
        livekitTokenEndpoint.startsWith('http') &&
        livekitSandboxId.isNotEmpty;
  }

  static String get configDiagnostics {
    return '''
CRUX LiveKit configuration

WSS:
$livekitWssUrl

Default WSS:
$livekitDefaultWssUrl

Token endpoint:
$livekitTokenEndpoint

Sandbox ID:
$livekitSandboxId

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
