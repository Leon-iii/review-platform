import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/folders.dart';

@DataClassName('QuizSessionRow')
class QuizSessions extends Table {
  TextColumn get id => text()();

  DateTimeColumn get startedAt => dateTime()();

  DateTimeColumn get finishedAt => dateTime().nullable()();

  TextColumn get sourceFolderId => text().nullable().references(Folders, #id)();

  IntColumn get totalQuestions => integer()();

  IntColumn get completedQuestions => integer()();

  TextColumn get filterJson => text()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
