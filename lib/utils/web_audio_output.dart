library;
/// Pilotage de la sortie audio des pistes distantes sur WEB.
///
/// Sur web, LiveKit crée un élément <audio> par piste distante dans le
/// conteneur `livekit_audio_container` : pour le réglage « haut-parleur »,
/// on pilote directement leur volume/mute. Cette API n'existe QUE sur web —
/// l'implémentation est derrière un import conditionnel pour que la build
/// Android compile (package:web est interdit hors web).
export 'web_audio_output_stub.dart'
    if (dart.library.js_interop) 'web_audio_output_web.dart';
