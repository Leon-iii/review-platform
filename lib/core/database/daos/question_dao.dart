import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/acceptable_answers.dart';
import 'package:review_platform/core/database/tables/question_choices.dart';
import 'package:review_platform/core/database/tables/questions.dart';

part 'question_dao.g.dart';

@DriftAccessor(tables: [Questions, QuestionChoices, AcceptableAnswers])
class QuestionDao extends DatabaseAccessor<AppDatabase>
    with _$QuestionDaoMixin {
  QuestionDao(super.attachedDatabase);

  Stream<List<QuestionRow>> watchActiveQuestions(String folderId) {
    return (select(questions)
          ..where(
            (question) =>
                question.folderId.equals(folderId) &
                question.deletedAt.isNull(),
          )
          ..orderBy([(question) => OrderingTerm.desc(question.updatedAt)]))
        .watch();
  }

  Future<QuestionRow?> getActiveQuestion(String id) {
    return (select(questions)..where(
          (question) => question.id.equals(id) & question.deletedAt.isNull(),
        ))
        .getSingleOrNull();
  }

  Future<List<QuestionRow>> getEligibleQuestions({
    required List<String> folderIds,
    required List<String> types,
  }) {
    if (folderIds.isEmpty || types.isEmpty) return Future.value(const []);

    return (select(questions)..where(
          (question) =>
              question.folderId.isIn(folderIds) &
              question.type.isIn(types) &
              question.status.equals('approved') &
              question.deletedAt.isNull(),
        ))
        .get();
  }

  Future<List<QuestionChoiceRow>> getChoices(String questionId) {
    return (select(questionChoices)
          ..where((choice) => choice.questionId.equals(questionId))
          ..orderBy([(choice) => OrderingTerm.asc(choice.position)]))
        .get();
  }

  Future<List<AcceptableAnswerRow>> getAcceptableAnswers(String questionId) {
    return (select(
      acceptableAnswers,
    )..where((answer) => answer.questionId.equals(questionId))).get();
  }

  Future<void> insertQuestion(QuestionsCompanion question) {
    return into(questions).insert(question);
  }

  Future<void> updateQuestion(String id, QuestionsCompanion question) {
    return (update(
      questions,
    )..where((row) => row.id.equals(id))).write(question);
  }

  Future<void> replaceChoices(
    String questionId,
    List<QuestionChoicesCompanion> choices,
  ) async {
    await (delete(
      questionChoices,
    )..where((choice) => choice.questionId.equals(questionId))).go();
    await batch((batch) => batch.insertAll(questionChoices, choices));
  }

  Future<void> replaceAcceptableAnswers(
    String questionId,
    List<AcceptableAnswersCompanion> answers,
  ) async {
    await (delete(
      acceptableAnswers,
    )..where((answer) => answer.questionId.equals(questionId))).go();
    await batch((batch) => batch.insertAll(acceptableAnswers, answers));
  }

  Future<void> softDeleteQuestion(String id, DateTime deletedAt) {
    return (update(
      questions,
    )..where((question) => question.id.equals(id))).write(
      QuestionsCompanion(
        updatedAt: Value(deletedAt),
        deletedAt: Value(deletedAt),
      ),
    );
  }

  Future<int> countActiveQuestionsInFolders(Iterable<String> folderIds) async {
    final ids = folderIds.toList(growable: false);
    if (ids.isEmpty) return 0;

    final countExpression = questions.id.count();
    final query = selectOnly(questions)
      ..addColumns([countExpression])
      ..where(questions.folderId.isIn(ids) & questions.deletedAt.isNull());
    final row = await query.getSingle();
    return row.read(countExpression) ?? 0;
  }

  Future<void> softDeleteQuestionsInFolders({
    required Iterable<String> folderIds,
    required DateTime deletedAt,
  }) {
    final ids = folderIds.toList(growable: false);
    if (ids.isEmpty) return Future.value();

    return (update(
      questions,
    )..where((question) => question.folderId.isIn(ids))).write(
      QuestionsCompanion(
        updatedAt: Value(deletedAt),
        deletedAt: Value(deletedAt),
      ),
    );
  }
}
