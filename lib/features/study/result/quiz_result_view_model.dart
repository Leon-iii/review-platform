import 'package:review_platform/core/errors/app_failure.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/repositories/quiz_answer_correction_repository.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/quiz_session.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'quiz_result_view_model.g.dart';

final quizAnswerCorrectionRepositoryProvider = Provider(
  (ref) => QuizAnswerCorrectionRepository(ref.watch(appDatabaseProvider)),
);

class QuizResultSummary {
  const QuizResultSummary({
    required this.session,
    required this.attempts,
    this.skippedQuestions = 0,
  });

  final QuizSession session;
  final List<Attempt> attempts;
  final int skippedQuestions;
  bool get stopped =>
      session.completedQuestions + skippedQuestions < session.totalQuestions;

  int get correctCount =>
      attempts.where((attempt) => attempt.score == attempt.maxScore).length;

  List<Attempt> get wrongAttempts => attempts
      .where((attempt) => attempt.score < attempt.maxScore)
      .toList(growable: false);

  double get totalScore => attempts.fold(0, (sum, item) => sum + item.score);

  double get maxScore => attempts.fold(0, (sum, item) => sum + item.maxScore);

  int get accuracyPercent =>
      maxScore == 0 ? 0 : ((totalScore / maxScore) * 100).round();
}

@riverpod
Future<QuizResultSummary> quizResult(Ref ref, String sessionId) async {
  final details = await ref.watch(quizRepositoryProvider).getSession(sessionId);
  if (details == null) {
    throw const ValidationFailure('학습 세션을 찾을 수 없어요.');
  }
  final attempts = await ref
      .watch(attemptRepositoryProvider)
      .getAttemptsForSession(sessionId);
  return QuizResultSummary(
    session: details.session,
    attempts: attempts,
    skippedQuestions: details.skippedQuestions,
  );
}
