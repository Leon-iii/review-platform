import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/statistics_summary.dart';

abstract final class StatisticsCalculator {
  static StatisticsSummary calculate(
    StatisticsSourceData source, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final sevenDaysAgo = current.toUtc().subtract(const Duration(days: 7));
    final thirtyDaysAgo = current.toUtc().subtract(const Duration(days: 30));
    final attempts = [...source.attempts]
      ..sort((a, b) => b.answeredAt.compareTo(a.answeredAt));

    final folderBuckets = <String, List<Attempt>>{};
    for (final attempt in attempts) {
      final folderId = source.folderIdByQuestionId[attempt.questionId];
      if (folderId != null) {
        folderBuckets.putIfAbsent(folderId, () => []).add(attempt);
      }
    }

    final latestByQuestion = <String, Attempt>{};
    for (final attempt in attempts) {
      latestByQuestion.putIfAbsent(attempt.questionId, () => attempt);
    }
    final recentWrong =
        latestByQuestion.values
            .where((attempt) => attempt.score < attempt.maxScore)
            .map((attempt) {
              final folderId =
                  source.folderIdByQuestionId[attempt.questionId] ?? '';
              return RecentWrongQuestion(
                attempt: attempt,
                folderId: folderId,
                folderName: source.folderNameById[folderId] ?? '삭제된 폴더',
              );
            })
            .toList(growable: false)
          ..sort(
            (a, b) => b.attempt.answeredAt.compareTo(a.attempt.answeredAt),
          );

    final localNow = current.toLocal();
    final folderStatistics =
        folderBuckets.entries
            .map((entry) {
              final metric = _metric(entry.value);
              return FolderStatistics(
                folderId: entry.key,
                folderName: source.folderNameById[entry.key] ?? '삭제된 폴더',
                attemptCount: entry.value.length,
                score: metric.score,
                maxScore: metric.maxScore,
              );
            })
            .toList(growable: false)
          ..sort((a, b) => a.folderName.compareTo(b.folderName));

    return StatisticsSummary(
      totalQuestionCount: source.activeQuestionCount,
      totalAttemptCount: attempts.length,
      total: _metric(attempts),
      last7Days: _metric(
        attempts.where(
          (attempt) => !attempt.answeredAt.toUtc().isBefore(sevenDaysAgo),
        ),
      ),
      last30Days: _metric(
        attempts.where(
          (attempt) => !attempt.answeredAt.toUtc().isBefore(thirtyDaysAgo),
        ),
      ),
      todayAttemptCount: attempts.where((attempt) {
        final date = attempt.answeredAt.toLocal();
        return date.year == localNow.year &&
            date.month == localNow.month &&
            date.day == localNow.day;
      }).length,
      folderStatistics: List.unmodifiable(folderStatistics),
      recentWrongQuestions: List.unmodifiable(recentWrong),
      lastAnsweredAt: attempts.firstOrNull?.answeredAt,
    );
  }

  static AccuracyMetric _metric(Iterable<Attempt> attempts) {
    var score = 0.0;
    var maxScore = 0.0;
    for (final attempt in attempts) {
      score += attempt.score;
      maxScore += attempt.maxScore;
    }
    return AccuracyMetric(score: score, maxScore: maxScore);
  }
}
