library;
/// Export de fichiers texte compatible web + natif.
///
/// Web : téléchargement navigateur (blob + <a download>).
/// Natif : écriture dans le dossier documents de l'application.
export 'download_file_stub.dart' if (dart.library.io) 'download_file_io.dart';
