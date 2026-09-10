import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import '../services/meeting_service.dart';

class MeetingProvider extends ChangeNotifier {
  final MeetingService _meetingService = MeetingService();
  final _logger = Logger();

  final List<MeetingModel> _meetings = [];
  MeetingModel? _currentMeeting;
  bool _isLoading = false;
  String? _error;
  StreamSubscription<MeetingModel?>? _meetingSub;

  List<MeetingModel> get meetings => _meetings;
  MeetingModel? get currentMeeting => _currentMeeting;
  bool get isLoading => _isLoading;
  String? get error => _error;

  @override
  void dispose() {
    _meetingSub?.cancel();
    super.dispose();
  }

  Future<String?> createMeeting({
    required String title,
    required String description,
    required String organizerName,
    required String organizerId,
  }) async {
    try {
      _setLoading(true);
      _clearError();
      final meeting = await _meetingService.createMeeting(
        title: title,
        description: description,
        organizerName: organizerName,
        organizerId: organizerId,
      );
      _logger.i('✅ Réunion créée: ${meeting.id}');
      notifyListeners();
      return meeting.id;
    } catch (e) {
      _setError('Erreur création réunion: $e');
      return null;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> getMeeting(String meetingId) async {
    try {
      _setLoading(true);
      _clearError();
      await _meetingSub?.cancel();
      _meetingSub = _meetingService.getMeeting(meetingId).listen((meeting) {
        _currentMeeting = meeting;
        notifyListeners();
      });
    } catch (e) {
      _setError('Erreur récupération: $e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> updateMeetingStatus(
    String meetingId,
    MeetingStatus status,
  ) async {
    try {
      await _meetingService.updateMeetingStatus(meetingId, status);
      notifyListeners();
    } catch (e) {
      _setError('Erreur mise à jour: $e');
    }
  }

  Future<void> addParticipant(String meetingId, String userId) async {
    try {
      await _meetingService.addParticipant(meetingId, userId);
      notifyListeners();
    } catch (e) {
      _setError('Erreur ajout participant: $e');
    }
  }

  Future<void> removeParticipant(String meetingId, String userId) async {
    try {
      await _meetingService.removeParticipant(meetingId, userId);
      notifyListeners();
    } catch (e) {
      _setError('Erreur suppression participant: $e');
    }
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _setError(String error) {
    _error = error;
    _logger.e('❌ $error');
    notifyListeners();
  }

  void _clearError() => _error = null;

  void clearMeeting() {
    _meetingSub?.cancel();
    _meetingSub = null;
    _currentMeeting = null;
    notifyListeners();
  }
}
