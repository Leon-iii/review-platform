import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/quiz_session_items.dart';
import 'package:review_platform/core/database/tables/quiz_sessions.dart';

part 'quiz_dao.g.dart';

@DriftAccessor(tables: [QuizSessions, QuizSessionItems])
class QuizDao extends DatabaseAccessor<AppDatabase> with _$QuizDaoMixin {
  QuizDao(super.attachedDatabase);

  Future<void> insertSession(QuizSessionsCompanion session) {
    return into(quizSessions).insert(session);
  }

  Future<void> insertItems(List<QuizSessionItemsCompanion> items) {
    return batch((batch) => batch.insertAll(quizSessionItems, items));
  }

  Future<QuizSessionRow?> getActiveSession(String id) {
    return (select(quizSessions)..where(
          (session) => session.id.equals(id) & session.deletedAt.isNull(),
        ))
        .getSingleOrNull();
  }

  Future<QuizSessionRow?> getSession(String id) {
    return (select(
      quizSessions,
    )..where((session) => session.id.equals(id))).getSingleOrNull();
  }

  Future<void> upsertSession(QuizSessionsCompanion session) {
    return into(quizSessions).insertOnConflictUpdate(session);
  }

  Future<List<QuizSessionItemRow>> getSessionItems(String sessionId) {
    return (select(quizSessionItems)
          ..where((item) => item.sessionId.equals(sessionId))
          ..orderBy([(item) => OrderingTerm.asc(item.position)]))
        .get();
  }

  Future<void> replaceSessionItems(
    String sessionId,
    List<QuizSessionItemsCompanion> items,
  ) async {
    await (delete(
      quizSessionItems,
    )..where((item) => item.sessionId.equals(sessionId))).go();
    await batch((batch) => batch.insertAll(quizSessionItems, items));
  }

  Future<void> linkAttempt({
    required String itemId,
    required String attemptId,
  }) {
    return (update(quizSessionItems)..where((item) => item.id.equals(itemId)))
        .write(QuizSessionItemsCompanion(attemptId: Value(attemptId)));
  }

  Future<void> updateProgress({
    required String sessionId,
    required int completedQuestions,
    required DateTime updatedAt,
  }) {
    return (update(
      quizSessions,
    )..where((row) => row.id.equals(sessionId))).write(
      QuizSessionsCompanion(
        completedQuestions: Value(completedQuestions),
        updatedAt: Value(updatedAt),
      ),
    );
  }

  Future<void> finishSession({
    required String sessionId,
    required DateTime finishedAt,
  }) {
    return (update(
      quizSessions,
    )..where((row) => row.id.equals(sessionId))).write(
      QuizSessionsCompanion(
        finishedAt: Value(finishedAt),
        updatedAt: Value(finishedAt),
      ),
    );
  }

  Future<void> softDeleteSession({
    required String sessionId,
    required DateTime deletedAt,
  }) {
    return (update(
      quizSessions,
    )..where((session) => session.id.equals(sessionId))).write(
      QuizSessionsCompanion(
        updatedAt: Value(deletedAt),
        deletedAt: Value(deletedAt),
      ),
    );
  }
}
