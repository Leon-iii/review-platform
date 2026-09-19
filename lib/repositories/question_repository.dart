import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/services/question_validator.dart';
import 'package:uuid/uuid.dart';

abstract interface class QuestionRepository {
  Future<String> createQuestion(QuestionDraft draft);

  Future<List<String>> createQuestions(List<QuestionDraft> drafts);

  Future<void> updateQuestion(String id, QuestionDraft draft);

  Future<void> deleteQuestion(String id);

  Future<void> approveQuestion(String id);

  Future<void> approveQuestions(Iterable<String> ids);

  Stream<List<Question>> watchQuestions(String folderId);

  Future<Question?> getQuestion(String id);

  Future<List<Question>> getEligibleQuestions({
    required List<String> folderIds,
    required Set<QuestionType> types,
  });
}

class DriftQuestionRepository implements QuestionRepository {
  DriftQuestionRepository(this._database);

  final AppDatabase _database;
  final Uuid _uuid = const Uuid();

  @override
  Future<String> createQuestion(QuestionDraft draft) {
    return createQuestions([draft]).then((ids) => ids.single);
  }

  @override
  Future<List<String>> createQuestions(List<QuestionDraft> drafts) {
    return _guard(() async {
      if (drafts.isEmpty) {
        throw const ValidationFailure('저장할 문제가 없어요.');
      }
      final validatedDrafts = drafts
          .map(QuestionValidator.validate)
          .toList(growable: false);
      final ids = [for (final _ in validatedDrafts) _uuid.v4()];
      final now = DateTime.now().toUtc();

      await _database.transaction(() async {
        for (var index = 0; index < validatedDrafts.length; index++) {
          final draft = validatedDrafts[index];
          final id = ids[index];
          await _requireFolder(draft.folderId);
          await _database.questionDao.insertQuestion(
            QuestionsCompanion.insert(
              id: id,
              folderId: draft.folderId,
              type: draft.type.name,
              status: draft.status.name,
              prompt: draft.prompt,
              explanation: Value(draft.explanation),
              difficulty: Value(draft.difficulty),
              createdAt: now,
              updatedAt: now,
            ),
          );
          await _replaceDetails(id, draft);
          await _database.syncDao.enqueue(
            entityType: SyncEntityType.question.name,
            entityId: id,
            operation: SyncOperation.upsert.name,
            createdAt: now,
          );
        }
      });

      return ids;
    }, '문제들을 저장하지 못했어요.');
  }

