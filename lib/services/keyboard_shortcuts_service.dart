import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/logger.dart' as crux;

/// Service de raccourcis clavier pour l'interface web.
///
/// Ce service gère les raccourcis clavier pour permettre aux utilisateurs
/// d'accéder rapidement aux fonctions courantes de réunion.
class KeyboardShortcutsService {
  KeyboardShortcutsService._();

  static final KeyboardShortcutsService instance = KeyboardShortcutsService._();

  final _logger = crux.logger;

  // État
  bool _isEnabled = true;
  final Map<ShortcutActivator, VoidCallback> _shortcuts = {};
  final FocusNode _focusNode = FocusNode();

  // Callbacks pour les actions de réunion
  Function()? _onToggleMic;
  Function()? _onToggleCamera;
  Function()? _onToggleScreenShare;
  Function()? _onToggleHandRaise;
  Function()? _onLeaveMeeting;
  Function()? _onToggleChat;
  Function()? _onToggleParticipants;
  Function()? _onToggleReactions;
  Function()? _onMuteAll;
  Function()? _onToggleFullscreen;

  // Getters
  bool get isEnabled => _isEnabled;
  FocusNode get focusNode => _focusNode;

  /// Initialise le service de raccourcis clavier
  void initialize({
    Function()? onToggleMic,
    Function()? onToggleCamera,
    Function()? onToggleScreenShare,
    Function()? onToggleHandRaise,
    Function()? onLeaveMeeting,
    Function()? onToggleChat,
    Function()? onToggleParticipants,
    Function()? onToggleReactions,
    Function()? onMuteAll,
    Function()? onToggleFullscreen,
  }) {
    _onToggleMic = onToggleMic;
    _onToggleCamera = onToggleCamera;
    _onToggleScreenShare = onToggleScreenShare;
    _onToggleHandRaise = onToggleHandRaise;
    _onLeaveMeeting = onLeaveMeeting;
    _onToggleChat = onToggleChat;
    _onToggleParticipants = onToggleParticipants;
    _onToggleReactions = onToggleReactions;
    _onMuteAll = onMuteAll;
    _onToggleFullscreen = onToggleFullscreen;

    _registerDefaultShortcuts();
    _logger.i('KeyboardShortcutsService initialized');
  }

  /// Enregistre les raccourcis par défaut
  void _registerDefaultShortcuts() {
    // Raccourcis alignés sur Zoom Desktop (Windows/Linux) : la touche Alt
    // n'entre pas en conflit avec le navigateur (Ctrl+S, Ctrl+P, Ctrl+F…)
    // ni avec le copier-coller (Ctrl+C).

    // Micro : Alt + A
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyA, alt: true)] =
        _onToggleMic ?? () {};

    // Caméra : Alt + V
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyV, alt: true)] =
        _onToggleCamera ?? () {};

    // Partage d'écran : Alt + S
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyS, alt: true)] =
        _onToggleScreenShare ?? () {};

    // Lever la main : Alt + Y
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyY, alt: true)] =
        _onToggleHandRaise ?? () {};

    // Chat : Alt + H
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyH, alt: true)] =
        _onToggleChat ?? () {};

    // Participants : Alt + U
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyU, alt: true)] =
        _onToggleParticipants ?? () {};

    // Réactions : Alt + R
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyR, alt: true)] =
        _onToggleReactions ?? () {};

    // Plein écran : Alt + F
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyF, alt: true)] =
        _onToggleFullscreen ?? () {};

    // Quitter : Alt + Q
    _shortcuts[const SingleActivator(LogicalKeyboardKey.keyQ, alt: true)] =
        _onLeaveMeeting ?? () {};

    // Couper le micro de tous (hôte uniquement) : Ctrl/Cmd + Shift + M
    _shortcuts[const SingleActivator(
          LogicalKeyboardKey.keyM,
          control: true,
          shift: true,
        )] =
        _onMuteAll ?? () {};
  }

  /// Active/désactive les raccourcis clavier
  void setEnabled(bool enabled) {
    _isEnabled = enabled;
    _logger.i('Keyboard shortcuts ${enabled ? "enabled" : "disabled"}');
  }

  /// Traite les événements clavier
  bool handleKeyEvent(KeyEvent event) {
    if (!_isEnabled) return false;

    if (event is! KeyDownEvent) return false;

    final activator = SingleActivator(
      event.logicalKey,
      control: HardwareKeyboard.instance.isControlPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      meta: HardwareKeyboard.instance.isMetaPressed,
    );

    final callback = _shortcuts[activator];
    if (callback != null) {
      callback();
      return true;
    }

    return false;
  }

  /// Ajoute un raccourci personnalisé
  void addShortcut(ShortcutActivator activator, VoidCallback callback) {
    _shortcuts[activator] = callback;
    _logger.d('Custom shortcut added');
  }

  /// Supprime un raccourci
  void removeShortcut(ShortcutActivator activator) {
    _shortcuts.remove(activator);
    _logger.d('Shortcut removed');
  }

  /// Obtient la liste des raccourcis disponibles
  List<ShortcutDescription> getAvailableShortcuts() {
    return [
      ShortcutDescription(
        keys: 'Alt + A',
        description: 'Activer/Désactiver le micro',
        action: _onToggleMic != null,
      ),
      ShortcutDescription(
        keys: 'Alt + V',
        description: 'Activer/Désactiver la caméra',
        action: _onToggleCamera != null,
      ),
      ShortcutDescription(
        keys: 'Alt + S',
        description: 'Partager/Arrêter le partage d\'écran',
        action: _onToggleScreenShare != null,
      ),
      ShortcutDescription(
        keys: 'Alt + Y',
        description: 'Lever/Baisser la main',
        action: _onToggleHandRaise != null,
      ),
      ShortcutDescription(
        keys: 'Alt + H',
        description: 'Ouvrir/Fermer le chat',
        action: _onToggleChat != null,
      ),
      ShortcutDescription(
        keys: 'Alt + U',
        description: 'Afficher/Masquer les participants',
        action: _onToggleParticipants != null,
      ),
      ShortcutDescription(
        keys: 'Alt + R',
        description: 'Afficher/Masquer les réactions',
        action: _onToggleReactions != null,
      ),
      ShortcutDescription(
        keys: 'Alt + F',
        description: 'Plein écran',
        action: _onToggleFullscreen != null,
      ),
      ShortcutDescription(
        keys: 'Alt + Q',
        description: 'Quitter la réunion',
        action: _onLeaveMeeting != null,
      ),
      if (_onMuteAll != null)
        ShortcutDescription(
          keys: 'Ctrl/Cmd + Shift + M',
          description: 'Couper le micro de tous (hôte)',
          action: true,
        ),
    ];
  }

  /// Widget qui enveloppe l'application pour gérer les raccourcis
  Widget buildKeyboardShortcutHandler({required Widget child}) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (handleKeyEvent(event)) {
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: CallbackShortcuts(bindings: _shortcuts, child: child),
    );
  }

  /// Nettoie les ressources
  void dispose() {
    _focusNode.dispose();
    _shortcuts.clear();
    _logger.i('KeyboardShortcutsService disposed');
  }
}

