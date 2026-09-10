import 'package:flutter/foundation.dart';

/// Bus de diffusion des réactions emoji en réunion.
///
/// Un seul canal pour les réactions locales (envoyées par l'utilisateur) et
/// les réactions distantes (reçues via le data channel LiveKit) :
/// `CruxConferenceView` écoute ce bus et anime les particules, quel que soit
/// l'émetteur.
class ReactionBus extends ChangeNotifier {
  ReactionBus._();

  static final ReactionBus instance = ReactionBus._();

  String? _lastEmoji;

  int _seq = 0;

  /// Dernière réaction publiée (null si aucune).
  String? get lastEmoji => _lastEmoji;

  /// Compteur monotone : permet de notifier plusieurs fois la même emoji.
  int get seq => _seq;

  void publish(String emoji) {
    if (emoji.trim().isEmpty) return;

    _lastEmoji = emoji;

    _seq++;

    notifyListeners();
  }

  void reset() {
    _lastEmoji = null;

    _seq = 0;
  }
}
