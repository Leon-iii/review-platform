import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/services/answer_grader.dart';
import 'package:review_platform/domain/services/quiz_builder.dart';
import 'package:review_platform/features/study/result/quiz_result_view_model.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/quiz_answer_correction_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';
import 'package:review_platform/repositories/statistics_repository.dart';

import '../support/quiz_answer_correction_fixture.dart';

void main() {
  late AppDatabase db;
  late QuizAnswerCorrectionRepository corrections;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    corrections = QuizAnswerCorrectionRepository(db);
  });
  tearDown(() => db.close());

  test('단답형 정의·점수·정답률·최근 오답·통계·미래 채점과 실행취소를 함께 반영한다', () async {
    final fixture = await createWrongQuiz(db);
    final attempts = DriftAttemptRepository(db);
    final questions = DriftQuestionRepository(db);
    final quizzes = DriftQuizRepository(db);
    final before = (await attempts.getAttemptsForSession(fixture.sessionId))
        .single;
    final correction = await corrections.acceptSubmittedAnswer(before.id);
    final after = (await attempts.getAttemptsForSession(fixture.sessionId))
        .single;
    final summary = QuizResultSummary(
      session: (await quizzes.getSession(fixture.sessionId))!.session,
      attempts: [after],
    );
    expect(summary.totalScore, 1);
    expect(summary.correctCount, 1);
    expect(summary.accuracyPercent, 100);
    expect(summary.wrongAttempts, isEmpty);
    expect(
      (await DriftStatisticsRepository(
        db,
      ).watchStatisticsData().first).attempts.single.score,
      1,
    );
    expect(after.answeredAt, before.answeredAt);
    expect(after.durationMs, before.durationMs);
    final updated = (await questions.getQuestion(fixture.question.id))!;
    expect(updated.acceptableAnswers.map((a) => a.text), ['용어', '다른 용어']);
    for (final answer in ['용어', '다른 용어', '다른용어']) {
      expect(
        AnswerGrader.gradeShortAnswer(
          QuestionSnapshot.fromQuestion(updated),
          answer,
        ).isCorrect,
        true,
      );
    }
    final builder = QuizBuilder(
      DriftFolderRepository(db),
      questions,
      quizzes,
      attempts,
    );
    final filter = QuizFilter(
      rootFolderId: fixture.folderId,
      enabledQuestionTypes: {QuestionType.shortAnswer},
      questionCount: 1,
      onlyWrongQuestions: true,
    );
    await expectLater(builder.build(filter), throwsA(isA<ValidationFailure>()));
    await corrections.undo(correction);
    final restored = (await attempts.getAttemptsForSession(fixture.sessionId))
        .single;
    expect(restored.score, before.score);
    expect(
      restored.questionSnapshot.toJson(),
      before.questionSnapshot.toJson(),
    );
    expect(
      (await questions.getQuestion(updated.id))!.acceptableAnswers
          .map((a) => a.text),
      ['용어'],
    );
    expect(
      (await DriftStatisticsRepository(
        db,
      ).watchStatisticsData().first).attempts.single.score,
      0,
    );
    expect((await builder.build(filter)).questionCount, 1);
    await expectLater(
      corrections.undo(correction),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('중복 등록·모름·빈 답안·객관식·O/X·서술형·정답은 거부한다', () async {
    final wrong = await createWrongQuiz(db);
    await corrections.acceptSubmittedAnswer(wrong.attemptId);
    await expectLater(
      corrections.acceptSubmittedAnswer(wrong.attemptId),
      throwsA(isA<ValidationFailure>()),
    );
    for (final type in QuestionType.values) {
      if (type == QuestionType.shortAnswer) continue;
      final fixture = await createWrongQuiz(db, type: type);
      await expectLater(
        corrections.acceptSubmittedAnswer(fixture.attemptId),
        throwsA(isA<ValidationFailure>()),
      );
    }
    for (final fixture in [
      await createWrongQuiz(db, unknown: true),
      await createWrongQuiz(db, correct: true),
      await createWrongQuiz(db, submittedAnswer: '   '),
    ]) {
      await expectLater(
        corrections.acceptSubmittedAnswer(fixture.attemptId),
        throwsA(isA<ValidationFailure>()),
      );
    }
  });

  test('삭제/변경된 문항과 채점 설정 변경을 보호하며 실행취소는 후속 편집을 덮어쓰지 않는다', () async {
    final fixture = await createWrongQuiz(db);
    final correction = await corrections.acceptSubmittedAnswer(
      fixture.attemptId,
    );
    await db.questionDao.updateQuestion(
      fixture.question.id,
      const QuestionsCompanion(prompt: Value('수정된 문제')),
    );
    await expectLater(
      corrections.undo(correction),
      throwsA(isA<ValidationFailure>()),
    );
    expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 1);
    final deleted = await createWrongQuiz(db);
    await DriftQuestionRepository(db).deleteQuestion(deleted.question.id);
    await expectLater(
      corrections.acceptSubmittedAnswer(deleted.attemptId),
      throwsA(isA<ValidationFailure>()),
    );
    final changed = await createWrongQuiz(db);
    await db.questionDao.updateQuestion(
      changed.question.id,
      const QuestionsCompanion(caseSensitive: Value(true)),
    );
    await expectLater(
      corrections.acceptSubmittedAnswer(changed.attemptId),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('등록/실행취소 중 실패 시 허용 정답·풀이·동기화가 모두 롤백된다', () async {
    final fixture = await createWrongQuiz(db);
    final sync = DriftSyncRepository(db);
    final pending = (await sync.getPending()).length;
    await db.customStatement(
      "CREATE TRIGGER reject_correction BEFORE UPDATE ON attempts BEGIN SELECT RAISE(ABORT, 'test'); END",
    );
    await expectLater(
      corrections.acceptSubmittedAnswer(fixture.attemptId),
      throwsA(isA<DatabaseFailure>()),
    );
    expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 0);
    expect(
      await db.questionDao.getAcceptableAnswers(fixture.question.id),
      hasLength(1),
    );
    expect((await sync.getPending()).length, pending);
    await db.customStatement('DROP TRIGGER reject_correction');
    final correction = await corrections.acceptSubmittedAnswer(
      fixture.attemptId,
    );
    await db.customStatement(
      "CREATE TRIGGER reject_undo BEFORE UPDATE ON attempts BEGIN SELECT RAISE(ABORT, 'test'); END",
    );
    await expectLater(
      corrections.undo(correction),
      throwsA(isA<DatabaseFailure>()),
    );
    expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 1);
    expect(
      await db.questionDao.getAcceptableAnswers(fixture.question.id),
      hasLength(2),
    );
    await db.customStatement('DROP TRIGGER reject_undo');
    await corrections.undo(correction);
    expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 0);
  });

  for (final caseSensitive in [false, true]) {
    for (final whitespaceSensitive in [false, true]) {
      test('case=$caseSensitive space=$whitespaceSensitive: 문항별 정규화와 중복 방지/취소', () async {
        final fixture = await createWrongQuiz(
          db,
          submittedAnswer: '  Web Cache  ',
          caseSensitive: caseSensitive,
          whitespaceSensitive: whitespaceSensitive,
        );
        // Another device/editor accepted an equivalent variant after this quiz.
        const candidate = 'webcache';
        await db
            .into(db.acceptableAnswers)
            .insert(
              AcceptableAnswersCompanion.insert(
                id: 'existing-variant',
                questionId: fixture.question.id,
                answerText: candidate,
              ),
            );
        final correction = await corrections.acceptSubmittedAnswer(
          fixture.attemptId,
        );
        final updated = (await DriftQuestionRepository(db)
            .getQuestion(fixture.question.id))!;
        expect(
          updated.acceptableAnswers,
          hasLength(!caseSensitive && !whitespaceSensitive ? 2 : 3),
        );
        expect(
          AnswerGrader.gradeShortAnswer(
            QuestionSnapshot.fromQuestion(updated),
            'Web Cache',
          ).isCorrect,
          true,
        );
        expect(updated.caseSensitive, caseSensitive);
        expect(updated.whitespaceSensitive, whitespaceSensitive);
        await corrections.undo(correction);
        final restored = (await db.questionDao.getAcceptableAnswers(
          fixture.question.id,
        ));
        expect(restored.map((a) => a.answerText), ['용어', candidate]);
        expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 0);
      });
    }
  }

  test('레거시 스냅샷의 필드는 보존하며 허용 정답만 추가한다', () async {
    final fixture = await createWrongQuiz(db);
    final row = (await db.attemptDao.getAttempt(fixture.attemptId))!;
    final legacy = jsonDecode(row.questionSnapshotJson) as Map
      ..remove('difficulty')
      ..remove('answerFormatVersion')
      ..remove('caseSensitive')
      ..remove('whitespaceSensitive');
    await (db.update(db.attempts)..where((a) => a.id.equals(row.id))).write(
      AttemptsCompanion(questionSnapshotJson: Value(jsonEncode(legacy))),
    );
    final correction = await corrections.acceptSubmittedAnswer(row.id);
    final after = jsonDecode(
      (await db.attemptDao.getAttempt(row.id))!.questionSnapshotJson,
    ) as Map;
    expect(after.keys.toSet(), legacy.keys.toSet());
    expect(after['acceptableAnswers'], ['용어', '다른 용어']);
    await corrections.undo(correction);
    expect(
      jsonDecode(
        (await db.attemptDao.getAttempt(row.id))!.questionSnapshotJson,
      ),
      legacy,
    );
  });

  test('동기화 채점 수정은 응답·문항·기존 정답·채점 설정을 바꿀 수 없다', () async {
    final fixture = await createWrongQuiz(db);
    final original = (await db.attemptDao.getAttempt(fixture.attemptId))!;
    await corrections.acceptSubmittedAnswer(original.id);
    final payload = (await DriftSyncRepository(db).buildPushBatch())
        .firstWhere((change) => change.entityType == 'attempt')
        .payload!;
    expect(isValidAttemptCorrection(original, payload), true);
    expect(
      isValidAttemptCorrection(original, {
        ...payload,
        'response': {'textAnswer': '바뀐 응답'},
      }),
      false,
    );
    for (final alteration in [
      {'prompt': '다른 문항'},
      {
        'acceptableAnswers': ['다른 용어'],
      },
      {
        'acceptableAnswers': ['용어', '임의 용어', '다른 용어'],
      },
      {'caseSensitive': true},
    ]) {
      expect(
        isValidAttemptCorrection(original, {
          ...payload,
          'questionSnapshot': {
            ...payload['questionSnapshot'] as Map,
            ...alteration,
          },
        }),
        false,
      );
    }
  });

  test('다른 기기에 이미 존재하는 풀이에도 등록/취소를 동기화하며 오래된 변경은 무시한다', () async {
    final fixture = await createWrongQuiz(db);
    final previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () =>
          driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning,
    );
    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    final sourceSync = DriftSyncRepository(db),
        targetSync = DriftSyncRepository(target);
    var revision = 0;
    Future<List<PullSyncChange>> push() async {
      final batch = await sourceSync.buildPushBatch();
      final pulled = [
        for (final change in batch)
          PullSyncChange(
            entityType: change.entityType,
            entityId: change.entityId,
            operation: change.operation,
            payload: change.payload,
            updatedAt: change.updatedAt,
            revision: ++revision,
          ),
      ];
      await targetSync.applyPulledChanges(pulled);
      await sourceSync.removeAcknowledged(batch.map((c) => c.operationId));
      return pulled;
    }

    await push();
    final correction = await corrections.acceptSubmittedAnswer(
      fixture.attemptId,
    );
    final accepted = await push();
    expect((await target.attemptDao.getAttempt(fixture.attemptId))!.score, 1);
    expect(
      await target.questionDao.getAcceptableAnswers(fixture.question.id),
      hasLength(2),
    );
    await corrections.undo(correction);
    await push();
    expect((await target.attemptDao.getAttempt(fixture.attemptId))!.score, 0);
    expect(
      await target.questionDao.getAcceptableAnswers(fixture.question.id),
      hasLength(1),
    );
    await targetSync.applyPulledChanges([
      for (final c in accepted)
        PullSyncChange(
          entityType: c.entityType,
          entityId: c.entityId,
          operation: c.operation,
          payload: c.payload,
          updatedAt: c.updatedAt,
          revision: ++revision,
        ),
    ]);
    final restored = (await target.attemptDao.getAttempt(fixture.attemptId))!;
    expect(restored.score, 0);
    expect(
      await target.questionDao.getAcceptableAnswers(fixture.question.id),
      hasLength(1),
    );
    expect(jsonDecode(restored.responseJson)['textAnswer'], '다른 용어');
  });
}
