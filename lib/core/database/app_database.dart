import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:review_platform/core/database/daos/attempt_dao.dart';
import 'package:review_platform/core/database/daos/folder_dao.dart';
import 'package:review_platform/core/database/daos/question_dao.dart';
import 'package:review_platform/core/database/daos/quiz_dao.dart';
import 'package:review_platform/core/database/daos/statistics_dao.dart';
import 'package:review_platform/core/database/daos/sync_dao.dart';
import 'package:review_platform/core/database/tables/acceptable_answers.dart';
import 'package:review_platform/core/database/tables/attempts.dart';
import 'package:review_platform/core/database/tables/folders.dart';
import 'package:review_platform/core/database/tables/question_choices.dart';
import 'package:review_platform/core/database/tables/questions.dart';
import 'package:review_platform/core/database/tables/quiz_session_items.dart';
import 'package:review_platform/core/database/tables/quiz_sessions.dart';
import 'package:review_platform/core/database/tables/sync_outbox.dart';
import 'package:review_platform/core/database/tables/sync_states.dart';
import 'package:uuid/uuid.dart';

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
    SyncOutbox,
    SyncStates,
  ],
  daos: [FolderDao, QuestionDao, QuizDao, AttemptDao, StatisticsDao, SyncDao],
)
final class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  AppDatabase.defaults() : super(driftDatabase(name: 'review_platform'));

  @override
  int get schemaVersion => 6;

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
      if (from < 5) {
        await migrator.createTable(syncOutbox);
        await migrator.createTable(syncStates);
      }
      if (from < 6) {
        await _seedExistingEntitiesForSync();
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _seedExistingEntitiesForSync() async {
    const uuid = Uuid();
    final folderRows = await select(folders).get();
    final questionRows = await select(questions).get();
    final sessionRows = await select(quizSessions).get();
    final attemptRows = await select(attempts).get();
    await batch((batch) {
      for (final folder in folderRows) {
        batch.insert(
          syncOutbox,
          SyncOutboxCompanion.insert(
            id: uuid.v4(),
            entityType: 'folder',
            entityId: folder.id,
            operation: folder.deletedAt == null ? 'upsert' : 'delete',
            createdAt: folder.updatedAt,
          ),
        );
      }
      for (final question in questionRows) {
        batch.insert(
          syncOutbox,
          SyncOutboxCompanion.insert(
            id: uuid.v4(),
            entityType: 'question',
            entityId: question.id,
            operation: question.deletedAt == null ? 'upsert' : 'delete',
            createdAt: question.updatedAt,
          ),
        );
      }
      for (final session in sessionRows) {
        batch.insert(
          syncOutbox,
          SyncOutboxCompanion.insert(
            id: uuid.v4(),
            entityType: 'quizSession',
            entityId: session.id,
            operation: session.deletedAt == null ? 'upsert' : 'delete',
            createdAt: session.updatedAt,
          ),
        );
      }
      for (final attempt in attemptRows) {
        batch.insert(
          syncOutbox,
          SyncOutboxCompanion.insert(
            id: uuid.v4(),
            entityType: 'attempt',
            entityId: attempt.id,
            operation: 'upsert',
            createdAt: attempt.createdAt,
          ),
        );
      }
    });
  }
}
