import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/models/quiz_session.dart';
import 'package:review_platform/features/study/quiz/quiz_view_model.dart';
import 'package:review_platform/features/study/result/quiz_result_view_model.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/repository_providers.dart';

import 'support/fake_sync.dart';

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  late AppDatabase db;
  late DriftQuizRepository quizzes;
  late DriftAttemptRepository attempts;
  late String folder;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    quizzes = DriftQuizRepository(db);
    attempts = DriftAttemptRepository(db);
    folder = await DriftFolderRepository(db).createFolder(name: '중단');
  });
  tearDown(() => db.close());
  Future<String> create(QuestionType type, AnswerFeedbackTiming timing) async {
    final repo = DriftQuestionRepository(db);
    final questions = <Question>[];
    for (var i = 0; i < 2; i++) {
      final id = await repo.createQuestion(
        QuestionDraft(
          folderId: folder,
          type: type,
          prompt: '중단 문제 ${i + 1}',
          acceptableAnswers:
              type == QuestionType.essay || type == QuestionType.shortAnswer
              ? const ['정답']
              : const [],
          choices:
              type == QuestionType.multipleChoice ||
                  type == QuestionType.trueFalse
              ? [
                  QuestionChoiceDraft(
                    text: type == QuestionType.trueFalse ? 'O' : '정답 선택지',
                    isCorrect: true,
                  ),
                  QuestionChoiceDraft(
                    text: type == QuestionType.trueFalse ? 'X' : '오답 선택지',
                    isCorrect: false,
                  ),
                ]
              : const [],
        ),
      );
      questions.add((await repo.getQuestion(id))!);
    }
    return quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folder,
        enabledQuestionTypes: {type},
        questionCount: 2,
        feedbackTiming: timing,
        shuffle: false,
      ),
      questions: questions,
    );
  }

  Future<ProviderContainer> open(
    WidgetTester tester,
    String session, {
    QuizRepository? controlled,
  }) async {
    await tester.binding.setSurfaceSize(
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1100, 900)
          : const Size(390, 800),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          isWindowsPlatformProvider.overrideWithValue(false),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(),
          ),
          if (controlled != null)
            quizRepositoryProvider.overrideWithValue(controlled),
        ],
        child: const ReviewApp(),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    container.read(routerProvider).go(AppRoutes.studySession(session));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('stop-quiz-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-stop-quiz-button')));
    await tester.pumpAndSettle();
  }

  for (final type in QuestionType.values) {
    for (final timing in AnswerFeedbackTiming.values) {
      testWidgets(
        '${type.name} ${timing.name}: 중단 취소는 답안을 유지하고 확인은 기존 채점만 보존한다',
        (tester) async {
          final session = await create(type, timing);
          final container = await open(tester, session);
          final model = container.read(quizViewModelProvider(session).notifier);
          final initial = container
              .read(quizViewModelProvider(session))
              .requireValue;
          if (type == QuestionType.multipleChoice ||
              type == QuestionType.trueFalse) {
            model.selectChoice(
              initial.currentItem.questionSnapshot.choices.first.id,
            );
          } else {
            model.updateTextAnswer('정답');
          }
          if (type == QuestionType.essay &&
              timing == AnswerFeedbackTiming.afterCompletion) {
            await model.submit(isUnknown: true);
          } else {
            await model.submit();
          }
          if (type == QuestionType.essay &&
              timing == AnswerFeedbackTiming.immediate) {
            await model.submit(manualCorrect: true);
          }
          await tester.pumpAndSettle();
          final before = container
              .read(quizViewModelProvider(session))
              .requireValue;
          if (type == QuestionType.essay || type == QuestionType.shortAnswer) {
            await tester.enterText(
              find.byKey(Key('answer-${before.currentItem.id}')),
              '작성 중 답안',
            );
          } else {
            model.selectChoice(
              before.currentItem.questionSnapshot.choices.last.id,
            );
            await tester.pumpAndSettle();
          }
          final button = find.byKey(const Key('stop-quiz-button'));
          final back = tester.widget<IconButton>(button);
          expect(
            back.icon,
            isA<Icon>().having(
              (icon) => icon.icon,
              'icon',
              Icons.arrow_back_rounded,
            ),
          );
          expect(find.text('중단'), findsNothing);
          expect(
            tester.getCenter(button).dx,
            lessThan(tester.getCenter(find.text('문제 풀기')).dx),
          );
          final stale = back.onPressed!;
          stale();
          stale();
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('stop-quiz-confirm-dialog')),
            findsOneWidget,
          );
          expect(
            tester.getSize(find.byKey(const Key('continue-quiz-button'))).width,
            closeTo(
              tester
                  .getSize(find.byKey(const Key('confirm-stop-quiz-button')))
                  .width,
              0.1,
            ),
          );
          await tester.tap(find.byKey(const Key('continue-quiz-button')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('quiz-view')), findsOneWidget);
          final continued = container
              .read(quizViewModelProvider(session))
              .requireValue;
          expect(continued.currentItem.id, before.currentItem.id);
          expect(continued.details.session.finishedAt, isNull);
          if (type == QuestionType.essay || type == QuestionType.shortAnswer) {
            expect(continued.textAnswer, '작성 중 답안');
            expect(find.text('작성 중 답안'), findsOneWidget);
          } else {
            expect(
              continued.selectedChoiceId,
              before.currentItem.questionSnapshot.choices.last.id,
            );
          }
          await confirm(tester);
          expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
          expect(find.text('학습 중단'), findsOneWidget);
          expect(find.text('전체 2문항 중 1문항 채점 완료'), findsOneWidget);
          final ended = (await quizzes.getSession(session))!;
          expect(ended.session.finishedAt, isNotNull);
          expect(ended.session.completedQuestions, 1);
          expect(ended.items.last.attemptId, isNull);
          final saved = await attempts.getAttemptsForSession(session);
          expect(saved, hasLength(1));
          expect(
            saved.single.score,
            type == QuestionType.essay &&
                    timing == AnswerFeedbackTiming.afterCompletion
                ? 0
                : 1,
          );
          container.read(routerProvider).go(AppRoutes.studySession(session));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('stop-quiz-button')), findsNothing);
          expect(find.text('결과 보기'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        variant: platforms,
      );
    }
  }
  for (final type in QuestionType.values) {
    for (final timing in AnswerFeedbackTiming.values) {
      testWidgets('${type.name} ${timing.name}: 재검토 취소·스킵·재개 및 점수 제외', (
        tester,
      ) async {
        final session = await create(type, timing);
        final container = await open(tester, session);
        var model = container.read(quizViewModelProvider(session).notifier);
        final initial = container
            .read(quizViewModelProvider(session))
            .requireValue;
        final first = initial.currentItem;
        final written =
            type == QuestionType.essay || type == QuestionType.shortAnswer;
        if (written) {
          model.updateTextAnswer('작성 중');
        } else {
          model.selectChoice(first.questionSnapshot.choices.last.id);
        }
        await tester.pumpAndSettle();
        final review = find.byKey(const Key('request-question-review-button'));
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        expect(
          tester.getCenter(find.byKey(const Key('unknown-answer-button'))).dy,
          lessThan(
            tester.getCenter(find.byKey(const Key('quiz-review-divider'))).dy,
          ),
        );
        expect(
          tester.getCenter(find.byKey(const Key('quiz-review-divider'))).dy,
          lessThan(tester.getCenter(review).dy),
        );
        final stale = tester.widget<OutlinedButton>(review).onPressed!;
        stale();
        stale();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('question-review-confirm-dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('cancel-question-review-button')),
        );
        await tester.pumpAndSettle();
        final continued = container
            .read(quizViewModelProvider(session))
            .requireValue;
        expect(continued.currentItem.id, first.id);
        expect(
          written ? continued.textAnswer : continued.selectedChoiceId,
          written ? '작성 중' : first.questionSnapshot.choices.last.id,
        );
        expect(
          (await DriftQuestionRepository(db).getQuestion(first.questionId))!
              .status,
          QuestionStatus.approved,
        );
        stale();
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('confirm-question-review-button')),
        );
        await tester.pumpAndSettle();
        var next = container.read(quizViewModelProvider(session)).requireValue;
        expect(next.currentItem.id, initial.details.items.last.id);
        expect(next.details.processedQuestions, 1);
        expect(next.details.session.completedQuestions, 0);
        expect(next.details.items.first.skippedForReview, isTrue);
        expect(next.textAnswer, isEmpty);
        expect(next.selectedChoiceId, isNull);
        expect(
          (await DriftQuestionRepository(db).getQuestion(first.questionId))!
              .status,
          QuestionStatus.draft,
        );
        expect(await attempts.getAttemptsForSession(session), isEmpty);
        container.invalidate(quizViewModelProvider(session));
        await tester.pumpAndSettle();
        next = container.read(quizViewModelProvider(session)).requireValue;
        expect(next.currentItem.id, initial.details.items.last.id);
        stale();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('question-review-confirm-dialog')),
          findsNothing,
        );
        model = container.read(quizViewModelProvider(session).notifier);
        if (written) {
          model.updateTextAnswer('정답');
        } else {
          model.selectChoice(
            next.currentItem.questionSnapshot.choices.first.id,
          );
        }
        await model.submit();
        if (type == QuestionType.essay) await model.submit(manualCorrect: true);
        container.read(routerProvider).go(AppRoutes.studyResult(session));
        await tester.pumpAndSettle();
        final summary = await container.read(
          quizResultProvider(session).future,
        );
        expect(summary.totalScore, 1);
        expect(summary.maxScore, 1);
        expect(summary.accuracyPercent, 100);
        expect(summary.skippedQuestions, 1);
        expect(summary.stopped, isFalse);
        expect(summary.attempts.single.questionId, next.currentItem.questionId);
        expect(find.text('학습 완료'), findsOneWidget);
        expect(find.text('재검토 요청 1문항은 점수와 정답률에서 제외됩니다.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: platforms);
    }
  }
  testWidgets('모든 문제를 재검토 요청해도 0점·0문항으로 정상 종료한다', (tester) async {
    final session = await create(
      QuestionType.trueFalse,
      AnswerFeedbackTiming.immediate,
    );
    final container = await open(tester, session);
    for (var i = 0; i < 2; i++) {
      final review = find.byKey(const Key('request-question-review-button'));
      await tester.ensureVisible(review);
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-question-review-button')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
    expect(find.text('학습 완료'), findsOneWidget);
    final summary = await container.read(quizResultProvider(session).future);
    expect(summary.stopped, isFalse);
    expect(summary.skippedQuestions, 2);
    expect(summary.totalScore, 0);
    expect(summary.maxScore, 0);
    expect(summary.accuracyPercent, 0);
    expect(summary.attempts, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
  testWidgets('시스템 뒤로가기도 중단 확인을 거치며 취소하면 유지된다', (tester) async {
    final session = await create(
      QuestionType.trueFalse,
      AnswerFeedbackTiming.immediate,
    );
    await open(tester, session);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stop-quiz-confirm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('continue-quiz-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quiz-view')), findsOneWidget);
    expect((await quizzes.getSession(session))!.session.finishedAt, isNull);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
  testWidgets('재검토 저장 실패와 중복 클릭은 답안·문제 상태를 보존하고 재시도한다', (tester) async {
    final session = await create(
      QuestionType.shortAnswer,
      AnswerFeedbackTiming.immediate,
    );
    final controlled = _ControlledQuizzes(quizzes)..failNextReview = true;
    final container = await open(tester, session, controlled: controlled);
    final first = container
        .read(quizViewModelProvider(session))
        .requireValue
        .currentItem;
    await tester.enterText(find.byKey(Key('answer-${first.id}')), '작성 중');
    final review = find.byKey(const Key('request-question-review-button'));
    await tester.ensureVisible(review);
    await tester.pumpAndSettle();
    final stale = tester.widget<OutlinedButton>(review).onPressed!;
    stale();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-question-review-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    expect(
      container.read(quizViewModelProvider(session)).requireValue.textAnswer,
      '작성 중',
    );
    expect(
      (await DriftQuestionRepository(db).getQuestion(first.questionId))!.status,
      QuestionStatus.approved,
    );
    controlled.reviewGate = Completer<void>();
    addTearDown(() {
      if (!controlled.reviewGate!.isCompleted) {
        controlled.reviewGate!.complete();
      }
    });
    stale();
    stale();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-question-review-button')));
    await tester.pump();
    expect(tester.widget<OutlinedButton>(review).onPressed, isNull);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('stop-quiz-button')))
          .onPressed,
      isNull,
    );
    stale();
    await tester.pump();
    expect(controlled.reviewCalls, 2);
    controlled.reviewGate!.complete();
    await tester.pumpAndSettle();
    expect(
      container
          .read(quizViewModelProvider(session))
          .requireValue
          .currentItem
          .id,
      isNot(first.id),
    );
    expect(await attempts.getAttemptsForSession(session), isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
  testWidgets('채점 대기 서술형을 중단해도 임의로 오답 처리하거나 채점 기록을 만들지 않는다', (tester) async {
    final session = await create(
      QuestionType.essay,
      AnswerFeedbackTiming.afterCompletion,
    );
    final container = await open(tester, session);
    final model = container.read(quizViewModelProvider(session).notifier);
    model.updateTextAnswer('나중에 채점할 서술형 답안');
    await model.submit();
    await tester.pumpAndSettle();
    await confirm(tester);
    final ended = (await quizzes.getSession(session))!;
    expect(ended.session.finishedAt, isNotNull);
    expect(ended.session.completedQuestions, 0);
    expect(
      ended.items.first.pendingEssayResponse!['textAnswer'],
      '나중에 채점할 서술형 답안',
    );
    expect(await attempts.getAttemptsForSession(session), isEmpty);
    expect(find.text('학습 중단'), findsOneWidget);
    expect(find.text('채점한 문항이 없어요.'), findsOneWidget);
    expect(find.text('모든 문제를 맞혔어요.'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
  testWidgets('중단 저장 실패는 오류를 표시하고 답안을 유지하며 재시도·중복 클릭을 안전하게 처리한다', (
    tester,
  ) async {
    final session = await create(
      QuestionType.shortAnswer,
      AnswerFeedbackTiming.immediate,
    );
    final controlled = _ControlledQuizzes(quizzes)..failNext = true;
    final container = await open(tester, session, controlled: controlled);
    final item = container
        .read(quizViewModelProvider(session))
        .requireValue
        .currentItem;
    await tester.enterText(find.byKey(Key('answer-${item.id}')), '작성 중');
    await confirm(tester);
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    expect((await quizzes.getSession(session))!.session.finishedAt, isNull);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    expect(find.text('작성 중'), findsOneWidget);
    controlled.gate = Completer<void>();
    addTearDown(() {
      if (!controlled.gate!.isCompleted) controlled.gate!.complete();
    });
    final stop = tester
        .widget<IconButton>(find.byKey(const Key('stop-quiz-button')))
        .onPressed!;
    stop();
    stop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-stop-quiz-button')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('stop-quiz-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('submit-answer-button')))
          .onPressed,
      isNull,
    );
    stop();
    await tester.pump();
    expect(controlled.calls, 2);
    controlled.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
    expect(await attempts.getAttemptsForSession(session), isEmpty);
    expect(find.text('채점한 문항이 없어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}

class _ControlledQuizzes implements QuizRepository {
  _ControlledQuizzes(this.delegate);
  final QuizRepository delegate;
  bool failNext = false;
  int calls = 0;
  Completer<void>? gate;
  bool failNextReview = false;
  int reviewCalls = 0;
  Completer<void>? reviewGate;
  @override
  Future<void> finishSession(String id) async {
    calls++;
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw const DatabaseFailure('테스트 중단 저장 실패');
    }
    return delegate.finishSession(id);
  }

  @override
  Future<String> createSession({
    required QuizFilter filter,
    required List<Question> questions,
  }) => delegate.createSession(filter: filter, questions: questions);
  @override
  Future<QuizSessionDetails?> getSession(String id) => delegate.getSession(id);
  @override
  Future<QuizSessionDetails?> resumeSession(String id) =>
      delegate.resumeSession(id);
  @override
  Future<void> linkAttempt({
    required String sessionId,
    required String itemId,
    required String attemptId,
  }) => delegate.linkAttempt(
    sessionId: sessionId,
    itemId: itemId,
    attemptId: attemptId,
  );
  @override
  Future<void> saveEssayResponse({
    required String sessionId,
    required String itemId,
    required String answer,
    required int durationMs,
  }) => delegate.saveEssayResponse(
    sessionId: sessionId,
    itemId: itemId,
    answer: answer,
    durationMs: durationMs,
  );
  @override
  Future<void> skipForReview({
    required String sessionId,
    required String itemId,
  }) async {
    reviewCalls++;
    await reviewGate?.future;
    if (failNextReview) {
      failNextReview = false;
      throw const DatabaseFailure('테스트 재검토 저장 실패');
    }
    await delegate.skipForReview(sessionId: sessionId, itemId: itemId);
  }
}
