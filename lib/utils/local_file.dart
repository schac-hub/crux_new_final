library;
/// Helpers fichiers locaux compatibles web + mobile.
///
/// Sur le web, le navigateur n'expose pas dart:io : les opérations locales
/// deviennent des no-ops et les images locales renvoient null (placeholder).
export 'local_file_stub.dart' if (dart.library.io) 'local_file_io.dart';
