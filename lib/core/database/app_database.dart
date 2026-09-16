import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:review_platform/core/database/daos/attempt_dao.dart';
import 'package:review_platform/core/database/daos/folder_dao.dart';
import 'package:review_platform/core/database/daos/question_dao.dart';
import 'package:review_platform/core/database/daos/quiz_dao.dart';
import 'package:review_platform/core/database/daos/statistics_dao.dart';
import 'package:review_platform/core/database/tables/acceptable_answers.dart';
import 'package:review_platform/core/database/tables/attempts.dart';
import 'package:review_platform/core/database/tables/folders.dart';
import 'package:review_platform/core/database/tables/question_choices.dart';
import 'package:review_platform/core/database/tables/questions.dart';
import 'package:review_platform/core/database/tables/quiz_session_items.dart';
import 'package:review_platform/core/database/tables/quiz_sessions.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Folders,
    Questions,
    QuestionChoices,
    AcceptableAnswers,
    QuizSessions,
    Attempts,
    QuizSessionItems,
  ],
  daos: [FolderDao, QuestionDao, QuizDao, AttemptDao, StatisticsDao],
)
final class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  AppDatabase.defaults() : super(driftDatabase(name: 'review_platform'));

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.createTable(folders);
      }
      if (from < 3) {
        await migrator.createTable(questions);
        await migrator.createTable(questionChoices);
        await migrator.createTable(acceptableAnswers);
      }
      if (from < 4) {
        await migrator.createTable(quizSessions);
        await migrator.createTable(attempts);
        await migrator.createTable(quizSessionItems);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
