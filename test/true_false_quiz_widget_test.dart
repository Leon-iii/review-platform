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
import 'package:review_platform/domain/models/attempt.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/repository_providers.dart';

import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late DriftQuestionRepository questions;
  late DriftQuizRepository quizzes;
  late DriftAttemptRepository attempts;
  late String folderId;
  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    questions = DriftQuestionRepository(database);
    quizzes = DriftQuizRepository(database);
    attempts = DriftAttemptRepository(database);
    folderId = await DriftFolderRepository(database).createFolder(name: 'O/X');
  });
  tearDown(() => database.close());

  Future<String> session({
    List<String> answers = const ['O', 'X'],
    AnswerFeedbackTiming timing = AnswerFeedbackTiming.afterCompletion,
  }) async {
    final items = <Question>[];
    for (final (index, answer) in answers.indexed) {
      final id = await questions.createQuestion(
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.trueFalse,
          prompt: 'O/X 문제 ${index + 1}',
          choices: [
            QuestionChoiceDraft(text: 'X', isCorrect: answer == 'X'),
            QuestionChoiceDraft(text: 'O', isCorrect: answer == 'O'),
          ],
        ),
      );
      final question = (await questions.getQuestion(id))!;
      // Snapshot order need not match display order (older/synchronized data).
      items.add(
        Question(
          id: question.id,
          folderId: folderId,
          type: question.type,
          status: question.status,
          prompt: question.prompt,
          choices: question.choices.reversed.toList(),
          acceptableAnswers: question.acceptableAnswers,
          createdAt: question.createdAt,
          updatedAt: question.updatedAt,
        ),
      );
    }
    return quizzes.createSession(
      filter: QuizFilter(
        rootFolderId: folderId,
        enabledQuestionTypes: const {QuestionType.trueFalse},
        questionCount: items.length,
        shuffle: false,
        feedbackTiming: timing,
      ),
      questions: items,
    );
  }

  Future<void> open(
    WidgetTester tester,
    String id, {
    AttemptRepository? controlled,
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
          appDatabaseProvider.overrideWithValue(database),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(),
          ),
          isWindowsPlatformProvider.overrideWithValue(false),
          if (controlled != null)
            attemptRepositoryProvider.overrideWithValue(controlled),
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
    container.read(routerProvider).go(AppRoutes.studySession(id));
    await tester.pumpAndSettle();
  }

  Finder answer(String symbol) =>
      find.byKey(Key('true-false-${symbol.toLowerCase()}-button'));
  Future<void> choose(WidgetTester tester, String symbol) async {
    await tester.ensureVisible(answer(symbol));
    await tester.tap(answer(symbol));
    await tester.pumpAndSettle();
  }

  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });

  for (final timing in AnswerFeedbackTiming.values) {
    testWidgets('큰 O/X 버튼으로 즉시 제출하고 ${timing.name} 정오 공개 설정을 유지한다', (
      tester,
    ) async {
      final id = await session(timing: timing);
      await open(tester, id);
      final o = tester.getRect(answer('O'));
      final x = tester.getRect(answer('X'));
      expect(o.right, lessThan(x.left));
      expect(o.top, x.top);
      expect(o.width, closeTo(x.width, 0.01));
      expect(o.height, greaterThanOrEqualTo(160));
      expect(x.height, greaterThanOrEqualTo(160));
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(find.byKey(const Key('submit-answer-button')), findsNothing);
      await choose(tester, 'O');
      expect(find.text('O/X 문제 2'), findsOneWidget);
      final first = (await attempts.getAttemptsForSession(id)).single;
      expect(first.score, 1);
      expect(
        first.questionSnapshot.choices
            .singleWhere(
              (choice) => choice.id == first.response['selectedChoiceId'],
            )
            .text,
        'O',
      );
      expect(
        find.text('정답이에요.'),
        timing == AnswerFeedbackTiming.immediate
            ? findsOneWidget
            : findsNothing,
      );
      final staleFinal = tester.widget<FilledButton>(answer('X')).onPressed!;
      await choose(tester, 'X');
      staleFinal();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
      final saved = await attempts.getAttemptsForSession(id);
      expect(saved, hasLength(2));
      expect(saved.every((attempt) => attempt.score == 1), isTrue);
      expect((await quizzes.getSession(id))!.session.finishedAt, isNotNull);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('O를 눌러도 정답이 X이면 오답으로 채점하여 바로 완료한다', (tester) async {
    final id = await session(answers: ['X']);
    await open(tester, id);
    await choose(tester, 'O');
    expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
    expect((await attempts.getAttemptsForSession(id)).single.score, 0);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('O/X 저장 중 두 버튼을 비활성화하고 연속·이전 문제 클릭을 무시한다', (tester) async {
    final id = await session();
    final controlled = _ControlledAttempts(attempts)..gate = Completer<void>();
    addTearDown(() {
      if (!controlled.gate!.isCompleted) controlled.gate!.complete();
    });
    await open(tester, id, controlled: controlled);
    final staleO = tester.widget<FilledButton>(answer('O')).onPressed!;
    final staleX = tester.widget<FilledButton>(answer('X')).onPressed!;
    final staleUnknown = tester
        .widget<OutlinedButton>(find.byKey(const Key('unknown-answer-button')))
        .onPressed!;
    await tester.tap(answer('O'));
    await tester.pump();
    expect(tester.widget<FilledButton>(answer('O')).onPressed, isNull);
    expect(tester.widget<FilledButton>(answer('X')).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('unknown-answer-button')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('true-false-submit-progress')), findsOneWidget);
    staleX();
    staleUnknown();
    staleO();
    await tester.pump();
    expect(controlled.calls, 1);
    controlled.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('O/X 문제 2'), findsOneWidget);
    staleO();
    await tester.pumpAndSettle();
    expect(controlled.calls, 1);
    expect((await attempts.getAttemptsForSession(id)), hasLength(1));
    expect(
      (await attempts.getAttemptsForSession(id)).single.isUnknown,
      isFalse,
    );
    expect(find.byKey(const Key('app-error-dialog')), findsNothing);
    await choose(tester, 'X');
    expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
    expect((await attempts.getAttemptsForSession(id)), hasLength(2));
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('모름 저장 중 O/X·모름 연속 클릭을 무시하고 완료 후 이전 클릭을 차단한다', (tester) async {
    final id = await session();
    final controlled = _ControlledAttempts(attempts)..gate = Completer<void>();
    addTearDown(() {
      if (!controlled.gate!.isCompleted) controlled.gate!.complete();
    });
    await open(tester, id, controlled: controlled);
    final unknown = find.byKey(const Key('unknown-answer-button'));
    final staleUnknown = tester.widget<OutlinedButton>(unknown).onPressed!;
    final staleO = tester.widget<FilledButton>(answer('O')).onPressed!;
    await tester.ensureVisible(unknown);
    await tester.tap(unknown);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(unknown).onPressed, isNull);
    expect(tester.widget<FilledButton>(answer('O')).onPressed, isNull);
    expect(tester.widget<FilledButton>(answer('X')).onPressed, isNull);
    staleO();
    staleUnknown();
    await tester.pump();
    expect(controlled.calls, 1);
    controlled.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('O/X 문제 2'), findsOneWidget);
    staleUnknown();
    await tester.pumpAndSettle();
    expect(controlled.calls, 1);
    expect((await attempts.getAttemptsForSession(id)).single.isUnknown, isTrue);
    expect(find.byKey(const Key('app-error-dialog')), findsNothing);
    await choose(tester, 'X');
    expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
    expect((await attempts.getAttemptsForSession(id)), hasLength(2));
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('모름 저장 실패 후 같은 문제에서 정답으로 다시 제출할 수 있다', (tester) async {
    final id = await session(answers: ['O']);
    final controlled = _ControlledAttempts(attempts)..failNext = true;
    await open(tester, id, controlled: controlled);
    final unknown = find.byKey(const Key('unknown-answer-button'));
    await tester.ensureVisible(unknown);
    await tester.tap(unknown);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    expect(await attempts.getAttemptsForSession(id), isEmpty);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    expect(find.text('O/X 문제 1'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(unknown).onPressed, isNotNull);
    await choose(tester, 'O');
    final saved = (await attempts.getAttemptsForSession(id)).single;
    expect(saved.isUnknown, isFalse);
    expect(saved.score, 1);
    expect(controlled.calls, 2);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('O/X 저장 실패를 알리고 같은 문제에서 버튼으로 재시도한다', (tester) async {
    final id = await session(answers: ['O']);
    final controlled = _ControlledAttempts(attempts)..failNext = true;
    await open(tester, id, controlled: controlled);
    await choose(tester, 'X');
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    expect(find.text('테스트 저장 실패'), findsOneWidget);
    expect(await attempts.getAttemptsForSession(id), isEmpty);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    expect(find.text('O/X 문제 1'), findsOneWidget);
    expect(tester.widget<FilledButton>(answer('O')).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(answer('X')).onPressed, isNotNull);
    await choose(tester, 'O');
    expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
    expect((await attempts.getAttemptsForSession(id)).single.score, 1);
    expect(controlled.calls, 2);
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}

class _ControlledAttempts implements AttemptRepository {
  _ControlledAttempts(this.delegate);
  final AttemptRepository delegate;
  Completer<void>? gate;
  bool failNext = false;
  int calls = 0;
  @override
  Future<String> recordAttempt(AttemptDraft draft) async {
    calls++;
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw const DatabaseFailure('테스트 저장 실패');
    }
    return delegate.recordAttempt(draft);
  }

  @override
  Future<List<Attempt>> getAllAttempts() => delegate.getAllAttempts();
  @override
  Future<List<Attempt>> getAttemptsForQuestion(String id) =>
      delegate.getAttemptsForQuestion(id);
  @override
  Future<List<Attempt>> getAttemptsForSession(String id) =>
      delegate.getAttemptsForSession(id);
  @override
  Future<List<Attempt>> getRecentAttempts({int limit = 50}) =>
      delegate.getRecentAttempts(limit: limit);
  @override
  Stream<List<Attempt>> watchAttempts() => delegate.watchAttempts();
}
