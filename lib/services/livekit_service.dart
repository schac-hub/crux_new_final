import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Service centralisé LiveKit pour CRUX.
class LiveKitService {
  LiveKitService._();

  static final LiveKitService instance =
      LiveKitService._();

  // ===========================================================================
  // LARGE WEBINAR CONFIGURATION
  // ===========================================================================

  static const int targetCapacity = 10000;

  static const int maxVisibleVideoTiles = 10;

  static const int maxTokenAttempts = 3;

  static const String architectureVersion =
      'large_webinar_10k_v2';

  /// Dernière URL LiveKit retournée par le token server.
  String? _lastServerUrl;

  String? get lastServerUrl =>
      _lastServerUrl;

  // ===========================================================================
  // TOKEN
  // ===========================================================================

  Future<String?> fetchToken({
    required String room,
    required String identity,
    required String name,
    bool isHost = false,
  }) async {
    final cleanRoom =
        room.trim();

    final cleanIdentity =
        identity.trim();

    final cleanName =
        name.trim();

    if (cleanRoom.isEmpty) {
      _error(
        'Room name is empty.',
      );
      return null;
    }

    if (cleanIdentity.isEmpty) {
      _error(
        'Participant identity is empty.',
      );
      return null;
    }

    if (cleanName.isEmpty) {
      _error(
        'Participant name is empty.',
      );
      return null;
    }

    final endpoint =
        AppConfig.livekitTokenEndpoint.trim();

    if (endpoint.isEmpty) {
      _error(
        'LiveKit token endpoint is empty.',
      );
      return null;
    }

    final sandboxId =
        AppConfig.livekitSandboxId.trim();

    if (sandboxId.isEmpty) {
      _error(
        'LiveKit sandbox ID is empty.',
      );
      return null;
    }

    final uri =
        Uri.tryParse(endpoint);

    if (uri == null ||
        !uri.hasScheme) {
      _error(
        'Invalid LiveKit token endpoint: $endpoint',
      );
      return null;
    }

    for (
      var attempt = 1;
      attempt <= maxTokenAttempts;
      attempt++
    ) {
      try {
        developer.log(
          'LiveKit sandbox token request '
          '(attempt=$attempt/$maxTokenAttempts, '
          'room=$cleanRoom, '
          'identity=$cleanIdentity, '
          'role=${isHost ? 'host' : 'audience'})',
          level: 800,
        );

        // ---------------------------------------------------------------------
        // EXACT SANDBOX REQUEST
        // ---------------------------------------------------------------------

        final response = await http
            .post(
              uri,
              headers: {
                'X-Sandbox-ID':
                    sandboxId,
                'Content-Type':
                    'application/json',
                'Accept':
                    'application/json',
              },
              body: jsonEncode(
                {
                  'room_name':
                      cleanRoom,
                  'participant_name':
                      cleanName,
                },
              ),
            )
            .timeout(
          AppConfig.tokenTimeout,
        );

        developer.log(
          'LiveKit token response: '
          '${response.statusCode}',
          level: 800,
        );

        // ---------------------------------------------------------------------
        // HTTP ERROR
        // ---------------------------------------------------------------------

        if (response.statusCode < 200 ||
            response.statusCode >= 300) {
          _error(
            'Token server HTTP '
            '${response.statusCode}: '
            '${_safeResponseBody(response.body)}',
          );

          if (attempt <
              maxTokenAttempts) {
            await _waitBeforeRetry(
              attempt,
            );
            continue;
          }

          return null;
        }

        // ---------------------------------------------------------------------
        // JSON
        // ---------------------------------------------------------------------

        final dynamic decoded =
            jsonDecode(
          response.body,
        );

        if (decoded
            is! Map<String, dynamic>) {
          _error(
            'Invalid LiveKit response format.',
          );

          if (attempt <
              maxTokenAttempts) {
            await _waitBeforeRetry(
              attempt,
            );
            continue;
          }

          return null;
        }

        // ---------------------------------------------------------------------
        // TOKEN
        // ---------------------------------------------------------------------

        final token =
            _extractToken(
          decoded,
        );

        if (token == null ||
            token.isEmpty) {
          _error(
            'LiveKit response does not contain '
            'a participant token.',
          );

          if (attempt <
              maxTokenAttempts) {
            await _waitBeforeRetry(
              attempt,
            );
            continue;
          }

          return null;
        }

        // ---------------------------------------------------------------------
        // SERVER URL
        // ---------------------------------------------------------------------

        final serverUrl =
            _extractServerUrl(
          decoded,
        );

        if (serverUrl != null &&
            serverUrl.isNotEmpty) {
          _lastServerUrl =
              serverUrl;

          AppConfig
              .setLivekitWssUrl(
            serverUrl,
          );
        }

        developer.log(
          'LiveKit credentials received. '
          'serverUrl='
          '${serverUrl ?? AppConfig.livekitWssUrl}',
          level: 800,
        );

        return token;
      } on TimeoutException {
        _error(
          'LiveKit token request timed out '
          'after ${AppConfig.tokenTimeout.inSeconds}s.',
        );

        if (attempt <
            maxTokenAttempts) {
          await _waitBeforeRetry(
            attempt,
          );
          continue;
        }

        return null;
      } on FormatException catch (e) {
        _error(
          'Invalid LiveKit JSON response: $e',
        );

        if (attempt <
            maxTokenAttempts) {
          await _waitBeforeRetry(
            attempt,
          );
          continue;
        }

        return null;
      } on http.ClientException catch (e) {
        _error(
          'LiveKit token HTTP client error: $e',
        );

        if (attempt <
            maxTokenAttempts) {
          await _waitBeforeRetry(
            attempt,
          );
          continue;
        }

        return null;
      } catch (e, stackTrace) {
        developer.log(
          'LiveKit token request failed',
          error: e,
          stackTrace: stackTrace,
          level: 1000,
        );

        if (attempt <
            maxTokenAttempts) {
          await _waitBeforeRetry(
            attempt,
          );
          continue;
        }

        return null;
      }
    }

    return null;
  }

