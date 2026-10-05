import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

void main() {
  for (final legacy in [true, false]) {
    test('단답형 동기화: 구버전만 서술형 전환 (legacy: $legacy)', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final target = AppDatabase(NativeDatabase.memory());
      addTearDown(target.close);
      final folder = await DriftFolderRepository(db).createFolder(name: '동기화');
      final repo = DriftQuestionRepository(db);
      final id = await repo.createQuestion(
        QuestionDraft(
          folderId: folder,
          type: QuestionType.shortAnswer,
          prompt: '동기화 문항',
          acceptableAnswers: const ['정답'],
        ),
      );
      final quizzes = DriftQuizRepository(db);
      final session = await quizzes.createSession(
        filter: QuizFilter(
          rootFolderId: folder,
          enabledQuestionTypes: const {QuestionType.shortAnswer},
          questionCount: 1,
        ),
        questions: [(await repo.getQuestion(id))!],
      );
      final batch = await DriftSyncRepository(db).buildPushBatch();
      final restored = <PullSyncChange>[];
      for (var i = 0; i < batch.length; i++) {
        final entry = batch[i];
        final payload = Map<String, Object?>.from(
          jsonDecode(jsonEncode(entry.payload)) as Map,
        );
        if (legacy) {
          payload.remove('answerFormatVersion');
          if (entry.entityType == 'quizSession') {
            for (final item in payload['items']! as List) {
              (item['questionSnapshot'] as Map).remove('answerFormatVersion');
            }
          }
        }
        restored.add(
          PullSyncChange(
            entityType: entry.entityType,
            entityId: entry.entityId,
            operation: entry.operation,
            updatedAt: entry.updatedAt,
            revision: i + 1,
            payload: payload,
          ),
        );
      }
      await DriftSyncRepository(target).applyPulledChanges(restored);
      final expected = legacy ? QuestionType.essay : QuestionType.shortAnswer;
      expect(
        (await DriftQuestionRepository(target).getQuestion(id))!.type,
        expected,
      );
      expect(
        (await DriftQuizRepository(target).getSession(session))!
            .items
            .single
            .questionSnapshot
            .type,
        expected,
      );
      expect(await DriftSyncRepository(target).getPending(), isEmpty);
    });
  }

  test('채점 대기 서술형 답안을 동기화·재개하고 중복 제출과 잘못된 문항을 거부한다', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    final folder = await DriftFolderRepository(db).createFolder(name: '자기 채점');
    final repo = DriftQuestionRepository(db);
    final id = await repo.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.essay,
        prompt: '설명하시오.',
        acceptableAnswers: const ['모범 답안 문장.'],
      ),
    );
    final quizzes = DriftQuizRepository(db);
    final session = await quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: const {QuestionType.essay},
        questionCount: 1,
        feedbackTiming: AnswerFeedbackTiming.afterCompletion,
      ),
      questions: [(await repo.getQuestion(id))!],
    );
    final item = (await quizzes.getSession(session))!.items.single;
    await expectLater(
      quizzes.saveEssayResponse(
        sessionId: session,
        itemId: item.id,
        answer: '',
        durationMs: 20,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      quizzes.saveEssayResponse(
        sessionId: session,
        itemId: 'wrong',
        answer: '답안',
        durationMs: 20,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    await quizzes.saveEssayResponse(
      sessionId: session,
      itemId: item.id,
      answer: '내 답안\n두 번째 줄',
      durationMs: 500,
    );
    await expectLater(
      quizzes.saveEssayResponse(
        sessionId: session,
        itemId: item.id,
        answer: '덮어쓰기',
        durationMs: 100,
      ),
      throwsA(isA<ValidationFailure>()),
    );
    final batch = await DriftSyncRepository(db).buildPushBatch();
    await DriftSyncRepository(target).applyPulledChanges([
      for (var i = 0; i < batch.length; i++)
        PullSyncChange(
          entityType: batch[i].entityType,
          entityId: batch[i].entityId,
          operation: batch[i].operation,
          updatedAt: batch[i].updatedAt,
          revision: i + 1,
          payload: batch[i].payload,
        ),
    ]);
    final resumed = (await DriftQuizRepository(target).resumeSession(session))!;
    expect(resumed.session.finishedAt, isNull);
    expect(resumed.session.completedQuestions, 0);
    expect(resumed.items.single.pendingEssayResponse, {
      'textAnswer': '내 답안\n두 번째 줄',
      'durationMs': 500,
    });
    expect(resumed.items.single.attemptId, isNull);
    expect(await target.select(target.attempts).get(), isEmpty);
    expect(
      resumed.session.filter.feedbackTiming,
      AnswerFeedbackTiming.afterCompletion,
    );
  });
}
