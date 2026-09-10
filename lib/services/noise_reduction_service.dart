import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart' as crux;

/// Service de réduction de bruit audio.
///
/// Ce service implémente des algorithmes de réduction de bruit
/// pour améliorer la qualité audio lors des réunions.
class NoiseReductionService {
  NoiseReductionService._();

  static final NoiseReductionService instance = NoiseReductionService._();

  final _logger = crux.logger;

  // État
  bool _isEnabled = false;
  NoiseReductionLevel _level = NoiseReductionLevel.medium;
  bool _echoCancellation = true;
  bool _autoGainControl = true;

  // Statistiques
  int _processedSamples = 0;
  double _noiseLevel = 0.0;
  Timer? _noiseMonitor;

  // Préférences
  static const String _enabledKey = 'crux_noise_reduction_enabled';
  static const String _levelKey = 'crux_noise_reduction_level';
  static const String _echoCancellationKey = 'crux_echo_cancellation';
  static const String _autoGainControlKey = 'crux_auto_gain_control';

  // Getters
  bool get isEnabled => _isEnabled;
  NoiseReductionLevel get level => _level;
  bool get echoCancellation => _echoCancellation;
  bool get autoGainControl => _autoGainControl;
  int get processedSamples => _processedSamples;
  double get noiseLevel => _noiseLevel;

  /// Initialise le service
  Future<void> initialize() async {
    await _loadPreferences();
    _startNoiseMonitoring();
    _logger.i(
      'NoiseReductionService initialized - Enabled: $_isEnabled, Level: $_level',
    );
  }

  /// Charge les préférences
  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Activée par défaut (référence Zoom : suppression du bruit ON).
    _isEnabled = prefs.getBool(_enabledKey) ?? true;
      _echoCancellation = prefs.getBool(_echoCancellationKey) ?? true;
      _autoGainControl = prefs.getBool(_autoGainControlKey) ?? true;

