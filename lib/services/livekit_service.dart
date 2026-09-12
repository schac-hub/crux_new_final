import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

import '../config/app_config.dart';

/// Résultat complet de la demande de connexion LiveKit
class ConnectionDetails {
  final String serverUrl;
  final String participantToken;
  final String roomName;
  final String participantName;
  final DateTime? expiresAt;

  ConnectionDetails({
    required this.serverUrl,
    required this.participantToken,
    required this.roomName,
    required this.participantName,
    this.expiresAt,
  });
}

/// Service centralisé LiveKit pour CRUX.
///
/// Utilise l'API LiveKit Sandbox pour obtenir les tokens de connexion.
///
/// Flow:
/// 1. FirebaseAuth.currentUser.uid comme identité
/// 2. POST https://cloud-api.livekit.io/api/sandbox/connection-details
/// 3. Header: X-Sandbox-ID: crux-6l6num
/// 4. Body: { "room_name": "meetingId", "participant_name": "Firebase UID" }
/// 5. Response: { "serverUrl": "...", "participantToken": "...", "roomName": "...", "participantName": "..." }
class LiveKitService {
  LiveKitService._();

  static final LiveKitService instance = LiveKitService._();

  // ===========================================================================
  // CONFIGURATION
  // ===========================================================================

  /// Nombre maximum de tentatives pour obtenir un token.
  static const int maxTokenAttempts = 3;

  /// Durée de validité du token sandbox (environ 15 minutes)
  static const Duration tokenValidity = Duration(minutes: 15);

  /// Dernier échec détaillé (remonté à l'écran de réunion pour le diagnostic
  /// « impossible de rejoindre » : quota Cloud, HTTP, réseau…).
  String? lastError;

  // ---------------------------------------------------------------------------
  // CACHE DE TOKEN
  // Les tokens sandbox sont valides ~15 minutes. Re-demander un token à chaque
  // (re)connexion sature le quota de requêtes du sandbox (HTTP 429 → « impossible
  // de rejoindre »). On réutilise donc le token courant tant qu'il est valide.
  // ---------------------------------------------------------------------------

  ConnectionDetails? _cachedDetails;

  String? _cachedKey;

  // ===========================================================================
  // OBTENIR LES DÉTAILS DE CONNEXION
  // ===========================================================================

