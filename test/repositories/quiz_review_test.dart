import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<String> createSession(AppDatabase db) async {
  final folder = await DriftFolderRepository(db).createFolder(name: '재검토');
  final repo = DriftQuestionRepository(db);
  final questions = <Question>[];
  for (var i = 0; i < 2; i++) {
    final id = await repo.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.essay,
        prompt: '설명해라. $i',
        acceptableAnswers: const ['답안'],
      ),
    );
    questions.add((await repo.getQuestion(id))!);
  }
  return DriftQuizRepository(db).createSession(
    filter: QuizFilter(
      rootFolderId: folder,
      enabledQuestionTypes: const {QuestionType.essay},
      questionCount: 2,
      feedbackTiming: AnswerFeedbackTiming.afterCompletion,
    ),
    questions: questions,
  );
}

void main() {
  late AppDatabase db;
  late DriftQuizRepository quizzes;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    quizzes = DriftQuizRepository(db);
  });
  tearDown(() => db.close());

  test('재검토는 기존 draft로 되돌리고 답안 기록 없이 스킵·재개하며 모두 스킵해도 완료한다', () async {
    final session = await createSession(db);
    final original = (await quizzes.getSession(session))!;
    final item = original.items.first;
    await quizzes.saveEssayResponse(
      sessionId: session,
      itemId: item.id,
      answer: '작성한 답',
      durationMs: 10,
    );
    await quizzes.skipForReview(sessionId: session, itemId: item.id);
    final resumed = (await quizzes.resumeSession(session))!;
    expect(resumed.items.first.skippedForReview, true);
    expect(resumed.items.first.pendingEssayResponse, isNull);
    expect(resumed.items.first.attemptId, isNull);
    expect(resumed.processedQuestions, 1);
    expect(resumed.session.completedQuestions, 0);
    expect(resumed.session.finishedAt, isNull);
    final questions = DriftQuestionRepository(db);
    expect(
      (await questions.getQuestion(item.questionId))!.status,
      QuestionStatus.draft,
    );
    expect(
      (await questions.getEligibleQuestions(
        folderIds: [original.session.sourceFolderId!],
        types: const {QuestionType.essay},
      )).map((q) => q.id),
      isNot(contains(item.questionId)),
    );
    expect(await DriftAttemptRepository(db).getAllAttempts(), isEmpty);
    await expectLater(
      quizzes.skipForReview(sessionId: session, itemId: item.id),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      quizzes.saveEssayResponse(
        sessionId: session,
        itemId: item.id,
        answer: '답',
        durationMs: 10,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      quizzes.linkAttempt(
        sessionId: session,
        itemId: item.id,
        attemptId: 'invalid',
      ),
      throwsA(isA<ValidationFailure>()),
    );
    await quizzes.skipForReview(
      sessionId: session,
      itemId: resumed.items.last.id,
    );
    final ended = (await quizzes.getSession(session))!;
    expect(ended.processedQuestions, 2);
    expect(ended.session.totalQuestions, 2);
    expect(ended.session.completedQuestions, 0);
    expect(ended.session.finishedAt, isNotNull);
    await questions.approveQuestions([item.questionId]);
    expect(
      (await questions.getQuestion(item.questionId))!.status,
      QuestionStatus.approved,
    );
  });

  test('문제 상태 변경 실패는 스킵·진행 상태·동기화 기록까지 롤백한다', () async {
    final session = await createSession(db);
    final before = (await quizzes.getSession(session))!;
    final sync = DriftSyncRepository(db);
    final pending = (await sync.getPending()).length;
    await db.customStatement(
      "CREATE TRIGGER fail_review BEFORE UPDATE OF status ON questions BEGIN SELECT RAISE(ABORT, 'test review failure'); END",
    );
    await expectLater(
      quizzes.skipForReview(sessionId: session, itemId: before.items.first.id),
      throwsA(isA<DatabaseFailure>()),
    );
    final after = (await quizzes.getSession(session))!;
    expect(after.items.first.skippedForReview, false);
    expect(after.session.updatedAt, before.session.updatedAt);
    expect(
      (await DriftQuestionRepository(db)
              .getQuestion(before.items.first.questionId))!
          .status,
      QuestionStatus.approved,
    );
    expect((await sync.getPending()).length, pending);
    await db.customStatement('DROP TRIGGER fail_review');
    await quizzes.skipForReview(
      sessionId: session,
      itemId: before.items.first.id,
    );
    expect(
      (await quizzes.getSession(session))!.items.first.skippedForReview,
      true,
    );
  });

  test('동기화는 스킵과 기존 draft를 보존하고 구버전 스킵 필드 누락은 false로 읽는다', () async {
    final session = await createSession(db);
    final item = (await quizzes.getSession(session))!.items.first;
    await quizzes.skipForReview(sessionId: session, itemId: item.id);
    final batch = await DriftSyncRepository(db).buildPushBatch();
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    await DriftSyncRepository(target).applyPulledChanges([
      for (var i = 0; i < batch.length; i++)
        PullSyncChange(
          entityType: batch[i].entityType,
          entityId: batch[i].entityId,
          operation: batch[i].operation,
          payload: batch[i].payload,
          updatedAt: batch[i].updatedAt,
          deletedAt: batch[i].deletedAt,
          revision: i + 1,
        ),
    ]);
    expect(
      (await DriftQuizRepository(target).resumeSession(session))!
          .items
          .first
          .skippedForReview,
      true,
    );
    expect(
      (await DriftQuestionRepository(target).getQuestion(item.questionId))!
          .status,
      QuestionStatus.draft,
    );
    expect(await DriftAttemptRepository(target).getAllAttempts(), isEmpty);
    final payload = batch
        .firstWhere((e) => e.entityType == 'quizSession')
        .payload!;
    final legacy = {
      ...payload,
      'items': [
        for (final raw in payload['items']! as List)
          {...Map<String, Object?>.from(raw as Map)}
            ..remove('skippedForReview'),
      ],
    };
    await DriftSyncRepository(target).applyPulledChanges([
      PullSyncChange(
        entityType: 'quizSession',
        entityId: session,
        operation: 'upsert',
        payload: legacy,
        updatedAt: DateTime.now().toUtc().add(const Duration(seconds: 2)),
        revision: batch.length + 1,
      ),
    ]);
    expect(
      (await DriftQuizRepository(target).getSession(session))!.items
          .every((item) => !item.skippedForReview),
      true,
    );
  });

  test('v14 세션·채점 대기 답안을 보존하며 스킵 기본값 false를 추가한다', () async {
    final directory = await Directory.systemTemp.createTemp(
      'quiz_review_migration_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/test.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    final session = await createSession(original);
    final originalQuizzes = DriftQuizRepository(original);
    final item = (await originalQuizzes.getSession(session))!.items.first;
    await originalQuizzes.saveEssayResponse(
      sessionId: session,
      itemId: item.id,
      answer: '기존 답안',
      durationMs: 12,
    );
    await original.close();
    final legacy = sqlite.sqlite3.open(file.path);
    legacy.execute(
      'ALTER TABLE quiz_session_items DROP COLUMN skipped_for_review',
    );
    legacy.execute('PRAGMA user_version = 14');
    legacy.execute('ALTER TABLE questions DROP COLUMN correct_choice_ids_json');
    legacy.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final saved = (await DriftQuizRepository(upgraded).getSession(session))!;
    expect(upgraded.schemaVersion, 16);
    expect(saved.items.every((item) => !item.skippedForReview), true);
    expect(saved.items.first.pendingEssayResponse!['textAnswer'], '기존 답안');
    expect(saved.session.completedQuestions, 0);
  });
}
