import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/folders.dart';

@DataClassName('QuestionRow')
class Questions extends Table {
  TextColumn get id => text()();

  TextColumn get folderId => text().references(Folders, #id)();

  TextColumn get type => text()();

  TextColumn get status => text()();

  TextColumn get prompt => text()();

  TextColumn get explanation => text().nullable()();

  IntColumn get difficulty => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
