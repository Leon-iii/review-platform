import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

void main() {
  late AppDatabase database;
  late DriftFolderRepository folders;
  late DriftQuestionRepository questions;
  late DriftSourceRepository sources;
  late String originId;
  late String targetId;
  late StudySourceWithConcepts document;

  Future<Question> createQuestion(QuestionType type) async {
    final ids = await questions.createQuestions(
      [
        QuestionDraft(
          folderId: originId,
          type: type,
          prompt: '전기장의 단위를 설명하시오.',
          explanation: '전기장의 단위는 V/m이다.',
          difficulty: 4,
          choices: switch (type) {
            QuestionType.multipleChoice => const [
              QuestionChoiceDraft(text: 'V/m', isCorrect: true),
              QuestionChoiceDraft(text: 'A/m', isCorrect: false),
            ],
            QuestionType.trueFalse => const [
              QuestionChoiceDraft(text: 'O', isCorrect: true),
              QuestionChoiceDraft(text: 'X', isCorrect: false),
            ],
            _ => const [],
          },
          acceptableAnswers: type == QuestionType.shortAnswer
              ? const ['V/m', 'N/C']
              : const [],
        ),
      ],
      sourceReferences: [
        QuestionSourceDraft(
          sourceId: document.source.id,
          conceptId: document.concepts.single.id,
          pageNumbers: const [2],
        ),
      ],
    );
    return (await questions.getQuestion(ids.single))!;
  }

  Future<void> clearOutbox() async {
    final pending = await database.syncDao.getPending();
    await database.syncDao.removeAcknowledged(pending.map((entry) => entry.id));
  }

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    folders = DriftFolderRepository(database);
    questions = DriftQuestionRepository(database);
    sources = DriftSourceRepository(database);
    originId = await folders.createFolder(name: '원래 폴더');
    targetId = await folders.createFolder(name: '하위 폴더', parentId: originId);
    document = await sources.saveImport(
      folderId: originId,
      result: DocumentImportResult(
        source: ImportedSource(
          id: 'move-source',
          fileName: '전자기학.pdf',
          contentHash: List.filled(64, 'a').join(),
          pageCount: 5,
          extractionMethod: 'hybrid',
          importedAt: DateTime.utc(2026, 9, 19),
        ),
        concepts: const [
          ImportedConcept(
            title: '전기장',
            content: '전기장의 단위는 V/m이다.',
            pageNumbers: [2],
            importance: ConceptImportance.high,
          ),
        ],
      ),
    );
    await sources.setConceptApproval(
      id: document.concepts.single.id,
      approved: true,
    );
  });
  tearDown(() => database.close());

  for (final type in [
    QuestionType.multipleChoice,
    QuestionType.trueFalse,
    QuestionType.shortAnswer,
  ]) {
    test('${type.name} 이동 시 정답 ID·내용·출처·상태를 보존한다', () async {
      final before = await createQuestion(type);
      final references = await database.sourceDao.getQuestionSources(before.id);
      await clearOutbox();

      await questions.moveQuestion(id: before.id, folderId: targetId);

      final after = (await questions.getQuestion(before.id))!;
      expect(after.folderId, targetId);
      expect(
        QuestionSnapshot.fromQuestion(after).toJson(),
        QuestionSnapshot.fromQuestion(before).toJson(),
      );
      expect(
        after.acceptableAnswers.map((answer) => answer.id),
        before.acceptableAnswers.map((answer) => answer.id),
      );
      expect(after.status, before.status);
      expect(after.createdAt, before.createdAt);
      expect(
        await database.sourceDao.getQuestionSources(before.id),
        references,
      );
      expect(after.sourceReferences.single.sourceId, document.source.id);
      expect(
        after.sourceReferences.single.conceptId,
        document.concepts.single.id,
      );
      expect(after.sourceReferences.single.pageNumbers, [2]);
      expect(
        (await sources.getSourceWithConcepts(document.source.id))
            .source
            .folderId,
        originId,
      );
      expect(await questions.watchQuestions(originId).first, isEmpty);
      expect(
        (await questions.watchQuestions(targetId).first).single.id,
        before.id,
      );
      final changes = await DriftSyncRepository(database).buildPushBatch();
      expect(changes, hasLength(1));
      expect(changes.single.entityType, 'question');
      expect(changes.single.operation, 'upsert');
      expect(changes.single.payload!['folderId'], targetId);
    });
  }

  test('이동 후 기존 풀이 기록과 진행 중 세션을 보존한다', () async {
    final question = await createQuestion(QuestionType.multipleChoice);
    final quizzes = DriftQuizRepository(database);
    final sessionId = await quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: originId,
        enabledQuestionTypes: {QuestionType.multipleChoice},
        questionCount: 1,
      ),
      questions: [question],
    );
    final session = (await quizzes.getSession(sessionId))!;
    final attempts = DriftAttemptRepository(database);
    final attemptId = await attempts.recordAttempt(
      AttemptDraft(
        questionId: question.id,
        sessionId: sessionId,
        response: {'selectedChoiceId': question.choices.first.id},
        questionSnapshot: session.items.single.questionSnapshot,
        score: 1,
        maxScore: 1,
        gradingType: GradingType.local,
        durationMs: 1000,
      ),
    );
    await quizzes.linkAttempt(
      sessionId: sessionId,
      itemId: session.items.single.id,
      attemptId: attemptId,
    );
    final before = await database.attemptDao.getAttemptsForQuestion(
      question.id,
    );

    await questions.moveQuestion(id: question.id, folderId: targetId);

    expect(
      await database.attemptDao.getAttemptsForQuestion(question.id),
      before,
    );
    final resumed = (await quizzes.resumeSession(sessionId))!;
    expect(resumed.items.single.attemptId, attemptId);
    expect(
      resumed.items.single.questionSnapshot.toJson(),
      session.items.single.questionSnapshot.toJson(),
    );
  });

  test('PDF 이동은 개념·승인·파일 정보를 보존하고 생성된 문제는 옮기지 않는다', () async {
    final question = await createQuestion(QuestionType.shortAnswer);
    final references = await database.sourceDao.getQuestionSources(question.id);
    final before = await sources.getSourceWithConcepts(document.source.id);
    final conceptRows = await database.sourceDao.getConcepts(
      document.source.id,
    );
    await clearOutbox();

    await sources.moveSource(id: document.source.id, folderId: targetId);

    final after = await sources.getSourceWithConcepts(document.source.id);
    expect(after.source.id, before.source.id);
    expect(after.source.folderId, targetId);
    expect(after.source.fileName, before.source.fileName);
    expect(after.source.contentHash, before.source.contentHash);
    expect(after.source.importedAt, before.source.importedAt);
    expect(after.source.pageCount, before.source.pageCount);
    expect(after.source.extractionMethod, before.source.extractionMethod);
    expect(
      await database.sourceDao.getConcepts(document.source.id),
      conceptRows,
    );
    expect(after.concepts.single.status, ConceptStatus.approved);
    expect(after.concepts.single.importance, ConceptImportance.high);
    expect(
      (await sources.getConceptGenerationSeed(after.concepts.single.id))
          .folderId,
      targetId,
    );
    final unchanged = (await questions.getQuestion(question.id))!;
    expect(unchanged.folderId, originId);
    expect(
      await database.sourceDao.getQuestionSources(question.id),
      references,
    );
    expect(await sources.getSources(originId), isEmpty);
    expect((await sources.getSources(targetId)).single.id, document.source.id);
    final counts = await database.folderDao
        .watchActiveFoldersWithCounts()
        .first;
    expect(
      counts.singleWhere((row) => row.folder.id == originId).sourceCount,
      0,
    );
    expect(
      counts.singleWhere((row) => row.folder.id == originId).questionCount,
      1,
    );
    expect(
      counts.singleWhere((row) => row.folder.id == targetId).sourceCount,
      1,
    );
    final changes = await DriftSyncRepository(database).buildPushBatch();
    expect(changes, hasLength(1));
    expect(changes.single.entityType, 'source');
    expect(changes.single.operation, 'upsert');
    expect(changes.single.payload!['folderId'], targetId);
  });

  test('문제 및 PDF 이동을 기존 기기에 동기화하고 승인 상태를 유지한다', () async {
    final question = await createQuestion(QuestionType.trueFalse);
    final secondDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(secondDatabase.close);
    var revision = 0;
    Future<void> sync() async {
      final changes = await DriftSyncRepository(database).buildPushBatch();
      await DriftSyncRepository(secondDatabase).applyPulledChanges([
        for (final change in changes)
          PullSyncChange(
            entityType: change.entityType,
            entityId: change.entityId,
            operation: change.operation,
            payload: change.payload,
            updatedAt: change.updatedAt,
            deletedAt: change.deletedAt,
            revision: ++revision,
          ),
      ]);
      await clearOutbox();
    }

    await sync();
    await questions.moveQuestion(id: question.id, folderId: targetId);
    await sources.moveSource(id: document.source.id, folderId: targetId);
    await sync();

    final syncedQuestion = (await DriftQuestionRepository(secondDatabase)
        .getQuestion(question.id))!;
    expect(syncedQuestion.folderId, targetId);
    expect(syncedQuestion.status, QuestionStatus.approved);
    expect(
      QuestionSnapshot.fromQuestion(syncedQuestion).toJson(),
      QuestionSnapshot.fromQuestion(question).toJson(),
    );
    expect(
      await secondDatabase.sourceDao.getQuestionSources(question.id),
      await database.sourceDao.getQuestionSources(question.id),
    );
    final syncedSource = await DriftSourceRepository(secondDatabase)
        .getSourceWithConcepts(document.source.id);
    expect(syncedSource.source.folderId, targetId);
    expect(syncedSource.concepts.single.status, ConceptStatus.approved);
  });

  for (final isPdf in [false, true]) {
    final label = isPdf ? 'PDF' : '문제';
    Future<void> move(String id, String folderId) => isPdf
        ? sources.moveSource(id: id, folderId: folderId)
        : questions.moveQuestion(id: id, folderId: folderId);
    Future<String> itemId() async => isPdf
        ? document.source.id
        : (await createQuestion(QuestionType.shortAnswer)).id;
    Future<String> currentFolder(String id) async => isPdf
        ? (await sources.getSourceWithConcepts(id)).source.folderId
        : (await questions.getQuestion(id))!.folderId;

    test('$label 이동 시 현재 폴더 선택은 변경·동기화를 발생시키지 않는다', () async {
      final id = await itemId();
      await clearOutbox();
      await move(id, originId);
      expect(await currentFolder(id), originId);
      expect(await database.syncDao.getPendingCount(), 0);
    });

    test('$label 이동 시 없는/삭제된 대상 폴더 및 항목을 거부한다', () async {
      final id = await itemId();
      await folders.deleteFolder(targetId);
      await clearOutbox();
      for (final invalidTarget in ['missing-folder', targetId]) {
        await expectLater(
          move(id, invalidTarget),
          throwsA(isA<ValidationFailure>()),
        );
      }
      await expectLater(
        move('missing-item', originId),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await currentFolder(id), originId);
      expect(await database.syncDao.getPendingCount(), 0);
      if (isPdf) {
        await sources.deleteSource(id);
      } else {
        await questions.deleteQuestion(id);
      }
      await clearOutbox();
      await expectLater(move(id, originId), throwsA(isA<ValidationFailure>()));
      expect(await database.syncDao.getPendingCount(), 0);
    });

    test('$label 이동 시 동기화 기록 실패는 폴더 변경도 롤백한다', () async {
      final id = await itemId();
      await clearOutbox();
      await database.customStatement('''
        CREATE TRIGGER reject_move_outbox BEFORE INSERT ON sync_outbox
        BEGIN SELECT RAISE(ABORT, 'test failure'); END
      ''');
      await expectLater(move(id, targetId), throwsA(isA<DatabaseFailure>()));
      expect(await currentFolder(id), originId);
      expect(await database.syncDao.getPendingCount(), 0);
    });
  }
}
