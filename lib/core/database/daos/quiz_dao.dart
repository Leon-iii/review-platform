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

  Future<List<QuizSessionItemRow>> getSessionItems(String sessionId) {
    return (select(quizSessionItems)
          ..where((item) => item.sessionId.equals(sessionId))
          ..orderBy([(item) => OrderingTerm.asc(item.position)]))
        .get();
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
}
