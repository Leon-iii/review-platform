import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/study_sources.dart';

@DataClassName('ConceptRow')
class Concepts extends Table {
  TextColumn get id => text()();

  TextColumn get sourceId => text().references(StudySources, #id)();

  TextColumn get title => text()();

  TextColumn get content => text()();

  TextColumn get pageNumbersJson => text()();

  TextColumn get status => text()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
