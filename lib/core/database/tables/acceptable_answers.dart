import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/questions.dart';

@DataClassName('AcceptableAnswerRow')
class AcceptableAnswers extends Table {
  TextColumn get id => text()();

  TextColumn get questionId => text().references(Questions, #id)();

  TextColumn get answerText => text().named('text')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
