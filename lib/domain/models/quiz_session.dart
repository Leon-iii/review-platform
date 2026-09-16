import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';

class QuizSession {
  const QuizSession({
    required this.id,
    required this.startedAt,
    required this.totalQuestions,
    required this.completedQuestions,
    required this.filter,
    required this.createdAt,
    required this.updatedAt,
    this.finishedAt,
    this.sourceFolderId,
    this.deletedAt,
  });

  final String id;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String? sourceFolderId;
  final int totalQuestions;
  final int completedQuestions;
  final QuizFilter filter;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

class QuizSessionItem {
  const QuizSessionItem({
    required this.id,
    required this.sessionId,
    required this.questionId,
    required this.position,
    required this.questionSnapshot,
    this.attemptId,
  });

  final String id;
  final String sessionId;
  final String questionId;
  final int position;
  final QuestionSnapshot questionSnapshot;
  final String? attemptId;
}

class QuizSessionDetails {
  const QuizSessionDetails({required this.session, required this.items});

  final QuizSession session;
  final List<QuizSessionItem> items;
}
