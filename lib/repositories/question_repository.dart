import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/services/question_validator.dart';
import 'package:uuid/uuid.dart';

abstract interface class QuestionRepository {
  Future<String> createQuestion(
    QuestionDraft draft, {
    String? primaryConceptId,
  });

  Future<List<String>> createQuestions(
    List<QuestionDraft> drafts, {
    List<QuestionSourceDraft?>? sourceReferences,
  });

  Future<void> updateQuestion(
    String id,
    QuestionDraft draft, {
    String? primaryConceptId,
    bool replacePrimaryConcept = false,
    ConceptImportance? detachedImportance,
  });

  Future<void> moveQuestion({required String id, required String folderId});

  Future<void> deleteQuestion(String id);

  Future<void> approveQuestion(String id);

  Future<void> approveQuestions(Iterable<String> ids);

  Future<void> moveQuestions({
    required Iterable<String> ids,
    required String folderId,
  });

  Future<void> deleteQuestions(Iterable<String> ids);

  Stream<List<Question>> watchQuestionsForConcept(String conceptId);

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
  Future<String> createQuestion(
    QuestionDraft draft, {
    String? primaryConceptId,
  }) {
    return _guard(
      () => _database.transaction(() async {
        final reference = primaryConceptId == null
            ? null
            : await _referenceForConcept(primaryConceptId);
        return (await createQuestions(
          [draft],
          sourceReferences: [reference],
        )).single;
      }),
      '문제를 저장하지 못했어요.',
    );
  }

