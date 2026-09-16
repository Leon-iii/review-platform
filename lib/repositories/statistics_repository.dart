import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/statistics_summary.dart';
import 'package:review_platform/repositories/attempt_repository.dart';

abstract interface class StatisticsRepository {
  Stream<StatisticsSourceData> watchStatisticsData();
}

class DriftStatisticsRepository implements StatisticsRepository {
  DriftStatisticsRepository(this._database);

  final AppDatabase _database;

  @override
  Stream<StatisticsSourceData> watchStatisticsData() async* {
    try {
      await for (final snapshot in _database.statisticsDao.watchSnapshot()) {
        yield StatisticsSourceData(
          attempts: List.unmodifiable(snapshot.attempts.map(mapAttemptRow)),
          activeQuestionCount: snapshot.questions
              .where((question) => question.deletedAt == null)
              .length,
          folderIdByQuestionId: {
            for (final question in snapshot.questions)
              question.id: question.folderId,
          },
          folderNameById: {
            for (final folder in snapshot.folders) folder.id: folder.name,
          },
        );
      }
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure('통계 데이터를 불러오지 못했어요.', cause: error),
        stackTrace,
      );
    }
  }
}