      final levelString = prefs.getString(_levelKey);
      _level =
          levelString != null
              ? NoiseReductionLevel.values.firstWhere(
                (e) => e.toString() == 'NoiseReductionLevel.$levelString',
                orElse: () => NoiseReductionLevel.medium,
              )
              : NoiseReductionLevel.medium;
    } catch (e) {
      _logger.e('Failed to load noise reduction preferences', error: e);
    }
  }

  /// Sauvegarde les préférences
  Future<void> _savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, _isEnabled);
      await prefs.setString(_levelKey, _level.toString().split('.').last);
      await prefs.setBool(_echoCancellationKey, _echoCancellation);
      await prefs.setBool(_autoGainControlKey, _autoGainControl);
    } catch (e) {
      _logger.e('Failed to save noise reduction preferences', error: e);
    }
  }

  /// Active/désactive la réduction de bruit
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    await _savePreferences();
    _logger.i('Noise reduction ${enabled ? "enabled" : "disabled"}');
  }

  /// Définit le niveau de réduction de bruit
  Future<void> setLevel(NoiseReductionLevel level) async {
    _level = level;
    await _savePreferences();
    _logger.i('Noise reduction level set to $level');
  }

  /// Active/désactive l'annulation d'écho
  Future<void> setEchoCancellation(bool enabled) async {
    _echoCancellation = enabled;
    await _savePreferences();
    _logger.i('Echo cancellation ${enabled ? "enabled" : "disabled"}');
  }

  /// Active/désactive le contrôle automatique du gain
  Future<void> setAutoGainControl(bool enabled) async {
    _autoGainControl = enabled;
    await _savePreferences();
    _logger.i('Auto gain control ${enabled ? "enabled" : "disabled"}');
  }

  /// Traite les données audio pour réduire le bruit
  Uint8List processAudio(Uint8List audioData) {
    if (!_isEnabled) return audioData;

    try {
      // Conversion des données audio
      final samples = _convertToSamples(audioData);

      // Application des algorithmes de réduction de bruit
      final processedSamples = _applyNoiseReduction(samples);

      // Conversion retour en bytes
      final processedData = _convertToBytes(processedSamples);

      _processedSamples += samples.length;
      return processedData;
    } catch (e) {
      _logger.e('Failed to process audio', error: e);
      return audioData;
    }
  }

  /// Convertit les bytes en échantillons audio
  List<double> _convertToSamples(Uint8List data) {
    // Simplification - en production, utiliser une vraie conversion
    // selon le format audio (PCM, etc.)
    final samples = <double>[];
    for (int i = 0; i < data.length; i += 2) {
      final sample = (data[i] + data[i + 1] * 256) / 32768.0;
      samples.add(sample);
    }
    return samples;
  }

  /// Applique les algorithmes de réduction de bruit
  List<double> _applyNoiseReduction(List<double> samples) {
    final processed = <double>[];
    final threshold = _getNoiseThreshold();

    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];

      // Gate noise (suppression des sons inférieurs au seuil)
      if (sample.abs() < threshold) {
        processed.add(sample * 0.1); // Atténuation forte
      } else {
        processed.add(sample);
      }

      // Annulation d'écho (simplifiée)
      if (_echoCancellation && i > 10) {
        final echoSample = samples[i - 10] * 0.3;
        processed[i] -= echoSample;
      }

      // Contrôle automatique du gain
      if (_autoGainControl) {
        processed[i] = _applyGainControl(processed[i]);
      }
    }

    return processed;
  }

  /// Obtient le seuil de bruit selon le niveau
  double _getNoiseThreshold() {
    switch (_level) {
      case NoiseReductionLevel.low:
        return 0.05;
      case NoiseReductionLevel.medium:
        return 0.1;
      case NoiseReductionLevel.high:
        return 0.15;
      case NoiseReductionLevel.aggressive:
        return 0.2;
    }
  }

  /// Applique le contrôle automatique du gain
  double _applyGainControl(double sample) {
    final targetLevel = 0.7;
    final currentLevel = sample.abs();

    if (currentLevel < targetLevel * 0.5) {
      return sample * 1.2; // Amplification
    } else if (currentLevel > targetLevel * 1.5) {
      return sample * 0.8; // Atténuation
    }

    return sample;
  }

  /// Convertit les échantillons en bytes
  Uint8List _convertToBytes(List<double> samples) {
    final data = Uint8List(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final value = (samples[i] * 32767).clamp(-32768, 32767).toInt();
      data[i * 2] = value & 0xFF;
      data[i * 2 + 1] = (value >> 8) & 0xFF;
    }
    return data;
  }

  /// Démarre la surveillance du bruit
  void _startNoiseMonitoring() {
    _noiseMonitor = Timer.periodic(const Duration(seconds: 5), (_) {
      _updateNoiseLevel();
    });
  }

  /// Met à jour le niveau de bruit estimé
  void _updateNoiseLevel() {
    // En production, calculer le niveau de bruit réel
    // à partir des données audio traitées
    _noiseLevel = _isEnabled ? 0.05 : 0.15;
  }

  /// Obtient des statistiques sur le traitement audio
  Map<String, dynamic> getProcessingStats() {
    return {
      'enabled': _isEnabled,
      'level': _level.toString().split('.').last,
      'echoCancellation': _echoCancellation,
      'autoGainControl': _autoGainControl,
      'processedSamples': _processedSamples,
      'currentNoiseLevel': _noiseLevel,
    };
  }

  /// Réinitialise les statistiques
  void resetStats() {
    _processedSamples = 0;
    _noiseLevel = 0.0;
    _logger.d('Noise reduction stats reset');
  }

  /// Nettoie les ressources
  void dispose() {
    _noiseMonitor?.cancel();
    _logger.i('NoiseReductionService disposed');
  }
}

/// Niveaux de réduction de bruit
enum NoiseReductionLevel { low, medium, high, aggressive }
