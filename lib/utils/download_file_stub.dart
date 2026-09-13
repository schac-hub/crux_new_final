library;
/// Stub web de l'export de fichiers texte.
///
/// Le navigateur n'a pas de système de fichiers : [exportTextFile] lance un
/// téléchargement via un blob + <a download> (package:web, l'API moderne
/// qui remplace dart:html).
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Mime type minimal dérivé de l'extension (téléchargement des images et
/// documents partagés dans le chat).
String _mimeFor(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.txt')) return 'text/plain';
  return 'image/jpeg';
}

/// Écrit [content] dans un fichier téléchargeable [fileName].
/// Renvoie null (téléchargement navigateur, pas de chemin disque).
Future<String?> exportTextFile(String fileName, String content) async {
  final bytes = utf8.encode(content);
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return null;
}

/// Télécharge des octets binaires (photo de chat partagée, document).
/// Renvoie null sur web (téléchargement navigateur).
Future<String?> exportBinaryFile(String fileName, Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: _mimeFor(fileName)),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return null;
}
