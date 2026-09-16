import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/questions.dart';
import 'package:review_platform/core/database/tables/quiz_sessions.dart';

@DataClassName('AttemptRow')
class Attempts extends Table {
  TextColumn get id => text()();

  TextColumn get questionId => text().references(Questions, #id)();

  TextColumn get sessionId => text().references(QuizSessions, #id)();

  DateTimeColumn get answeredAt => dateTime()();

  TextColumn get responseJson => text()();

  TextColumn get questionSnapshotJson => text()();

  RealColumn get score => real()();

  RealColumn get maxScore => real()();

  TextColumn get gradingType => text()();

  IntColumn get durationMs => integer()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
