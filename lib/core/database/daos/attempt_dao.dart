import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/attempts.dart';

part 'attempt_dao.g.dart';

@DriftAccessor(tables: [Attempts])
class AttemptDao extends DatabaseAccessor<AppDatabase> with _$AttemptDaoMixin {
  AttemptDao(super.attachedDatabase);

  Future<void> insertAttempt(AttemptsCompanion attempt) {
    return into(attempts).insert(attempt);
  }

  Future<List<AttemptRow>> getAttemptsForSession(String sessionId) {
    return (select(attempts)
          ..where((attempt) => attempt.sessionId.equals(sessionId))
          ..orderBy([(attempt) => OrderingTerm.asc(attempt.answeredAt)]))
        .get();
  }

  Future<List<AttemptRow>> getAttemptsForQuestion(String questionId) {
    return (select(attempts)
          ..where((attempt) => attempt.questionId.equals(questionId))
          ..orderBy([(attempt) => OrderingTerm.desc(attempt.answeredAt)]))
        .get();
  }

  Future<List<AttemptRow>> getRecentAttempts(int limit) {
    return (select(attempts)
          ..orderBy([(attempt) => OrderingTerm.desc(attempt.answeredAt)])
          ..limit(limit))
        .get();
  }

  Future<List<AttemptRow>> getAllAttempts() {
    return (select(
      attempts,
    )..orderBy([(attempt) => OrderingTerm.desc(attempt.answeredAt)])).get();
  }

  Stream<List<AttemptRow>> watchAttempts() {
    return (select(
      attempts,
    )..orderBy([(attempt) => OrderingTerm.desc(attempt.answeredAt)])).watch();
  }
}
