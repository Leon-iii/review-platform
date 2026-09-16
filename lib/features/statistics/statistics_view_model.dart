import 'package:review_platform/domain/models/statistics_summary.dart';
import 'package:review_platform/domain/services/statistics_calculator.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'statistics_view_model.g.dart';

@riverpod
Stream<StatisticsSummary> statistics(Ref ref) {
  return ref
      .watch(statisticsRepositoryProvider)
      .watchStatisticsData()
      .map(StatisticsCalculator.calculate);
}
