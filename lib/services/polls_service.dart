import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import '../utils/logger.dart' as crux;

/// Service de gestion des sondages et Q&A en temps réel.
///
/// Ce service permet de créer et gérer des sondages interactifs
/// et des sessions de questions-réponses pendant les réunions.
class PollsService {
  PollsService._();

  static final PollsService instance = PollsService._();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final _logger = crux.logger;
  final Uuid _uuid = const Uuid();

  // État des sondages actifs
  final List<Poll> _activePolls = [];
  final StreamController<List<Poll>> _pollsController =
      StreamController<List<Poll>>.broadcast();

  // Questions-réponses
  final List<QAQuestion> _qaQuestions = [];
  final StreamController<List<QAQuestion>> _qaController =
      StreamController<List<QAQuestion>>.broadcast();

  // Temps réel Firestore : source de vérité partagée entre appareils.
  String? _activeMeetingId;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _pollsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _qaSub;

  // Getters
  List<Poll> get activePolls => List.unmodifiable(_activePolls);
  List<QAQuestion> get qaQuestions => List.unmodifiable(_qaQuestions);
  Stream<List<Poll>> get pollsStream => _pollsController.stream;
  Stream<List<QAQuestion>> get qaStream => _qaController.stream;

  /// Initialise le service.
  ///
  /// [meetingId] (optionnel) branche l'écoute temps réel Firestore des
  /// sondages et questions de la réunion : sans lui, le service reste
  /// limité à l'état local de l'appareil.
  Future<void> initialize({String? meetingId}) async {
    if (meetingId != null && meetingId.trim().isNotEmpty) {
      final mid = meetingId.trim();
      if (mid != _activeMeetingId) {
        _activeMeetingId = mid;
        _subscribeToFirestore(mid);
      }
    }
    _logger.i('PollsService initialized (meeting: ${_activeMeetingId ?? 'local'})');
  }

  void _subscribeToFirestore(String meetingId) {
    _pollsSub?.cancel();
    _qaSub?.cancel();

    _pollsSub = _firestore
        .collection('polls')
        .where('meetingId', isEqualTo: meetingId)
        .snapshots()
        .listen(
          (snap) {
            final polls =
                snap.docs.map((d) => Poll.fromJson(d.data())).toList()
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            _activePolls
              ..clear()
              ..addAll(polls);
            _pollsController.add(List.from(_activePolls));
          },
          onError: (e) => _logger.e('Polls stream error', error: e),
        );

    _qaSub = _firestore
        .collection('qa_questions')
        .where('meetingId', isEqualTo: meetingId)
        .snapshots()
        .listen(
          (snap) {
            final questions =
                snap.docs.map((d) => QAQuestion.fromJson(d.data())).toList()
                  ..sort((a, b) => b.upvotes.compareTo(a.upvotes));
            _qaQuestions
              ..clear()
              ..addAll(questions);
            _qaController.add(List.from(_qaQuestions));
          },
          onError: (e) => _logger.e('QA stream error', error: e),
        );
  }