  @override
  Future<void> updateQuestion(String id, QuestionDraft draft) {
    return _guard(() async {
      final validated = QuestionValidator.validate(draft);

      await _database.transaction(() async {
        await _requireQuestion(id);
        await _requireFolder(validated.folderId);
        final now = DateTime.now().toUtc();
        await _database.questionDao.updateQuestion(
          id,
          QuestionsCompanion(
            folderId: Value(validated.folderId),
            type: Value(validated.type.name),
            status: Value(validated.status.name),
            prompt: Value(validated.prompt),
            explanation: Value(validated.explanation),
            difficulty: Value(validated.difficulty),
            updatedAt: Value(now),
          ),
        );
        await _replaceDetails(id, validated);
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.question.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '문제를 수정하지 못했어요.');
  }

  @override
  Future<void> deleteQuestion(String id) {
    return _guard(() async {
      await _database.transaction(() async {
        await _requireQuestion(id);
        final now = DateTime.now().toUtc();
        await _database.questionDao.softDeleteQuestion(id, now);
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.question.name,
          entityId: id,
          operation: SyncOperation.delete.name,
          createdAt: now,
        );
      });
    }, '문제를 삭제하지 못했어요.');
  }

  @override
  Future<void> approveQuestion(String id) => approveQuestions([id]);

  @override
  Future<void> approveQuestions(Iterable<String> ids) {
    return _guard(() async {
      final values = ids.toSet().toList(growable: false);
      if (values.isEmpty) return;
      await _database.transaction(() async {
        final now = DateTime.now().toUtc();
        for (final id in values) {
          await _requireQuestion(id);
          await _database.questionDao.updateQuestion(
            id,
            QuestionsCompanion(
              status: Value(QuestionStatus.approved.name),
              updatedAt: Value(now),
            ),
          );
          await _database.syncDao.enqueue(
            entityType: SyncEntityType.question.name,
            entityId: id,
            operation: SyncOperation.upsert.name,
            createdAt: now,
          );
        }
      });
    }, '문제를 승인하지 못했어요.');
  }

  @override
  Stream<List<Question>> watchQuestions(String folderId) async* {
    try {
      await for (final rows in _database.questionDao.watchActiveQuestions(
        folderId,
      )) {
        yield await Future.wait(rows.map(_hydrate));
      }
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure('문제 목록을 불러오지 못했어요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<Question?> getQuestion(String id) {
    return _guard(() async {
      final row = await _database.questionDao.getActiveQuestion(id);
      return row == null ? null : _hydrate(row);
    }, '문제를 불러오지 못했어요.');
  }

  @override
  Future<List<Question>> getEligibleQuestions({
    required List<String> folderIds,
    required Set<QuestionType> types,
  }) {
    return _guard(() async {
      final rows = await _database.questionDao.getEligibleQuestions(
        folderIds: folderIds,
        types: types.map((type) => type.name).toList(growable: false),
      );
      return Future.wait(rows.map(_hydrate));
    }, '출제 가능한 문제를 불러오지 못했어요.');
  }

  Future<void> _replaceDetails(String questionId, QuestionDraft draft) async {
    final choiceCompanions = <QuestionChoicesCompanion>[];
    for (var index = 0; index < draft.choices.length; index++) {
      final choice = draft.choices[index];
      choiceCompanions.add(
        QuestionChoicesCompanion.insert(
          id: _uuid.v4(),
          questionId: questionId,
          position: index,
          choiceText: choice.text,
          isCorrect: choice.isCorrect,
        ),
      );
    }

    final answerCompanions = [
      for (final answer in draft.acceptableAnswers)
        AcceptableAnswersCompanion.insert(
          id: _uuid.v4(),
          questionId: questionId,
          answerText: answer,
        ),
    ];

    await _database.questionDao.replaceChoices(questionId, choiceCompanions);
    await _database.questionDao.replaceAcceptableAnswers(
      questionId,
      answerCompanions,
    );
  }

  Future<Question> _hydrate(QuestionRow row) async {
    final results = await Future.wait([
      _database.questionDao.getChoices(row.id),
      _database.questionDao.getAcceptableAnswers(row.id),
    ]);
    final choices = results[0] as List<QuestionChoiceRow>;
    final answers = results[1] as List<AcceptableAnswerRow>;

    return Question(
      id: row.id,
      folderId: row.folderId,
      type: QuestionType.fromStorage(row.type),
      status: QuestionStatus.fromStorage(row.status),
      prompt: row.prompt,
      explanation: row.explanation,
      difficulty: row.difficulty,
      choices: List.unmodifiable(
        choices.map(
          (choice) => QuestionChoice(
            id: choice.id,
            position: choice.position,
            text: choice.choiceText,
            isCorrect: choice.isCorrect,
          ),
        ),
      ),
      acceptableAnswers: List.unmodifiable(
        answers.map(
          (answer) => AcceptableAnswer(id: answer.id, text: answer.answerText),
        ),
      ),
      createdAt: row.createdAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
      deletedAt: row.deletedAt?.toUtc(),
    );
  }

  Future<void> _requireFolder(String id) async {
    if (await _database.folderDao.getActiveFolder(id) == null) {
      throw const ValidationFailure('문제를 저장할 폴더를 찾을 수 없어요.');
    }
  }

  Future<QuestionRow> _requireQuestion(String id) async {
    final question = await _database.questionDao.getActiveQuestion(id);
    if (question == null) {
      throw const ValidationFailure('문제를 찾을 수 없어요.');
    }
    return question;
  }

  Future<T> _guard<T>(Future<T> Function() action, String message) async {
    try {
      return await action();
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure(message, cause: error),
        stackTrace,
      );
    }
  }
}
