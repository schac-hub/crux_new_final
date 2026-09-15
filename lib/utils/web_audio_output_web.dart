library;
import 'package:web/web.dart' as web;

/// Coupe ou rétablit la sortie des éléments <audio> créés par LiveKit.
void applyRemoteAudioOutput(bool speakerOn) {
  try {
    final container = web.document.getElementById('livekit_audio_container');

    if (container == null) return;

    final audios = container.querySelectorAll('audio');

    for (var i = 0; i < audios.length; i++) {
      final audio = audios.item(i) as web.HTMLAudioElement?;

      if (audio == null) continue;

      audio.muted = !speakerOn;
      audio.volume = speakerOn ? 1.0 : 0.0;
    }
  } catch (_) {
    // Silencieux : un DOM inattendu ne doit pas casser l'appel.
  }
}