  /// Crée un nouveau sondage
  Future<String> createPoll({
    required String meetingId,
    required String question,
    required List<PollOption> options,
    required bool allowMultipleAnswers,
    required bool anonymous,
    Duration? duration,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) throw Exception('User not authenticated');

      final pollId = _uuid.v4();
      final now = DateTime.now();

      final poll = Poll(
        id: pollId,
        meetingId: meetingId,
        createdBy: userId,
        question: question,
        options: options,
        allowMultipleAnswers: allowMultipleAnswers,
        anonymous: anonymous,
        createdAt: now,
        endsAt: duration != null ? now.add(duration) : null,
        isActive: true,
        totalResponses: 0,
        responses: {},
      );

      await _savePoll(poll);
      _activePolls.add(poll);
      _pollsController.add(List.from(_activePolls));

      _logger.i('Created poll: $question');
      return pollId;
    } catch (e) {
      _logger.e('Failed to create poll', error: e);
      rethrow;
    }
  }

  /// Répond à un sondage (transaction : comptage atomique multi-appareils).
  Future<void> respondToPoll({
    required String pollId,
    required List<String> selectedOptionIds,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) throw Exception('User not authenticated');

      if (selectedOptionIds.isEmpty) {
        throw Exception('No option selected');
      }

      await _firestore.runTransaction<void>((transaction) async {
        final doc = await transaction.get(
          _firestore.collection('polls').doc(pollId),
        );

        if (!doc.exists || doc.data() == null) {
          throw Exception('Poll not found');
        }

        final fresh = Poll.fromJson(doc.data()!);

        if (!fresh.isActive) throw Exception('Poll is closed');

        if (fresh.responses.containsKey(userId)) {
          throw Exception('Already responded to this poll');
        }

        if (!fresh.allowMultipleAnswers && selectedOptionIds.length > 1) {
          throw Exception('Multiple answers not allowed');
        }

        final validIds = fresh.options.map((o) => o.id).toSet();
        if (!selectedOptionIds.every(validIds.contains)) {
          throw Exception('Invalid option');
        }

        final updatedOptions =
            fresh.options
                .map(
                  (option) =>
                      selectedOptionIds.contains(option.id)
                          ? PollOption(
                            id: option.id,
                            text: option.text,
                            votes: option.votes + 1,
                          )
                          : option,
                )
                .toList();

        final updated = fresh.copyWith(
          options: updatedOptions,
          responses: {
            ...fresh.responses,
            userId: PollResponse(
              userId: userId,
              selectedOptionIds: selectedOptionIds,
              respondedAt: DateTime.now(),
            ),
          },
          totalResponses: fresh.totalResponses + 1,
        );

        transaction.set(doc.reference, updated.toJson());
      });

      // La diffusion temps réel propage le résultat à tous les appareils.
      _logger.i('User $userId responded to poll $pollId');
    } catch (e) {
      _logger.e('Failed to respond to poll', error: e);
      rethrow;
    }
  }

  /// Termine un sondage
  Future<void> endPoll(String pollId) async {
    try {
      await _firestore.collection('polls').doc(pollId).update({
        'isActive': false,
        'endedAt': DateTime.now().toIso8601String(),
      });

      _logger.i('Ended poll $pollId');
    } catch (e) {
      _logger.e('Failed to end poll', error: e);
      rethrow;
    }
  }

  /// Supprime un sondage
  Future<void> deletePoll(String pollId) async {
    try {
      await _firestore.collection('polls').doc(pollId).delete();
      _activePolls.removeWhere((p) => p.id == pollId);
      _pollsController.add(List.from(_activePolls));

      _logger.i('Deleted poll $pollId');
    } catch (e) {
      _logger.e('Failed to delete poll', error: e);
      rethrow;
    }
  }

  /// Obtient les résultats d'un sondage
  PollResults getPollResults(String pollId) {
    final poll = _activePolls.firstWhere(
      (p) => p.id == pollId,
      orElse: () => throw Exception('Poll not found'),
    );

    final totalVotes = poll.options.fold<int>(
      0,
      (total, option) => total + option.votes,
    );

    final optionResults =
        poll.options.map((option) {
          final percentage =
              totalVotes > 0
                  ? (option.votes / totalVotes * 100).toStringAsFixed(1)
                  : '0.0';

          return PollOptionResult(
            optionId: option.id,
            text: option.text,
            votes: option.votes,
            percentage: double.parse(percentage),
          );
        }).toList();

    return PollResults(
      pollId: pollId,
      question: poll.question,
      totalResponses: poll.totalResponses,
      optionResults: optionResults,
    );
  }

  /// Pose une question Q&A
  Future<String> askQuestion({
    required String meetingId,
    required String question,
    required bool anonymous,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) throw Exception('User not authenticated');

      final questionId = _uuid.v4();
      final now = DateTime.now();

      final qaQuestion = QAQuestion(
        id: questionId,
        meetingId: meetingId,
        askedBy: userId,
        question: question,
        anonymous: anonymous,
        askedAt: now,
        status: QAStatus.pending,
        upvotes: 0,
        answer: null,
      );

      await _saveQAQuestion(qaQuestion);
      _qaQuestions.add(qaQuestion);
      _qaController.add(List.from(_qaQuestions));

      _logger.i('Asked question: $question');
      return questionId;
    } catch (e) {
      _logger.e('Failed to ask question', error: e);
      rethrow;
    }
  }

  /// Répond à une question Q&A
  Future<void> answerQuestion({
    required String questionId,
    required String answer,
    required String answeredBy,
  }) async {
    try {
      final questionIndex = _qaQuestions.indexWhere((q) => q.id == questionId);
      if (questionIndex == -1) throw Exception('Question not found');

      final updatedQuestion = _qaQuestions[questionIndex].copyWith(
        answer: answer,
        answeredBy: answeredBy,
        answeredAt: DateTime.now(),
        status: QAStatus.answered,
      );

      await _saveQAQuestion(updatedQuestion);
      _qaQuestions[questionIndex] = updatedQuestion;
      _qaController.add(List.from(_qaQuestions));

      _logger.i('Answered question $questionId');
    } catch (e) {
      _logger.e('Failed to answer question', error: e);
      rethrow;
    }
  }

  /// Vote pour une question Q&A (arrayUnion/arrayRemove : atomique côté
  /// Firestore, aucun écrasement concurrent entre appareils).
  Future<void> upvoteQuestion(String questionId) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) throw Exception('User not authenticated');

      final question = _qaQuestions.firstWhere(
        (q) => q.id == questionId,
        orElse: () => throw Exception('Question not found'),
      );

      final alreadyVoted = (question.upvoters ?? []).contains(userId);

      await _firestore.collection('qa_questions').doc(questionId).update({
        'upvoters':
            alreadyVoted
                ? FieldValue.arrayRemove([userId])
                : FieldValue.arrayUnion([userId]),
        'upvotes': FieldValue.increment(alreadyVoted ? -1 : 1),
      });

      _logger.i('Upvoted question $questionId');
    } catch (e) {
      _logger.e('Failed to upvote question', error: e);
      rethrow;
    }
  }

  /// Archive une question Q&A
  Future<void> archiveQuestion(String questionId) async {
    try {
      final questionIndex = _qaQuestions.indexWhere((q) => q.id == questionId);
      if (questionIndex == -1) throw Exception('Question not found');

      final updatedQuestion = _qaQuestions[questionIndex].copyWith(
        status: QAStatus.archived,
      );

      await _saveQAQuestion(updatedQuestion);
      _qaQuestions[questionIndex] = updatedQuestion;
      _qaController.add(List.from(_qaQuestions));

      _logger.i('Archived question $questionId');
    } catch (e) {
      _logger.e('Failed to archive question', error: e);
      rethrow;
    }
  }

  /// Sauvegarde un sondage
  Future<void> _savePoll(Poll poll) async {
    try {
      await _firestore.collection('polls').doc(poll.id).set(poll.toJson());
    } catch (e) {
      _logger.e('Failed to save poll', error: e);
      rethrow;
    }
  }

  /// Sauvegarde une question Q&A
  Future<void> _saveQAQuestion(QAQuestion question) async {
    try {
      await _firestore
          .collection('qa_questions')
          .doc(question.id)
          .set(question.toJson());
    } catch (e) {
      _logger.e('Failed to save QA question', error: e);
      rethrow;
    }
  }

  /// Nettoie les ressources
  void dispose() {
    _pollsSub?.cancel();
    _qaSub?.cancel();
    _pollsController.close();
    _qaController.close();
    _logger.i('PollsService disposed');
  }
}

