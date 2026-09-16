import 'package:drift/drift.dart';
import 'package:review_platform/core/database/tables/questions.dart';

@DataClassName('QuestionChoiceRow')
class QuestionChoices extends Table {
  TextColumn get id => text()();

  TextColumn get questionId => text().references(Questions, #id)();

  IntColumn get position => integer()();

  TextColumn get choiceText => text().named('text')();

  BoolColumn get isCorrect => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {questionId, position},
  ];
}
