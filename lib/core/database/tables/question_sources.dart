import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/concepts.dart';
import 'package:review_platform/core/database/tables/questions.dart';
import 'package:review_platform/core/database/tables/study_sources.dart';

@DataClassName('QuestionSourceRow')
class QuestionSources extends Table {
  TextColumn get id => text()();

  TextColumn get questionId => text().references(Questions, #id)();

  TextColumn get sourceId => text().references(StudySources, #id)();

  TextColumn get conceptId => text().nullable().references(Concepts, #id)();

  TextColumn get pageNumbersJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