  /// Récupère les détails de connexion LiveKit auprès du sandbox API.
  ///
  /// Utilise l'API LiveKit Sandbox pour obtenir serverUrl et participantToken.
  ///
  /// [room] - ID de la réunion (meetingId)
  /// [identity] - Identité du participant (doit être le Firebase UID)
  /// [name] - Nom d'affichage du participant
  ///
  /// Retourne ConnectionDetails avec serverUrl et participantToken
  Future<ConnectionDetails?> fetchConnectionDetails({
    required String room,
    required String identity,
    required String name,
  }) async {
    final cleanRoom = room.trim();
    final cleanIdentity = identity.trim();
    final cleanName = name.trim();

    // -------------------------------------------------------------------------
    // VALIDATION
    // -------------------------------------------------------------------------

    if (cleanRoom.isEmpty) {
      _error('Room name is empty.');
      return null;
    }

    if (cleanIdentity.isEmpty) {
      _error('Participant identity is empty.');
      return null;
    }

    // Never allow a caller supplied identity to differ from the authenticated
    // Firebase identity.  The sandbox uses this value as the LiveKit identity.
    final firebaseIdentity = getFirebaseIdentity();
    if (firebaseIdentity == null || firebaseIdentity != cleanIdentity) {
      _error('Participant identity must match the authenticated Firebase UID.');
      return null;
    }

    if (cleanName.isEmpty) {
      _error('Participant name is empty.');
      return null;
    }

    final endpoint = AppConfig.livekitTokenEndpoint.trim();

    if (endpoint.isEmpty) {
      _error('LiveKit token endpoint is empty.');
      return null;
    }

    // Chaque nouvelle demande repart d'un diagnostic vierge.
    lastError = null;

    // Token encore valide pour ce couple room/identité → réutilisation
    // (marge de 2 minutes avant expiration).
    final cacheKey = '$cleanRoom|$cleanIdentity';
    final cached = _cachedDetails;
    if (_cachedKey == cacheKey && cached != null) {
      final expiresAt = cached.expiresAt;
      final stillValid =
          expiresAt == null ||
          expiresAt.isAfter(
            DateTime.now().add(const Duration(minutes: 2)),
          );
      if (stillValid) {
        developer.log(
          'LiveKit token cache hit (room=$cleanRoom)',
          level: 800,
        );
        return cached;
      }
    }

    final uri = Uri.tryParse(endpoint);

    if (uri == null || !uri.hasScheme) {
      _error('Invalid LiveKit token endpoint: $endpoint');
      return null;
    }

    final sandboxId = AppConfig.livekitSandboxId.trim();

    if (sandboxId.isEmpty) {
      _error('LiveKit Sandbox ID is empty.');
      return null;
    }

    // -------------------------------------------------------------------------
    // RETRY
    // -------------------------------------------------------------------------

    for (var attempt = 1; attempt <= maxTokenAttempts; attempt++) {
      try {
        developer.log(
          'LiveKit sandbox API request '
          '(attempt=$attempt/$maxTokenAttempts, '
          'room=$cleanRoom, '
          'identity=$cleanIdentity, '
          'sandbox=$sandboxId)',
          level: 800,
        );

        final headers = <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-Sandbox-ID': sandboxId,
        };

        final requestBody = jsonEncode({
          'room_name': cleanRoom,
          'participant_name': cleanIdentity,
          // Le nom d'affichage voyage dans les métadonnées du token : les
          // tuiles l'affichent dès la connexion (sinon « Anonymous »).
          'metadata': jsonEncode({'name': cleanName}),
        });

        final response = await http
            .post(uri, headers: headers, body: requestBody)
            .timeout(AppConfig.tokenTimeout);

        developer.log(
          'LiveKit sandbox API response: ${response.statusCode}',
          level: 800,
        );

        // ---------------------------------------------------------------------
        // HTTP ERROR
        // ---------------------------------------------------------------------

        if (response.statusCode < 200 || response.statusCode >= 300) {
          _error(
            'Sandbox API HTTP ${response.statusCode}: ${_safeResponseBody(response.body)}',
          );

          final retryable =
              response.statusCode == 408 ||
              response.statusCode == 429 ||
              response.statusCode >= 500;
          if (retryable && attempt < maxTokenAttempts) {
            await _waitBeforeRetry(attempt);
            continue;
          }

          return null;
        }

        // ---------------------------------------------------------------------
        // JSON
        // ---------------------------------------------------------------------

        final dynamic decoded = jsonDecode(response.body);

        if (decoded is! Map<String, dynamic>) {
          _error('Invalid LiveKit sandbox response format.');

          if (attempt < maxTokenAttempts) {
            await _waitBeforeRetry(attempt);
            continue;
          }

          return null;
        }

        // ---------------------------------------------------------------------
        // EXTRACTION DES CHAMPS
        // ---------------------------------------------------------------------

        // The sandbox has returned both camelCase and snake_case payloads
        // across API versions. Accept either without weakening validation.
        final payload =
            decoded['data'] is Map<String, dynamic>
                ? decoded['data'] as Map<String, dynamic>
                : decoded;
        String? value(String camel, String snake) {
          final candidate = payload[camel] ?? payload[snake];
          return candidate is String ? candidate : null;
        }

        final serverUrl = value('serverUrl', 'server_url');
        final participantToken = value('participantToken', 'participant_token');
        final roomName = value('roomName', 'room_name');
        final participantName = value('participantName', 'participant_name');

        if (serverUrl == null || serverUrl.isEmpty) {
          _error('LiveKit response does not contain serverUrl.');

          if (attempt < maxTokenAttempts) {
            await _waitBeforeRetry(attempt);
            continue;
          }

          return null;
        }

        if (participantToken == null || participantToken.isEmpty) {
          _error('LiveKit response does not contain participantToken.');

          if (attempt < maxTokenAttempts) {
            await _waitBeforeRetry(attempt);
            continue;
          }

          return null;
        }

        developer.log(
          'LiveKit connection details received. '
          'serverUrl=$serverUrl, '
          'roomName=$roomName, '
          'participantName=$participantName',
          level: 800,
        );

        DateTime? expiresAt;
        final expiresIn = payload['expiresIn'] ?? payload['expires_in'];
        if (expiresIn is num) {
          expiresAt = DateTime.now().add(Duration(seconds: expiresIn.toInt()));
        }

        // Le token sandbox ne renvoie pas toujours expiresIn : on retombe
        // sur la validité documentée (~15 minutes).
        expiresAt ??= DateTime.now().add(tokenValidity);

        final details = ConnectionDetails(
          serverUrl: serverUrl,
          participantToken: participantToken,
          roomName: roomName ?? cleanRoom,
          participantName: participantName ?? cleanName,
          expiresAt: expiresAt,
        );

        _cachedDetails = details;

        _cachedKey = cacheKey;

        return details;
      } on TimeoutException {
        _error(
          'LiveKit sandbox API request timed out after ${AppConfig.tokenTimeout.inSeconds}s.',
        );

        if (attempt < maxTokenAttempts) {
          await _waitBeforeRetry(attempt);
          continue;
        }

        return null;
      } on FormatException catch (e) {
        _error('Invalid LiveKit JSON response: $e');

        if (attempt < maxTokenAttempts) {
          await _waitBeforeRetry(attempt);
          continue;
        }

        return null;
      } on http.ClientException catch (e) {
        _error('LiveKit sandbox API HTTP client error: $e');

        if (attempt < maxTokenAttempts) {
          await _waitBeforeRetry(attempt);
          continue;
        }

        return null;
      } catch (e, stackTrace) {
        developer.log(
          'LiveKit sandbox API request failed',
          error: e,
          stackTrace: stackTrace,
          level: 1000,
        );

        if (attempt < maxTokenAttempts) {
          await _waitBeforeRetry(attempt);
          continue;
        }

        return null;
      }
    }

    return null;
  }

  // ===========================================================================
  // OBTENIR L'IDENTITÉ FIREBASE
  // ===========================================================================

  /// Récupère l'identité Firebase actuelle pour LiveKit.
  ///
  /// Utilise toujours le vrai UID Firebase comme identité LiveKit.
  String? getFirebaseIdentity() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _error('No Firebase user authenticated.');
      return null;
    }

    final uid = user.uid;
    if (uid.isEmpty) {
      _error('Firebase UID is empty.');
      return null;
    }

    return uid;
  }

  // ===========================================================================
  // RETRY BACKOFF
  // ===========================================================================

  Future<void> _waitBeforeRetry(int attempt) async {
    final multiplier = attempt.clamp(1, 3);

    await Future<void>.delayed(AppConfig.retryBackoff * multiplier);
  }

  // ===========================================================================
  // SAFE LOGGING
  // ===========================================================================

  /// Évite d'envoyer un body potentiellement énorme dans les logs.
  String _safeResponseBody(String body) {
    const maxLength = 500;

    if (body.length <= maxLength) {
      return body;
    }

    return '${body.substring(0, maxLength)}...';
  }

  // ===========================================================================
  // LOGGING
  // ===========================================================================

  void _error(String message) {
    lastError = message;

    developer.log('LiveKitService: $message', level: 1000);
  }
}
