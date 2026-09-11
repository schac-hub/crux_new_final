library;
/// Implémentation native (Android/iOS/desktop) de l'export de fichiers texte.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Écrit [content] dans le dossier documents de l'app et renvoie son chemin.
Future<String?> exportTextFile(String fileName, String content) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(content, flush: true);
  return file.path;
}
