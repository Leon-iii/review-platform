import 'package:review_platform/domain/models/attempt.dart';

class AccuracyMetric {
  const AccuracyMetric({required this.score, required this.maxScore});

  final double score;
  final double maxScore;

  int get accuracyPercent =>
      maxScore == 0 ? 0 : ((score / maxScore) * 100).round();
}

class FolderStatistics {
  const FolderStatistics({
    required this.folderId,
    required this.folderName,
    required this.attemptCount,
    required this.score,
    required this.maxScore,
  });

  final String folderId;
  final String folderName;
  final int attemptCount;
  final double score;
  final double maxScore;

  int get accuracyPercent =>
      maxScore == 0 ? 0 : ((score / maxScore) * 100).round();
}

class RecentWrongQuestion {
  const RecentWrongQuestion({
    required this.attempt,
    required this.folderId,
    required this.folderName,
  });

  final Attempt attempt;
  final String folderId;
  final String folderName;
}

class StatisticsSummary {
  const StatisticsSummary({
    required this.totalQuestionCount,
    required this.totalAttemptCount,
    required this.total,
    required this.last7Days,
    required this.last30Days,
    required this.todayAttemptCount,
    required this.folderStatistics,
    required this.recentWrongQuestions,
    this.lastAnsweredAt,
  });

  final int totalQuestionCount;
  final int totalAttemptCount;
  final AccuracyMetric total;
  final AccuracyMetric last7Days;
  final AccuracyMetric last30Days;
  final int todayAttemptCount;
  final List<FolderStatistics> folderStatistics;
  final List<RecentWrongQuestion> recentWrongQuestions;
  final DateTime? lastAnsweredAt;
}

class StatisticsSourceData {
  const StatisticsSourceData({
    required this.attempts,
    required this.activeQuestionCount,
    required this.folderIdByQuestionId,
    required this.folderNameById,
  });

  final List<Attempt> attempts;
  final int activeQuestionCount;
  final Map<String, String> folderIdByQuestionId;
  final Map<String, String> folderNameById;
}
