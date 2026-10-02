import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';

import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late DriftQuestionRepository questions;
  late DriftQuizRepository quizzes;
  late String folderId;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    questions = DriftQuestionRepository(database);
    quizzes = DriftQuizRepository(database);
    folderId = await DriftFolderRepository(database).createFolder(name: '학습');
  });
  tearDown(() => database.close());

  Widget app() => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      syncCredentialsStoreProvider.overrideWithValue(
        MemorySyncCredentialsStore(),
      ),
      isWindowsPlatformProvider.overrideWithValue(false),
    ],
    child: const ReviewApp(),
  );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  testWidgets('난이도 슬라이더의 양쪽 손잡이를 1~5에서 2~4로 조절한다', (tester) async {
    await tester.binding.setSurfaceSize(
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1100, 1000)
          : const Size(390, 800),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('start-study-button')));
    final finder = find.byKey(const Key('difficulty-range-slider'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    var slider = tester.widget<RangeSlider>(finder);
    expect(slider.values, const RangeValues(1, 5));
    expect(slider.divisions, 4);
    expect(slider.semanticFormatterCallback!(3), '3 · 보통');
    final rect = tester.getRect(finder);
    // Material range-slider endpoints are inset by 24 logical pixels.
    final trackStart = Offset(rect.left + 24, rect.center.dy);
    final trackEnd = Offset(rect.right - 24, rect.center.dy);
    final step = (trackEnd.dx - trackStart.dx) / 4;
    var gesture = await tester.startGesture(trackStart);
    await gesture.moveBy(Offset(step, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.widget<RangeSlider>(finder).values, const RangeValues(2, 5));
    gesture = await tester.startGesture(trackEnd);
    await gesture.moveBy(Offset(-step, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    slider = tester.widget<RangeSlider>(finder);
    expect(slider.values, const RangeValues(2, 4));
    expect(find.text('2 · 쉬움 ~ 4 · 어려움'), findsOneWidget);
    expect(find.byKey(const Key('difficulty-filter-1')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('양 끝을 같은 난이도로 지정하면 그 난이도만 출제한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final level in [2, 3, 4]) {
      await questions.createQuestion(
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '난이도 $level 문제',
          difficulty: level,
          acceptableAnswers: const ['정답'],
        ),
      );
    }
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('start-study-button')));
    final finder = find.byKey(const Key('difficulty-range-slider'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    tester.widget<RangeSlider>(finder).onChanged!(const RangeValues(3, 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('difficulty-range-label')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('difficulty-range-label'))).data,
      '3 · 보통',
    );
    await tapVisible(tester, find.byKey(const Key('start-quiz-button')));
    final row = await database.select(database.quizSessions).getSingle();
    final details = (await quizzes.getSession(row.id))!;
    expect(details.items.single.questionSnapshot.prompt, '난이도 3 문제');
    expect(details.session.filter.enabledDifficulties, {3});
    expect(tester.takeException(), isNull);
  });

  testWidgets('홈 제목은 다른 화면과 같은 높이에 고정된다', (tester) async {
    await tester.binding.setSurfaceSize(
      defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1100, 900)
          : const Size(390, 800),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final home = find.text('복습 노트');
    expect(find.byType(SliverAppBar), findsNothing);
    expect(
      find.ancestor(of: home, matching: find.byType(AppBar)),
      findsOneWidget,
    );
    final top = tester.getTopLeft(home).dy;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(home).dy, top);
    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();
    final statistics = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('통계'),
    );
    expect(tester.getTopLeft(statistics).dy, closeTo(top, 1));
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  for (final timing in AnswerFeedbackTiming.values) {
    testWidgets('${timing.name}: 세 유형의 정오 공개 시점과 난이도 선택 및 재개를 반영한다', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ids = <String>[];
      for (final type in [
        QuestionType.multipleChoice,
        QuestionType.trueFalse,
        QuestionType.shortAnswer,
      ]) {
        ids.add(
          await questions.createQuestion(
            QuestionDraft(
              folderId: folderId,
              type: type,
              prompt: '${type.name} 문제',
              difficulty: type == QuestionType.multipleChoice
                  ? 2
                  : type == QuestionType.trueFalse
                  ? 3
                  : 4,
              choices: type == QuestionType.shortAnswer
                  ? const []
                  : type == QuestionType.trueFalse
                  ? const [
                      QuestionChoiceDraft(text: 'O', isCorrect: true),
                      QuestionChoiceDraft(text: 'X', isCorrect: false),
                    ]
                  : const [
                      QuestionChoiceDraft(text: '맞는 선택지', isCorrect: true),
                      QuestionChoiceDraft(text: '틀린 선택지', isCorrect: false),
                    ],
              acceptableAnswers: type == QuestionType.shortAnswer
                  ? const ['정답']
                  : const [],
            ),
          ),
        );
      }
      await questions.createQuestion(
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          prompt: '난이도 제외 문제',
          difficulty: 1,
          acceptableAnswers: const ['정답'],
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('start-study-button')));
      expect(find.byKey(const Key('study-setup-view')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('difficulty-range-slider'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const Key('true-false-filter'))).dy,
        ),
      );
      final difficultySlider = find.byKey(const Key('difficulty-range-slider'));
      await tester.ensureVisible(difficultySlider);
      await tester.pumpAndSettle();
      tester.widget<RangeSlider>(difficultySlider).onChanged!(
        const RangeValues(2, 4),
      );
      await tester.pumpAndSettle();
      final sliderFinder = find.byKey(const Key('answer-feedback-slider'));
      await tester.ensureVisible(sliderFinder);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(sliderFinder).value, 0);
      if (timing == AnswerFeedbackTiming.afterCompletion) {
        await tester.drag(sliderFinder, const Offset(600, 0));
        await tester.pumpAndSettle();
        expect(tester.widget<Slider>(sliderFinder).value, 1);
      }
      await tapVisible(tester, find.widgetWithText(SwitchListTile, '문제 순서 섞기'));
      await tapVisible(tester, find.byKey(const Key('start-quiz-button')));
      final row = await database.select(database.quizSessions).getSingle();
      final details = (await quizzes.getSession(row.id))!;
      expect(details.items, hasLength(3));
      expect(details.session.filter.enabledDifficulties, {2, 3, 4});
      expect(details.session.filter.feedbackTiming, timing);
      for (var index = 0; index < details.items.length; index++) {
        final item = details.items[index];
        final question = item.questionSnapshot;
        final correct = question.type != QuestionType.trueFalse;
        expect(find.text(question.prompt), findsOneWidget);
        if (question.type == QuestionType.shortAnswer) {
          final field = find.byKey(Key('answer-${item.id}'));
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, '정답');
        } else {
          final choice = question.choices.singleWhere(
            (choice) => choice.isCorrect == correct,
          );
          await tapVisible(tester, find.byKey(Key('choice-${choice.id}')));
        }
        await tapVisible(tester, find.byKey(const Key('submit-answer-button')));
        if (timing == AnswerFeedbackTiming.immediate) {
          expect(find.text(correct ? '정답이에요.' : '오답이에요.'), findsOneWidget);
        } else {
          expect(find.text('정답이에요.'), findsNothing);
          expect(find.text('오답이에요.'), findsNothing);
        }
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        if (index == 0) {
          final container = ProviderScope.containerOf(
            tester.element(find.byKey(const Key('quiz-view'))),
          );
          container.read(routerProvider).go(AppRoutes.home);
          await tester.pumpAndSettle();
          container.read(routerProvider).go(AppRoutes.studySession(row.id));
          await tester.pumpAndSettle();
          final resumed = (await quizzes.resumeSession(row.id))!;
          expect(resumed.session.completedQuestions, 1);
          expect(resumed.session.filter.feedbackTiming, timing);
        }
      }
      expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
      final attempts = await DriftAttemptRepository(database)
          .getAttemptsForSession(row.id);
      expect(attempts, hasLength(3));
      expect(attempts.where((attempt) => attempt.score == 1), hasLength(2));
      final wrongCard = find.byKey(Key('quiz-answer-result-${ids[1]}'));
      expect(wrongCard, findsOneWidget);
      if (timing == AnswerFeedbackTiming.afterCompletion) {
        expect(find.text('문제별 결과'), findsOneWidget);
        for (final id in ids) {
          expect(find.byKey(Key('quiz-answer-result-$id')), findsOneWidget);
        }
      } else {
        expect(find.text('오답 문제'), findsOneWidget);
        expect(find.byKey(Key('quiz-answer-result-${ids[0]}')), findsNothing);
      }
      await tapVisible(tester, wrongCard);
      expect(find.text('내 답: X'), findsOneWidget);
      expect(find.text('정답: O'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }
}
