import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/attempts.dart';
import 'package:review_platform/core/database/tables/folders.dart';
import 'package:review_platform/core/database/tables/questions.dart';

part 'statistics_dao.g.dart';

class StatisticsDatabaseSnapshot {
  const StatisticsDatabaseSnapshot({
    required this.attempts,
    required this.questions,
    required this.folders,
  });

  final List<AttemptRow> attempts;
  final List<QuestionRow> questions;
  final List<FolderRow> folders;
}

@DriftAccessor(tables: [Attempts, Questions, Folders])
class StatisticsDao extends DatabaseAccessor<AppDatabase>
    with _$StatisticsDaoMixin {
  StatisticsDao(super.attachedDatabase);

  Stream<StatisticsDatabaseSnapshot> watchSnapshot() async* {
    final changes = customSelect(
      'SELECT 1 AS value',
      readsFrom: {attempts, questions, folders},
    ).watch();

    await for (final _ in changes) {
      final results = await Future.wait([
        (select(
          attempts,
        )..orderBy([(attempt) => OrderingTerm.desc(attempt.answeredAt)])).get(),
        select(questions).get(),
        select(folders).get(),
      ]);
      yield StatisticsDatabaseSnapshot(
        attempts: results[0] as List<AttemptRow>,
        questions: results[1] as List<QuestionRow>,
        folders: results[2] as List<FolderRow>,
      );
    }
  }
}