  // ===========================================================================
  // TOKEN EXTRACTION
  // ===========================================================================

  String? _extractToken(
    Map<String, dynamic> data,
  ) {
    final candidates =
        <dynamic>[
      data['participantToken'],
      data['participant_token'],
      data['token'],
      data['accessToken'],
      data['access_token'],
    ];

    final credentials =
        data['credentials'];

    if (credentials is Map) {
      candidates.addAll([
        credentials[
            'participantToken'],
        credentials[
            'participant_token'],
        credentials['token'],
        credentials[
            'accessToken'],
        credentials[
            'access_token'],
      ]);
    }

    final dataField =
        data['data'];

    if (dataField is Map) {
      candidates.addAll([
        dataField[
            'participantToken'],
        dataField[
            'participant_token'],
        dataField['token'],
        dataField[
            'accessToken'],
        dataField[
            'access_token'],
      ]);
    }

    final result =
        data['result'];

    if (result is Map) {
      candidates.addAll([
        result[
            'participantToken'],
        result[
            'participant_token'],
        result['token'],
        result[
            'accessToken'],
        result[
            'access_token'],
      ]);
    }

    for (final value
        in candidates) {
      if (value is String &&
          value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    return null;
  }

  // ===========================================================================
  // SERVER URL EXTRACTION
  // ===========================================================================

  String? _extractServerUrl(
    Map<String, dynamic> data,
  ) {
    final candidates =
        <dynamic>[
      data['serverUrl'],
      data['server_url'],
      data['url'],
      data['livekitUrl'],
      data['livekit_url'],
    ];

    final credentials =
        data['credentials'];

    if (credentials is Map) {
      candidates.addAll([
        credentials[
            'serverUrl'],
        credentials[
            'server_url'],
        credentials['url'],
        credentials[
            'livekitUrl'],
        credentials[
            'livekit_url'],
      ]);
    }

    final dataField =
        data['data'];

    if (dataField is Map) {
      candidates.addAll([
        dataField[
            'serverUrl'],
        dataField[
            'server_url'],
        dataField['url'],
        dataField[
            'livekitUrl'],
        dataField[
            'livekit_url'],
      ]);
    }

    final result =
        data['result'];

    if (result is Map) {
      candidates.addAll([
        result[
            'serverUrl'],
        result[
            'server_url'],
        result['url'],
        result[
            'livekitUrl'],
        result[
            'livekit_url'],
      ]);
    }

    for (final value
        in candidates) {
      if (value is String &&
          value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    return null;
  }

  // ===========================================================================
  // RETRY
  // ===========================================================================

  Future<void> _waitBeforeRetry(
    int attempt,
  ) async {
    final multiplier =
        attempt.clamp(
      1,
      3,
    );

    await Future<void>.delayed(
      AppConfig.retryBackoff *
          multiplier,
    );
  }

  // ===========================================================================
  // SAFE LOGGING
  // ===========================================================================

  String _safeResponseBody(
    String body,
  ) {
    const maxLength = 500;

    if (body.length <= maxLength) {
      return body;
    }

    return '${body.substring(0, maxLength)}...';
  }

  // ===========================================================================
  // ARCHITECTURE
  // ===========================================================================

  String get architectureDescription {
    return '''
CRUX Large Webinar Architecture

Target capacity     : $targetCapacity participants
Visible videos      : $maxVisibleVideoTiles
Transport            : LiveKit SFU

HOST:
  canPublish         : server-controlled

AUDIENCE:
  canPublish         : server-controlled

Architecture:
  10,000 participants
  -> LiveKit SFU
  -> selective subscription
  -> maximum 10 rendered video tiles
''';
  }

  int get maximumParticipants =>
      targetCapacity;

  int get maximumVisibleVideos =>
      maxVisibleVideoTiles;

  bool get isLargeWebinar =>
      targetCapacity >= 3000;

  bool get supportsTenThousandParticipants =>
      targetCapacity >= 10000;

  Map<String, dynamic>
      get diagnostics {
    return {
      'architecture':
          architectureVersion,
      'targetCapacity':
          targetCapacity,
      'maxVisibleVideoTiles':
          maxVisibleVideoTiles,
      'adaptiveStream':
          true,
      'dynacast':
          true,
      'simulcast':
          true,
      'transport':
          'LiveKit SFU',
      'tokenEndpoint':
          AppConfig.livekitTokenEndpoint,
      'sandboxId':
          AppConfig.livekitSandboxId,
      'serverUrl':
          AppConfig.livekitWssUrl,
      'largeWebinar':
          isLargeWebinar,
      'supports10K':
          supportsTenThousandParticipants,
    };
  }

  void _error(
    String message,
  ) {
    developer.log(
      'LiveKitService: $message',
      level: 1000,
    );
  }
}
