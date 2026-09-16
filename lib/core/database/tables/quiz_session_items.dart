import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/questions.dart';
import 'package:review_platform/core/database/tables/quiz_sessions.dart';

@DataClassName('QuizSessionItemRow')
class QuizSessionItems extends Table {
  TextColumn get id => text()();

  TextColumn get sessionId => text().references(QuizSessions, #id)();

  TextColumn get questionId => text().references(Questions, #id)();

  IntColumn get position => integer()();

  TextColumn get questionSnapshotJson => text()();

  TextColumn get attemptId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {sessionId, position},
  ];
}
