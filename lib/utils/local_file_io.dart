library;
/// Implémentation native (Android/iOS/desktop) des helpers fichiers.
import 'dart:io';

import 'package:flutter/painting.dart';

bool localFileExists(String path) => File(path).existsSync();

Future<void> copyLocalFile(String from, String to) async {
  await File(from).copy(to);
}

Future<void> deleteLocalFile(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Fichier verrouillé ou absent : sans gravité.
  }
}

Future<bool> localDirExists(String path) async => Directory(path).exists();

Future<void> createLocalDir(String path) async {
  await Directory(path).create(recursive: true);
}

Future<void> deleteLocalDir(String path) async {
  try {
    await Directory(path).delete(recursive: true);
  } catch (_) {
    // Rien à supprimer.
  }
}

Stream<String> listLocalDirPaths(String dirPath) {
  return Directory(dirPath).list().map((entity) => entity.path);
}

/// Provider d'image locale ; null si le fichier est absent.
ImageProvider? localFileImage(String path) {
  if (!File(path).existsSync()) return null;

  return FileImage(File(path));
}

Future<List<int>?> readLocalFileBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}
