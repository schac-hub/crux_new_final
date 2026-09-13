library;
/// Implémentation native (Android/iOS/desktop) de l'export de fichiers.
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Écrit [content] dans le dossier documents de l'app et renvoie son chemin.
Future<String?> exportTextFile(String fileName, String content) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(content, flush: true);
  return file.path;
}

/// Écrit des octets binaires (photo de chat partagée, document) dans le
/// dossier documents et renvoie son chemin.
Future<String?> exportBinaryFile(String fileName, Uint8List bytes) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
