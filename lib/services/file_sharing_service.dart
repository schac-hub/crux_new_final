import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:logger/logger.dart';

import '../config/app_config.dart';

/// Service de partage de fichiers dans le chat.
///
/// IMPORTANT — aucune dépendance à Firebase Storage (facturable) :
/// • Images et petits documents (≤ [maxInlineBytes]) : les octets sont
///   intégrés en base64 DANS le message de chat Firestore (`fileData`).
///   Coût : simple lecture Firestore du message — aucun service de stockage.
/// • Fichiers plus lourds : upload Cloudinary (plan gratuit) si configuré
///   via `--dart-define=CLOUDINARY_CLOUD_NAME=…` et
///   `--dart-define=CLOUDINARY_UPLOAD_PRESET=…` (preset non signé).
///   Sinon une erreur claire est renvoyée.
class FileSharingService {
  FileSharingService._();

  static final FileSharingService instance = FileSharingService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _logger = Logger();
  final Uuid _uuid = const Uuid();

  // Configuration
  static const int maxFileSize = 50 * 1024 * 1024; // 50 MB
  /// Taille maximale intégrée inline dans un document de chat Firestore
  /// (limite document : 1 Mo ; on garde une marge avec les autres champs).
  static const int maxInlineBytes = 400 * 1024; // 400 KB
  static const List<String> allowedImageExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
  ];
  static const List<String> allowedDocumentExtensions = [
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.txt',
  ];

  /// Cloudinary est-il configuré (via --dart-define) ?
  static bool get isCloudinaryConfigured =>
      AppConfig.cloudinaryCloudName.trim().isNotEmpty &&
      AppConfig.cloudinaryUploadPreset.trim().isNotEmpty;

  Future<void> deleteFile({
    required String meetingId,
    required String fileId,
    String? fileUrl,
  }) async {
    try {
      // Les fichiers inline vivent DANS le message de chat : seule la
      // métadonnée est supprimée. (Cloudinary : purge automatique du plan
      // gratuit, pas de suppression non signée possible côté client.)
      await _firestore
          .collection('meetings')
          .doc(meetingId)
          .collection('files')
          .doc(fileId)
          .delete();

      _logger.i('File deleted successfully: $fileId');
    } catch (e) {
      _logger.e('Error deleting file', error: e);
      rethrow;
    }
  }

  Stream<QuerySnapshot> getMeetingFiles(String meetingId) {
    return _firestore
        .collection('meetings')
        .doc(meetingId)
        .collection('files')
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  /// Partage un fichier depuis ses octets (compatible web + mobile via
  /// file_picker withData : dart:io n'est pas disponible sur le web).
  ///
  /// Retourne les métadonnées à écrire dans le message de chat :
  /// • `fileData` = base64 inline (aucun service de stockage) ;
  /// • ou `fileUrl` = URL Cloudinary pour les fichiers volumineux.
  Future<Map<String, dynamic>> shareFileBytes({
    required String meetingId,
    required String fileName,
    required List<int> bytes,
    required String senderId,
    required String senderName,
  }) async {
    try {
      final fileExtension =
          path.extension(fileName).isNotEmpty
              ? path.extension(fileName).toLowerCase()
              : '.bin';

      final fileSize = bytes.length;
      if (fileSize > maxFileSize) {
        throw Exception('Fichier trop volumineux (limite : 50 Mo).');
      }

      if (!_isFileTypeAllowed(fileExtension)) {
        throw Exception('Type de fichier non autorisé.');
      }

      final base = <String, dynamic>{
        'id': _uuid.v4(),
        'fileName': fileName,
        'fileSize': fileSize,
        'fileType': _getFileType(fileExtension),
        'senderId': senderId,
        'senderName': senderName,
        'meetingId': meetingId,
      };

      // 1) Inline base64 dans le message de chat (gratuit, sans Storage).
      if (fileSize <= maxInlineBytes) {
        _logger.i('File shared inline: $fileName ($fileSize octets)');

        return {
          ...base,
          'fileData': base64Encode(bytes),
          'fileUrl': null,
        };
      }

      // 2) Fichier volumineux → Cloudinary (plan gratuit) si configuré.
      if (isCloudinaryConfigured) {
        final url = await _uploadToCloudinary(
          bytes: Uint8List.fromList(bytes),
          fileName: fileName,
          isImage: _getFileType(fileExtension) == 'image',
        );

        _logger.i('File shared via Cloudinary: $fileName');

        return {...base, 'fileData': null, 'fileUrl': url};
      }

      throw Exception(
        'Fichier trop volumineux pour le partage direct '
        '(max ${(maxInlineBytes / 1024).round()} Ko). '
        'Compressez-le, ou configurez Cloudinary (gratuit) pour les '
        'gros fichiers.',
      );
    } catch (e) {
      _logger.e('Error sharing file', error: e);
      rethrow;
    }
  }

  /// Upload non signé vers Cloudinary (le `upload_preset` autorise les
  /// envois clients sans secret). Gratuit jusqu'à 25 crédits/mois.
  Future<String> _uploadToCloudinary({
    required Uint8List bytes,
    required String fileName,
    required bool isImage,
  }) async {
    final cloud = AppConfig.cloudinaryCloudName.trim();
    final preset = AppConfig.cloudinaryUploadPreset.trim();

    final resourceType = isImage ? 'image' : 'raw';

    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/$cloud/$resourceType/upload',
    );

    final request = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = preset
      ..fields['public_id'] = 'crux_chat/${_uuid.v4()}'
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      );

    final streamed = await request.send().timeout(
      const Duration(seconds: 60),
    );

    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Upload Cloudinary échoué (HTTP ${streamed.statusCode}).');
    }

    final decoded = jsonDecode(body);

    final url = decoded['secure_url']?.toString();

    if (url == null || url.isEmpty) {
      throw Exception('Réponse Cloudinary inattendue.');
    }

    return url;
  }

  bool _isFileTypeAllowed(String extension) {
    return allowedImageExtensions.contains(extension) ||
        allowedDocumentExtensions.contains(extension);
  }

  String _getFileType(String extension) {
    if (allowedImageExtensions.contains(extension)) {
      return 'image';
    } else if (allowedDocumentExtensions.contains(extension)) {
      return 'document';
    }
    return 'other';
  }
}