/// Sondage
class Poll {
  final String id;
  final String meetingId;
  final String createdBy;
  final String question;
  final List<PollOption> options;
  final bool allowMultipleAnswers;
  final bool anonymous;
  final DateTime createdAt;
  final DateTime? endsAt;
  final DateTime? endedAt;
  final bool isActive;
  final int totalResponses;
  final Map<String, PollResponse> responses;

  Poll({
    required this.id,
    required this.meetingId,
    required this.createdBy,
    required this.question,
    required this.options,
    required this.allowMultipleAnswers,
    required this.anonymous,
    required this.createdAt,
    this.endsAt,
    this.endedAt,
    required this.isActive,
    required this.totalResponses,
    required this.responses,
  });

  Poll copyWith({
    String? id,
    String? meetingId,
    String? createdBy,
    String? question,
    List<PollOption>? options,
    bool? allowMultipleAnswers,
    bool? anonymous,
    DateTime? createdAt,
    DateTime? endsAt,
    DateTime? endedAt,
    bool? isActive,
    int? totalResponses,
    Map<String, PollResponse>? responses,
  }) {
    return Poll(
      id: id ?? this.id,
      meetingId: meetingId ?? this.meetingId,
      createdBy: createdBy ?? this.createdBy,
      question: question ?? this.question,
      options: options ?? this.options,
      allowMultipleAnswers: allowMultipleAnswers ?? this.allowMultipleAnswers,
      anonymous: anonymous ?? this.anonymous,
      createdAt: createdAt ?? this.createdAt,
      endsAt: endsAt ?? this.endsAt,
      endedAt: endedAt ?? this.endedAt,
      isActive: isActive ?? this.isActive,
      totalResponses: totalResponses ?? this.totalResponses,
      responses: responses ?? this.responses,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'meetingId': meetingId,
      'createdBy': createdBy,
      'question': question,
      'options': options.map((o) => o.toJson()).toList(),
      'allowMultipleAnswers': allowMultipleAnswers,
      'anonymous': anonymous,
      'createdAt': createdAt.toIso8601String(),
      'endsAt': endsAt?.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
      'isActive': isActive,
      'totalResponses': totalResponses,
      'responses': responses.map((k, v) => MapEntry(k, v.toJson())),
    };
  }

