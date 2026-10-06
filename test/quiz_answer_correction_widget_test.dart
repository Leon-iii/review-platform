import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/features/library/question_editor/question_editor_view.dart';
import 'package:review_platform/features/study/result/quiz_result_view.dart';
import 'package:review_platform/features/study/result/quiz_result_view_model.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_answer_correction_repository.dart';

import 'support/quiz_answer_correction_fixture.dart';

class ControlledCorrections extends QuizAnswerCorrectionRepository {
  ControlledCorrections(super.database);
  Completer<void>? gate;
  bool fail = false;
  int calls = 0;
  @override
  Future<QuizAnswerCorrection> acceptSubmittedAnswer(String id) async {
    calls++;
    await gate?.future;
    if (fail) throw const DatabaseFailure('테스트 저장 실패');
    return super.acceptSubmittedAnswer(id);
  }
}

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  for (final timing in AnswerFeedbackTiming.values) {
    testWidgets('$timing: 해설 아래 등록 버튼으로 점수 갱신, 파란 실행취소로 복원', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final fixture = await createWrongQuiz(db, timing: timing);
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 900)
            : const Size(360, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            theme: AppTheme.light,
            home: QuizResultView(sessionId: fixture.sessionId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('0%'), findsOneWidget);
      await tester.tap(
        find.byKey(Key('quiz-answer-result-${fixture.question.id}')),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(
        Key('accept-submitted-answer-${fixture.attemptId}'),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(button).dy,
        greaterThan(tester.getBottomLeft(find.text('해설: 정답 등록 테스트 해설')).dy),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      final snackbar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snackbar.action!.label, '실행취소');
      expect(snackbar.action!.textColor, Colors.blue.shade200);
      expect(find.text('제출한 답안을 정답으로 등록했어요.'), findsOneWidget);
      expect(find.text('이 답안을 정답에 추가'), findsNothing);
      expect(find.text('100%'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(QuizResultView)),
      );
      var summary = await container.read(
        quizResultProvider(fixture.sessionId).future,
      );
      expect(summary.totalScore, 1);
      expect(summary.accuracyPercent, 100);
      expect(summary.wrongAttempts, isEmpty);
      await tester.tap(find.text('실행취소'));
      await tester.pumpAndSettle();
      summary = await container.read(
        quizResultProvider(fixture.sessionId).future,
      );
      expect(summary.totalScore, 0);
      expect(summary.accuracyPercent, 0);
      expect(summary.wrongAttempts, hasLength(1));
      expect(
        (await DriftQuestionRepository(db).getQuestion(fixture.question.id))!
            .acceptableAnswers
            .map((a) => a.text),
        ['용어'],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, variant: platforms);
  }

  testWidgets('좁은 화면·2배 글자·다크 테마에서 저장 대기/실패/재시도와 중복 방지', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final fixture = await createWrongQuiz(db);
    final controlled = ControlledCorrections(db)
      ..gate = Completer<void>()
      ..fail = true;
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          quizAnswerCorrectionRepositoryProvider.overrideWithValue(controlled),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: QuizResultView(sessionId: fixture.sessionId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(Key('quiz-answer-result-${fixture.question.id}'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    final button = find.byKey(
      Key('accept-submitted-answer-${fixture.attemptId}'),
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    expect(find.text('정답 등록 중…'), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(controlled.calls, 1);
    controlled.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('테스트 저장 실패'), findsOneWidget);
    expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 0);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    controlled
      ..gate = null
      ..fail = false;
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(controlled.calls, 2);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).action!.textColor,
      Colors.blue.shade800,
    );
    await tester.tap(find.text('실행취소'));
    await tester.pumpAndSettle();
    expect((await db.attemptDao.getAttempt(fixture.attemptId))!.score, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  for (final type in QuestionType.values) {
    testWidgets('$type: 정답 또는 모름에는 등록 버튼이 없고 다른 유형도 제외한다', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final fixture = await createWrongQuiz(
        db,
        type: type,
        unknown: type == QuestionType.shortAnswer,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: QuizResultView(sessionId: fixture.sessionId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('quiz-answer-result-${fixture.question.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('이 답안을 정답에 추가'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets('단답형 편집 시 추가 인정 정답을 허용 정답 필드로 유지한다', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final fixture = await createWrongQuiz(db);
    await QuizAnswerCorrectionRepository(db)
        .acceptSubmittedAnswer(fixture.attemptId);
    await tester.binding.setSurfaceSize(const Size(1100, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/edit',
      routes: [
        GoRoute(path: '/library', builder: (_, _) => const SizedBox()),
        GoRoute(
          path: '/edit',
          builder: (_, _) =>
              QuestionEditorView(questionId: fixture.question.id),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('answer-field-0')))
          .controller!
          .text,
      '용어',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('answer-field-1')))
          .controller!
          .text,
      '다른 용어',
    );
    await tester.enterText(
      find.byKey(const Key('question-prompt-field')),
      '수정한 문제',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save-question-button'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final updated = (await DriftQuestionRepository(db)
        .getQuestion(fixture.question.id))!;
    expect(updated.prompt, '수정한 문제');
    expect(updated.acceptableAnswers.map((a) => a.text), ['용어', '다른 용어']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('객관식 편집은 기존 라디오 버튼과 단일 정답을 유지한다', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final fixture = await createWrongQuiz(
      db,
      type: QuestionType.multipleChoice,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: QuestionEditorView(questionId: fixture.question.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Radio<int>), findsNWidgets(2));
    expect(find.text('정답 하나를 선택해 주세요.'), findsOneWidget);
    expect(find.byKey(const Key('correct-choice-0')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
