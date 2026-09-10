import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:logger/logger.dart';

/// Service de partage de fichiers dans le chat.
///
/// Ce service permet aux participants de partager des fichiers
/// (images, documents, etc.) dans le chat de la réunion.
class FileSharingService {
  FileSharingService._();

  static final FileSharingService instance = FileSharingService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final _logger = Logger();
  final Uuid _uuid = const Uuid();

  // Configuration
  static const int maxFileSize = 50 * 1024 * 1024; // 50 MB
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

  Future<void> deleteFile({
    required String meetingId,
    required String fileId,
    required String fileUrl,
  }) async {
    try {
      // Delete from Firestore
      await _firestore
          .collection('meetings')
          .doc(meetingId)
          .collection('files')
          .doc(fileId)
          .delete();

      // Delete from Firebase Storage
      final ref = _storage.refFromURL(fileUrl);
      await ref.delete();

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
  /// Upload vers Firebase Storage puis métadonnées dans Firestore
  /// (meetings/{id}/files), consommées par le chat de la réunion.
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
      final storedName = '${_uuid.v4()}$fileExtension';

      final fileSize = bytes.length;
      if (fileSize > maxFileSize) {
        throw Exception('File size exceeds 50MB limit');
      }

      if (!_isFileTypeAllowed(fileExtension)) {
        throw Exception('File type not allowed');
      }

      // Upload to Firebase Storage
      final ref = _storage.ref().child('meetings/$meetingId/files/$storedName');
      final snapshot = await ref.putData(Uint8List.fromList(bytes));
      final downloadUrl = await snapshot.ref.getDownloadURL();

      // Save metadata to Firestore
      final fileData = {
        'id': _uuid.v4(),
        'fileName': fileName,
        'fileUrl': downloadUrl,
        'fileSize': fileSize,
        'fileType': _getFileType(fileExtension),
        'senderId': senderId,
        'senderName': senderName,
        'timestamp': FieldValue.serverTimestamp(),
        'meetingId': meetingId,
      };

      await _firestore
          .collection('meetings')
          .doc(meetingId)
          .collection('files')
          .add(fileData);

      _logger.i('File shared successfully: $fileName');
      return fileData;
    } catch (e) {
      _logger.e('Error sharing file', error: e);
      rethrow;
    }
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
