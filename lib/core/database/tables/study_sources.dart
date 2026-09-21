import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/folders.dart';

@DataClassName('StudySourceRow')
class StudySources extends Table {
  @override
  String get tableName => 'sources';

  TextColumn get id => text()();

  TextColumn get folderId => text().references(Folders, #id)();

  TextColumn get fileName => text()();

  TextColumn get contentHash => text()();

  IntColumn get pageCount => integer()();

  TextColumn get extractionMethod => text()();

  DateTimeColumn get importedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
