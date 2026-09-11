library;
/// Stub web de l'export de fichiers texte.
///
/// Le navigateur n'a pas de système de fichiers : [exportTextFile] lance un
/// téléchargement via un blob + <a download> (package:web, l'API moderne
/// qui remplace dart:html).
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

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