  @override
  Future<List<String>> createQuestions(
    List<QuestionDraft> drafts, {
    List<QuestionSourceDraft?>? sourceReferences,
  }) {
    return _guard(() async {
      if (drafts.isEmpty) {
        throw const ValidationFailure('저장할 문제가 없어요.');
      }
      if (sourceReferences != null &&
          sourceReferences.length != drafts.length) {
        throw const ValidationFailure('문제와 출처 정보의 개수가 일치하지 않아요.');
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
              importance: Value(draft.importance.name),
              caseSensitive: Value(draft.caseSensitive),
              whitespaceSensitive: Value(draft.whitespaceSensitive),
              createdAt: now,
              updatedAt: now,
            ),
          );
          await _replaceDetails(id, draft);
          final sourceReference = sourceReferences?[index];
          if (sourceReference != null) {
            await _insertSourceReference(id, sourceReference);
          }
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
  Future<void> updateQuestion(
    String id,
    QuestionDraft draft, {
    String? primaryConceptId,
    bool replacePrimaryConcept = false,
    ConceptImportance? detachedImportance,
  }) {
    return _guard(() async {
      final validated = QuestionValidator.validate(draft);

      await _database.transaction(() async {
        final existing = await _requireQuestion(id);
        final reference = replacePrimaryConcept && primaryConceptId != null
            ? await _referenceForConcept(primaryConceptId)
            : null;
        final importance = replacePrimaryConcept && primaryConceptId == null
            ? detachedImportance ?? (await _hydrate(existing)).importance
            : validated.importance;
        await _requireFolder(validated.folderId);
        final now = _nextQuestionVersion(existing);
        await _database.questionDao.updateQuestion(
          id,
          QuestionsCompanion(
            folderId: Value(validated.folderId),
            type: Value(validated.type.name),
            status: Value(validated.status.name),
            prompt: Value(validated.prompt),
            explanation: Value(validated.explanation),
            difficulty: Value(validated.difficulty),
            importance: Value(importance.name),
            caseSensitive: Value(validated.caseSensitive),
            whitespaceSensitive: Value(validated.whitespaceSensitive),
            updatedAt: Value(now),
          ),
        );
        await _replaceDetails(id, validated);
        if (replacePrimaryConcept) {
          if (reference == null) {
            // Detach the concept, not the original material/page provenance.
            await (_database.update(_database.questionSources)
                  ..where((row) => row.questionId.equals(id)))
                .write(const QuestionSourcesCompanion(conceptId: Value(null)));
          } else {
            await _database.sourceDao.replaceQuestionSources(id, []);
            await _insertSourceReference(id, reference);
          }
        }
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
  Future<void> moveQuestion({required String id, required String folderId}) {
    return _guard(() async {
      await _database.transaction(() async {
        final question = await _requireQuestion(id);
        await _requireFolder(folderId);
        if (question.folderId == folderId) return;

        final now = _nextQuestionVersion(question);
        // Keep choice/answer IDs and history intact; moving is not an edit.
        await _database.questionDao.updateQuestion(
          id,
          QuestionsCompanion(folderId: Value(folderId), updatedAt: Value(now)),
        );
        await _database.syncDao.enqueue(
          entityType: SyncEntityType.question.name,
          entityId: id,
          operation: SyncOperation.upsert.name,
          createdAt: now,
        );
      });
    }, '문제를 이동하지 못했어요.');
  }

  @override
  Future<void> deleteQuestion(String id) {
    return _guard(() async {
      await _database.transaction(() async {
        final question = await _requireQuestion(id);
        final now = _nextQuestionVersion(question);
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
  Future<void> moveQuestions({
    required Iterable<String> ids,
    required String folderId,
  }) {
    final values = ids.toSet().toList(growable: false);
    return _guard(
      () => _database.transaction(() async {
        await _requireFolder(folderId);
        for (final id in values) {
          await moveQuestion(id: id, folderId: folderId);
        }
      }),
      '선택한 문제를 이동하지 못했어요.',
    );
  }

  @override
  Future<void> deleteQuestions(Iterable<String> ids) {
    final values = ids.toSet().toList(growable: false);
    return _guard(
      () => _database.transaction(() async {
        for (final id in values) {
          await deleteQuestion(id);
        }
      }),
      '선택한 문제를 삭제하지 못했어요.',
    );
  }

  @override
  Stream<List<Question>> watchQuestionsForConcept(String conceptId) async* {
    try {
      await for (final rows in _database.questionDao.watchQuestionsForConcept(
        conceptId,
      )) {
        yield await Future.wait(rows.map(_hydrate));
      }
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DatabaseFailure('연결된 문제를 불러오지 못했어요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<void> approveQuestions(Iterable<String> ids) {
    return _guard(() async {
      final values = ids.toSet().toList(growable: false);
      if (values.isEmpty) return;
      await _database.transaction(() async {
        for (final id in values) {
          final question = await _requireQuestion(id);
          final now = _nextQuestionVersion(question);
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
    await _database.questionDao.updateQuestion(
      questionId,
      QuestionsCompanion(
        correctChoiceIdsJson: Value(
          jsonEncode([
            for (final position in draft.correctOrder)
              choiceCompanions[position - 1].id.value,
          ]),
        ),
      ),
    );
    await _database.questionDao.replaceAcceptableAnswers(
      questionId,
      answerCompanions,
    );
  }

  DateTime _nextQuestionVersion(QuestionRow question) {
    // A fast edit/move/delete after regrading must not regress its sync version.
    final now = DateTime.now().toUtc();
    final next = question.updatedAt.toUtc().add(const Duration(seconds: 1));
    return now.isBefore(next) ? next : now;
  }

  Future<Question> _hydrate(QuestionRow row) async {
    final results = await Future.wait([
      _database.questionDao.getChoices(row.id),
      _database.questionDao.getAcceptableAnswers(row.id),
      _database.sourceDao.getQuestionSources(row.id),
    ]);
    final choices = results[0] as List<QuestionChoiceRow>;
    final answers = results[1] as List<AcceptableAnswerRow>;
    final sourceRows = results[2] as List<QuestionSourceRow>;
    final sourceReferences = <QuestionSourceReference>[];
    var importance = ConceptImportance.fromStorage(row.importance);
    var inherited = false;
    for (final reference in sourceRows) {
      final source = await _database.sourceDao.getSource(reference.sourceId);
      if (source == null) continue;
      final concept = reference.conceptId == null
          ? null
          : await _database.sourceDao.getConcept(reference.conceptId!);
      if (concept != null && !inherited) {
        importance = ConceptImportance.fromStorage(concept.importance);
        inherited = true;
      }
      sourceReferences.add(
        QuestionSourceReference(
          sourceId: source.id,
          fileName: source.fileName,
          conceptId: concept?.id,
          conceptTitle: concept?.title,
          pageNumbers: (jsonDecode(reference.pageNumbersJson) as List)
              .map((value) => (value as num).toInt())
              .toList(growable: false),
        ),
      );
    }

    return Question(
      id: row.id,
      folderId: row.folderId,
      type: QuestionType.fromStorage(row.type),
      status: QuestionStatus.fromStorage(row.status),
      prompt: row.prompt,
      explanation: row.explanation,
      difficulty: row.difficulty ?? 3,
      caseSensitive: row.caseSensitive,
      whitespaceSensitive: row.whitespaceSensitive,
      correctChoiceIds: List.unmodifiable(
        (jsonDecode(row.correctChoiceIdsJson) as List).cast<String>(),
      ),
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
      sourceReferences: List.unmodifiable(sourceReferences),
      importance: importance,
    );
  }

  Future<void> _insertSourceReference(
    String questionId,
    QuestionSourceDraft reference,
  ) async {
    final source = await _database.sourceDao.getSource(reference.sourceId);
    if (source == null) {
      throw const ValidationFailure('문제의 원본 자료를 찾을 수 없어요.');
    }
    if (reference.conceptId != null) {
      final concept = await _database.sourceDao.getConcept(
        reference.conceptId!,
      );
      if (concept == null || concept.sourceId != reference.sourceId) {
        throw const ValidationFailure('문제의 출처 개념이 올바르지 않아요.');
      }
      await _database.questionDao.updateQuestion(
        questionId,
        QuestionsCompanion(importance: Value(concept.importance)),
      );
    }
    await _database.sourceDao.insertQuestionSource(
      QuestionSourcesCompanion.insert(
        id: _uuid.v4(),
        questionId: questionId,
        sourceId: reference.sourceId,
        conceptId: Value(reference.conceptId),
        pageNumbersJson: jsonEncode(
          reference.pageNumbers.toSet().toList()..sort(),
        ),
      ),
    );
  }

  Future<QuestionSourceDraft> _referenceForConcept(String id) async {
    final concept = await _database.sourceDao.getConcept(id);
    if (concept == null) {
      throw const ValidationFailure('선택한 주개념이 삭제되었거나 존재하지 않아요. 다시 선택해 주세요.');
    }
    return QuestionSourceDraft(
      sourceId: concept.sourceId,
      conceptId: concept.id,
      pageNumbers: (jsonDecode(concept.pageNumbersJson) as List)
          .map((page) => (page as num).toInt())
          .toList(),
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
