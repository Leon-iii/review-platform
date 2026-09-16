import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/statistics_summary.dart';
import 'package:review_platform/domain/services/statistics_calculator.dart';

void main() {
  test('기간·폴더 통계와 각 문제의 최신 오답을 Attempt에서 계산한다', () {
    final now = DateTime.utc(2026, 9, 16, 12);
    final attempts = [
      _attempt(
        id: 'q1-old-wrong',
        questionId: 'q1',
        answeredAt: now.subtract(const Duration(days: 40)),
        score: 0,
      ),
      _attempt(
        id: 'q2-wrong',
        questionId: 'q2',
        answeredAt: now.subtract(const Duration(days: 10)),
        score: 0,
      ),
      _attempt(
        id: 'q1-latest-correct',
        questionId: 'q1',
        answeredAt: now.subtract(const Duration(days: 2)),
        score: 1,
      ),
    ];

    final summary = StatisticsCalculator.calculate(
      StatisticsSourceData(
        attempts: attempts,
        activeQuestionCount: 3,
        folderIdByQuestionId: const {'q1': 'f1', 'q2': 'f2'},
        folderNameById: const {'f1': '물리', 'f2': '수학'},
      ),
      now: now,
    );

    expect(summary.totalQuestionCount, 3);
    expect(summary.totalAttemptCount, 3);
    expect(summary.total.accuracyPercent, 33);
    expect(summary.last7Days.accuracyPercent, 100);
    expect(summary.last30Days.accuracyPercent, 50);
    expect(summary.folderStatistics, hasLength(2));
    expect(summary.recentWrongQuestions, hasLength(1));
    expect(summary.recentWrongQuestions.single.attempt.questionId, 'q2');
  });
}

Attempt _attempt({
  required String id,
  required String questionId,
  required DateTime answeredAt,
  required double score,
}) {
  return Attempt(
    id: id,
    questionId: questionId,
    sessionId: 'session',
    answeredAt: answeredAt,
    response: const {'textAnswer': '답'},
    questionSnapshot: QuestionSnapshot(
      questionId: questionId,
      type: QuestionType.shortAnswer,
      prompt: '$questionId 문제',
      choices: const [],
      acceptableAnswers: const ['정답'],
    ),
    score: score,
    maxScore: 1,
    gradingType: GradingType.local,
    durationMs: 100,
    createdAt: answeredAt,
  );
}