  static Poll fromJson(Map<String, dynamic> json) {
    return Poll(
      id: json['id'] as String,
      meetingId: json['meetingId'] as String,
      createdBy: json['createdBy'] as String,
      question: json['question'] as String,
      options:
          (json['options'] as List)
              .map((o) => PollOption.fromJson(o as Map<String, dynamic>))
              .toList(),
      allowMultipleAnswers: json['allowMultipleAnswers'] as bool,
      anonymous: json['anonymous'] as bool,
      createdAt: DateTime.parse(json['createdAt'] as String),
      endsAt:
          json['endsAt'] != null
              ? DateTime.parse(json['endsAt'] as String)
              : null,
      endedAt:
          json['endedAt'] != null
              ? DateTime.parse(json['endedAt'] as String)
              : null,
      isActive: json['isActive'] as bool,
      totalResponses: json['totalResponses'] as int,
      responses: (json['responses'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, PollResponse.fromJson(v as Map<String, dynamic>)),
      ),
    );
  }
}

/// Option de sondage
class PollOption {
  final String id;
  final String text;
  final int votes;

  PollOption({required this.id, required this.text, this.votes = 0});

  Map<String, dynamic> toJson() {
    return {'id': id, 'text': text, 'votes': votes};
  }

  static PollOption fromJson(Map<String, dynamic> json) {
    return PollOption(
      id: json['id'] as String,
      text: json['text'] as String,
      votes: json['votes'] as int,
    );
  }
}

/// Réponse à un sondage
class PollResponse {
  final String userId;
  final List<String> selectedOptionIds;
  final DateTime respondedAt;

