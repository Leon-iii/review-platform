import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/grading_type.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/enums/sync_entity_type.dart';
import 'package:review_platform/domain/enums/sync_operation.dart';
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

void main() {
  late AppDatabase database;
  late DriftFolderRepository folders;
  late DriftQuestionRepository questions;
  late DriftQuizRepository quizzes;
  late DriftAttemptRepository attempts;
  late DriftSyncRepository sync;
  late bool databaseClosed;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    folders = DriftFolderRepository(database);
    questions = DriftQuestionRepository(database);
    quizzes = DriftQuizRepository(database);
    attempts = DriftAttemptRepository(database);
    sync = DriftSyncRepository(database);
    databaseClosed = false;
  });

  tearDown(() async {
    if (!databaseClosed) await database.close();
  });

  test('주요 Entity 변경을 같은 로컬 흐름에서 Outbox에 기록한다', () async {
    final folderId = await folders.createFolder(name: '동기화');
    final questionId = await questions.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        prompt: '동기화 문제',
        acceptableAnswers: const ['정답'],
      ),
    );
    final question = (await questions.getQuestion(questionId))!;
    final sessionId = await quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folderId,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [question],
    );
    final session = (await quizzes.getSession(sessionId))!;
    final attemptId = await attempts.recordAttempt(
      AttemptDraft(
        questionId: questionId,
        sessionId: sessionId,
        response: const {'textAnswer': '정답'},
        questionSnapshot: session.items.single.questionSnapshot,
        score: 1,
        maxScore: 1,
        gradingType: GradingType.local,
        durationMs: 50,
      ),
    );
    await quizzes.linkAttempt(
      sessionId: sessionId,
      itemId: session.items.single.id,
      attemptId: attemptId,
    );

    final pending = await sync.getPending();
    expect(
      pending.map((entry) => entry.entityType),
      containsAll([
        SyncEntityType.folder,
        SyncEntityType.question,
        SyncEntityType.quizSession,
        SyncEntityType.attempt,
      ]),
    );
    expect(
      pending.every((entry) => entry.operation == SyncOperation.upsert),
      isTrue,
    );

    await sync.markFailed(id: pending.first.id, error: 'offline');
    final failed = (await sync.getPending()).first;
    expect(failed.retryCount, 1);
    expect(failed.lastError, 'offline');

    await sync.removeAcknowledged(pending.map((entry) => entry.id));
    expect(await sync.getPending(), isEmpty);
  });

  test('하위 폴더 삭제가 포함된 모든 Entity의 delete 이벤트를 남긴다', () async {
    final rootId = await folders.createFolder(name: '상위');
    final childId = await folders.createFolder(name: '하위', parentId: rootId);
    final questionId = await questions.createQuestion(
      QuestionDraft(
        folderId: childId,
        type: QuestionType.shortAnswer,
        prompt: '삭제 문제',
        acceptableAnswers: const ['정답'],
      ),
    );
    final existing = await sync.getPending();
    await sync.removeAcknowledged(existing.map((entry) => entry.id));

    await folders.deleteFolder(rootId);

    final deleted = await sync.getPending();
    expect(deleted, hasLength(3));
    expect(
      deleted
          .where((entry) => entry.entityType == SyncEntityType.folder)
          .map((entry) => entry.entityId),
      containsAll([rootId, childId]),
    );
    expect(
      deleted
          .singleWhere((entry) => entry.entityType == SyncEntityType.question)
          .entityId,
      questionId,
    );
    expect(
      deleted.every((entry) => entry.operation == SyncOperation.delete),
      isTrue,
    );
  });

  test('Entity 저장이 실패하면 Outbox도 추가되지 않는다', () async {
    await expectLater(
      questions.createQuestion(
        const QuestionDraft(
          folderId: 'missing-folder',
          type: QuestionType.shortAnswer,
          prompt: '저장 실패',
          acceptableAnswers: ['정답'],
        ),
      ),
      throwsA(isA<ValidationFailure>()),
    );

    expect(await sync.getPending(), isEmpty);
  });

  test('Folder부터 Attempt까지 직렬화한 payload를 다른 DB에 복원한다', () async {
    final folderId = await folders.createFolder(name: '기기 공유');
    final questionId = await questions.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        prompt: '동기화 정답은?',
        explanation: '기기 간 동일해야 한다.',
        acceptableAnswers: const ['같음'],
      ),
    );
    final question = (await questions.getQuestion(questionId))!;
    final sessionId = await quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folderId,
        enabledQuestionTypes: const {QuestionType.shortAnswer},
        questionCount: 1,
      ),
      questions: [question],
    );
    final sourceSession = (await quizzes.getSession(sessionId))!;
    final attemptId = await attempts.recordAttempt(
      AttemptDraft(
        questionId: questionId,
        sessionId: sessionId,
        response: const {'textAnswer': '같음'},
        questionSnapshot: sourceSession.items.single.questionSnapshot,
        score: 1,
        maxScore: 1,
        gradingType: GradingType.local,
        durationMs: 80,
      ),
    );
    await quizzes.linkAttempt(
      sessionId: sessionId,
      itemId: sourceSession.items.single.id,
      attemptId: attemptId,
    );
    final payloads = await sync.buildPushBatch();
    await database.close();
    databaseClosed = true;

    final targetDatabase = AppDatabase(NativeDatabase.memory());
    addTearDown(targetDatabase.close);
    final targetSync = DriftSyncRepository(targetDatabase);
    await targetSync.applyPulledChanges([
      for (var index = 0; index < payloads.length; index++)
        PullSyncChange(
          entityType: payloads[index].entityType,
          entityId: payloads[index].entityId,
          operation: payloads[index].operation,
          payload: payloads[index].payload,
          updatedAt: payloads[index].updatedAt,
          deletedAt: payloads[index].deletedAt,
          revision: index + 1,
        ),
    ]);

    final targetFolders = DriftFolderRepository(targetDatabase);
    final targetQuestions = DriftQuestionRepository(targetDatabase);
    final targetQuizzes = DriftQuizRepository(targetDatabase);
    final targetAttempts = DriftAttemptRepository(targetDatabase);
    expect(
      (await targetFolders.watchFolderTree().first).single.folder.name,
      '기기 공유',
    );
    expect((await targetQuestions.getQuestion(questionId))!.prompt, '동기화 정답은?');
    expect(
      (await targetQuizzes.getSession(sessionId))!.items.single.attemptId,
      attemptId,
    );
    expect(await targetAttempts.getAttemptsForSession(sessionId), hasLength(1));
    expect(await targetSync.getPending(), isEmpty);
  });
}
