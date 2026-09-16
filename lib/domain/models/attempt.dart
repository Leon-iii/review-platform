import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';

class Attempt {
  const Attempt({
    required this.id,
    required this.questionId,
    required this.sessionId,
    required this.answeredAt,
    required this.response,
    required this.questionSnapshot,
    required this.score,
    required this.maxScore,
    required this.gradingType,
    required this.durationMs,
    required this.createdAt,
  });

  final String id;
  final String questionId;
  final String sessionId;
  final DateTime answeredAt;
  final Map<String, Object?> response;
  final QuestionSnapshot questionSnapshot;
  final double score;
  final double maxScore;
  final GradingType gradingType;
  final int durationMs;
  final DateTime createdAt;
}

class AttemptDraft {
  const AttemptDraft({
    required this.questionId,
    required this.sessionId,
    required this.response,
    required this.questionSnapshot,
    required this.score,
    required this.maxScore,
    required this.gradingType,
    required this.durationMs,
  });

  final String questionId;
  final String sessionId;
  final Map<String, Object?> response;
  final QuestionSnapshot questionSnapshot;
  final double score;
  final double maxScore;
  final GradingType gradingType;
  final int durationMs;
}
