import 'package:drift/drift.dart';

@DataClassName('FolderRow')
class Folders extends Table {
  TextColumn get id => text()();

  TextColumn get parentId => text().nullable().references(Folders, #id)();

  TextColumn get name => text()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
