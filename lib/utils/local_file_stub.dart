library;
/// Stubs web des helpers fichiers : le navigateur n'a pas dart:io.
import 'package:flutter/painting.dart';

bool localFileExists(String path) => false;

Future<void> copyLocalFile(String from, String to) async {}

Future<void> deleteLocalFile(String path) async {}

Future<bool> localDirExists(String path) async => false;

Future<void> createLocalDir(String path) async {}

Future<void> deleteLocalDir(String path) async {}

Stream<String> listLocalDirPaths(String dirPath) => const Stream.empty();

/// Pas d'image locale sur web : l'appelant affiche son placeholder.
ImageProvider? localFileImage(String path) => null;

Future<List<int>?> readLocalFileBytes(String path) async => null;