/// Description d'un raccourci clavier
class ShortcutDescription {
  final String keys;
  final String description;
  final bool action;

  ShortcutDescription({
    required this.keys,
    required this.description,
    required this.action,
  });
}

/// Activateur de raccourci simplifié
class SingleActivator extends ShortcutActivator {
  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  const SingleActivator(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  @override
  bool accepts(KeyEvent event, HardwareKeyboard keyboard) {
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey != key) return false;

    if (control && !keyboard.isControlPressed) return false;
    if (shift && !keyboard.isShiftPressed) return false;
    if (alt && !keyboard.isAltPressed) return false;
    if (meta && !keyboard.isMetaPressed) return false;

    if (!control && keyboard.isControlPressed) return false;
    if (!shift && keyboard.isShiftPressed) return false;
    if (!alt && keyboard.isAltPressed) return false;
    if (!meta && keyboard.isMetaPressed) return false;

    return true;
  }

  @override
  String debugDescribeKeys() {
    return toString();
  }

  @override
  String toString() {
    final parts = <String>[];
    if (control) parts.add('Ctrl');
    if (meta) parts.add('Cmd');
    if (shift) parts.add('Shift');
    if (alt) parts.add('Alt');
    parts.add(_keyLabel(key));
    return parts.join(' + ');
  }

  String _keyLabel(LogicalKeyboardKey key) {
    // Mapping simplifié des touches courantes
    final keyMap = {
      LogicalKeyboardKey.keyA: 'A',
      LogicalKeyboardKey.keyB: 'B',
      LogicalKeyboardKey.keyC: 'C',
      LogicalKeyboardKey.keyD: 'D',
      LogicalKeyboardKey.keyE: 'E',
      LogicalKeyboardKey.keyF: 'F',
      LogicalKeyboardKey.keyG: 'G',
      LogicalKeyboardKey.keyH: 'H',
      LogicalKeyboardKey.keyI: 'I',
      LogicalKeyboardKey.keyJ: 'J',
      LogicalKeyboardKey.keyK: 'K',
      LogicalKeyboardKey.keyL: 'L',
      LogicalKeyboardKey.keyM: 'M',
      LogicalKeyboardKey.keyN: 'N',
      LogicalKeyboardKey.keyO: 'O',
      LogicalKeyboardKey.keyP: 'P',
      LogicalKeyboardKey.keyQ: 'Q',
      LogicalKeyboardKey.keyR: 'R',
      LogicalKeyboardKey.keyS: 'S',
      LogicalKeyboardKey.keyT: 'T',
      LogicalKeyboardKey.keyU: 'U',
      LogicalKeyboardKey.keyV: 'V',
      LogicalKeyboardKey.keyW: 'W',
      LogicalKeyboardKey.keyX: 'X',
      LogicalKeyboardKey.keyY: 'Y',
      LogicalKeyboardKey.keyZ: 'Z',
      LogicalKeyboardKey.space: 'Espace',
      LogicalKeyboardKey.enter: 'Entrée',
      LogicalKeyboardKey.escape: 'Échap',
      LogicalKeyboardKey.tab: 'Tab',
    };

    return keyMap[key] ?? key.keyLabel;
  }
}