  PollResponse({
    required this.userId,
    required this.selectedOptionIds,
    required this.respondedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'selectedOptionIds': selectedOptionIds,
      'respondedAt': respondedAt.toIso8601String(),
    };
  }

  static PollResponse fromJson(Map<String, dynamic> json) {
    return PollResponse(
      userId: json['userId'] as String,
      selectedOptionIds: (json['selectedOptionIds'] as List).cast<String>(),
      respondedAt: DateTime.parse(json['respondedAt'] as String),
    );
  }
}

/// Résultats d'un sondage
class PollResults {
  final String pollId;
  final String question;
  final int totalResponses;
  final List<PollOptionResult> optionResults;

  PollResults({
    required this.pollId,
    required this.question,
    required this.totalResponses,
    required this.optionResults,
  });
}

/// Résultat d'une option de sondage
class PollOptionResult {
  final String optionId;
  final String text;
  final int votes;
  final double percentage;

  PollOptionResult({
    required this.optionId,
    required this.text,
    required this.votes,
    required this.percentage,
  });
}

/// Question Q&A
class QAQuestion {
  final String id;
  final String meetingId;
  final String askedBy;
  final String question;
  final bool anonymous;
  final DateTime askedAt;
  final QAStatus status;
  final int upvotes;
  final List<String>? upvoters;
  final String? answer;
  final String? answeredBy;
  final DateTime? answeredAt;

  QAQuestion({
    required this.id,
    required this.meetingId,
    required this.askedBy,
    required this.question,
    required this.anonymous,
    required this.askedAt,
    required this.status,
    this.upvotes = 0,
    this.upvoters,
    this.answer,
    this.answeredBy,
    this.answeredAt,
  });

  QAQuestion copyWith({
    String? id,
    String? meetingId,
    String? askedBy,
    String? question,
    bool? anonymous,
    DateTime? askedAt,
    QAStatus? status,
    int? upvotes,
    List<String>? upvoters,
    String? answer,
    String? answeredBy,
    DateTime? answeredAt,
  }) {
    return QAQuestion(
      id: id ?? this.id,
      meetingId: meetingId ?? this.meetingId,
      askedBy: askedBy ?? this.askedBy,
      question: question ?? this.question,
      anonymous: anonymous ?? this.anonymous,
      askedAt: askedAt ?? this.askedAt,
      status: status ?? this.status,
      upvotes: upvotes ?? this.upvotes,
      upvoters: upvoters ?? this.upvoters,
      answer: answer ?? this.answer,
      answeredBy: answeredBy ?? this.answeredBy,
      answeredAt: answeredAt ?? this.answeredAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'meetingId': meetingId,
      'askedBy': askedBy,
      'question': question,
      'anonymous': anonymous,
      'askedAt': askedAt.toIso8601String(),
      'status': status.toString().split('.').last,
      'upvotes': upvotes,
      'upvoters': upvoters,
      'answer': answer,
      'answeredBy': answeredBy,
      'answeredAt': answeredAt?.toIso8601String(),
    };
  }

  static QAQuestion fromJson(Map<String, dynamic> json) {
    return QAQuestion(
      id: json['id'] as String,
      meetingId: json['meetingId'] as String,
      askedBy: json['askedBy'] as String,
      question: json['question'] as String,
      anonymous: json['anonymous'] as bool,
      askedAt: DateTime.parse(json['askedAt'] as String),
      status: QAStatus.values.firstWhere(
        (e) => e.toString() == 'QAStatus.${json['status']}',
        orElse: () => QAStatus.pending,
      ),
      upvotes: json['upvotes'] as int,
      upvoters: (json['upvoters'] as List?)?.cast<String>(),
      answer: json['answer'] as String?,
      answeredBy: json['answeredBy'] as String?,
      answeredAt:
          json['answeredAt'] != null
              ? DateTime.parse(json['answeredAt'] as String)
              : null,
    );
  }
}

/// Statut d'une question Q&A
enum QAStatus { pending, answered, archived }
