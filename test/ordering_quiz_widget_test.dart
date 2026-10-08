import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/features/study/quiz/quiz_view_model.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/shared/widgets/ordering_answer_picker.dart';
import 'package:review_platform/shared/widgets/ordering_sequence.dart';
import 'package:review_platform/shared/widgets/study_text.dart';

import 'support/fake_sync.dart';

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.android,
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('둥근 사각 배지의 빈 상태·선택 순서·재번호화 / $brightness · ${scale}x', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        const choices = [
          SnapshotChoice(id: 'a', text: '초기 설정을 완료한다.', isCorrect: true),
          SnapshotChoice(
            id: 'b',
            text: '자료를 읽고 필요한 정보를 처리한다.',
            isCorrect: true,
          ),
          SnapshotChoice(
            id: 'c',
            text: '상태를 확인하고 다음 단계의 입력을 준비한다.',
            isCorrect: true,
          ),
          SnapshotChoice(id: 'd', text: '자료를 계산하고 결과를 검증한다.', isCorrect: true),
          SnapshotChoice(
            id: 'e',
            text: '결과를 저장하고 내용을 다시 확인한다.',
            isCorrect: true,
          ),
          SnapshotChoice(id: 'f', text: '사용한 자원을 정리한다.', isCorrect: true),
        ];
        var selected = <String>[];
        late StateSetter update;
        var enabled = true;
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light
                ? AppTheme.light
                : AppTheme.dark,
            home: Scaffold(
              body: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return OrderingAnswerPicker(
                      choices: choices,
                      selectedIds: selected,
                      enabled: enabled,
                      onToggle: (id) => setState(() {
                        if (!selected.remove(id)) selected.add(id);
                      }),
                      onClear: () => setState(() => selected = []),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        String rank(String id) => tester
            .widget<Text>(find.byKey(Key('ordering-choice-rank-$id')))
            .data!;
        Finder badge(String id) =>
            find.byKey(Key('ordering-choice-rank-badge-$id'));
        BoxDecoration decoration(String id) =>
            tester.widget<DecoratedBox>(badge(id)).decoration as BoxDecoration;
        final colors = Theme.of(tester.element(badge('a'))).colorScheme;
        final rankStyle = Theme.of(tester.element(badge('a')))
            .textTheme
            .labelLarge!;
        final textHeight =
            MediaQuery.textScalerOf(tester.element(badge('a')))
                .scale(rankStyle.fontSize!) *
            (rankStyle.height ?? 1.25);
        final previousExtent = (textHeight + AppSpacing.lg).clamp(
          AppSpacing.section,
          double.infinity,
        );
        Future<void> tap(String id) async {
          final button = find.byKey(Key('ordering-choice-$id'));
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          await tester.tap(button);
          await tester.pumpAndSettle();
        }

        void expectNoSummary() {
          expect(find.textContaining('내 답안'), findsNothing);
          expect(find.textContaining('선지를 순서대로'), findsNothing);
          expect(find.text('선지'), findsNothing);
          expect(find.textContaining('번째'), findsNothing);
          expect(find.byType(OrderingSequence), findsNothing);
        }

        expectNoSummary();
        for (final choice in choices) {
          expect(rank(choice.id), isEmpty);
          final size = tester.getSize(badge(choice.id));
          expect(size.width, size.height);
          expect(size.width, closeTo(previousExtent * 0.8 * 0.9, 0.001));
          final choiceButton = find.byKey(Key('ordering-choice-${choice.id}'));
          final text = find.descendant(
            of: choiceButton,
            matching: find.byType(StudyText),
          );
          expect(
            tester.getCenter(text).dy,
            closeTo(tester.getCenter(badge(choice.id)).dy, 0.001),
          );
          expect(
            tester.getCenter(text).dy,
            closeTo(tester.getCenter(choiceButton).dy, 0.001),
          );
          expect(
            tester.getSize(choiceButton).height,
            greaterThanOrEqualTo(AppLayout.touchTarget),
          );
          expect(decoration(choice.id).color, colors.surface);
          expect(
            decoration(choice.id).borderRadius,
            BorderRadius.circular(AppRadius.control),
          );
          expect(
            (decoration(choice.id).border! as Border).top.color,
            colors.outline,
          );
        }
        final emptySize = tester.getSize(badge('d'));
        // The fourth displayed choice is the FIRST selected step, not "4.".
        await tap('d');
        await tap('b');
        await tap('a');
        expect(rank('d'), '1');
        expect(rank('b'), '2');
        expect(rank('a'), '3');
        expect(decoration('d').color, colors.primary);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('ordering-choice-rank-d')))
              .style!
              .color,
          colors.onPrimary,
        );
        expect(tester.getSize(badge('d')), emptySize);
        final rankCenter = tester.getCenter(
          find.byKey(const Key('ordering-choice-rank-d')),
        );
        expect(tester.getCenter(badge('d')).dx, closeTo(rankCenter.dx, 0.001));
        expect(tester.getCenter(badge('d')).dy, closeTo(rankCenter.dy, 0.001));
        expect(rank('c'), isEmpty);
        expectNoSummary();
        final content = find.descendant(
          of: find.byKey(const Key('ordering-choice-d')),
          matching: find.byType(StudyText),
        );
        final alignedX = tester.getTopLeft(content).dx;
        await tap('b');
        expect(rank('b'), isEmpty);
        expect(rank('a'), '2');
        expect(rank('d'), '1');
        expect(decoration('b').color, colors.surface);
        expect(tester.getTopLeft(content).dx, alignedX);
        await tap('b');
        expect(rank('b'), '3');
        final clear = find.byKey(const Key('ordering-answer-clear'));
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(selected, isEmpty);
        for (final choice in choices) {
          expect(rank(choice.id), isEmpty);
        }
        for (final choice in choices.reversed) {
          await tap(choice.id);
        }
        expect(rank('a'), '6');
        final numberRect = tester.getRect(
          find.byKey(const Key('ordering-choice-rank-a')),
        );
        final badgeRect = tester.getRect(badge('a'));
        expect(badgeRect.contains(numberRect.topLeft), isTrue);
        expect(badgeRect.contains(numberRect.bottomRight), isTrue);
        expectNoSummary();
        update(() => enabled = false);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('ordering-choice-a')),
              )
              .onPressed,
          isNull,
        );
        expect(rank('a'), '6');
        expect(decoration('a').color, colors.surfaceContainerHighest);
        expect(tester.takeException(), isNull);
      }, variant: platforms);
    }
  }
  for (final brightness in Brightness.values) {
    for (final mode in ['correct', 'wrong', 'unknown', 'review']) {
      testWidgets(
        '순서 배열형 $mode / $brightness: 360dp·글자 200%, 선택 취소·초기화·저장·결과',
        (tester) async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearAllTestValues);
          await tester.binding.setSurfaceSize(const Size(360, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final folder = await DriftFolderRepository(db)
              .createFolder(name: '순서');
          final repo = DriftQuestionRepository(db);
          final id = await repo.createQuestion(
            QuestionDraft(
              folderId: folder,
              type: QuestionType.ordering,
              prompt: '단계를 올바른 순서로 재구성해라.',
              choices: const [
                QuestionChoiceDraft(text: '초기 설정을 완료한다.', isCorrect: true),
                QuestionChoiceDraft(
                  text: '자료를 읽고 필요한 정보를 처리한다.',
                  isCorrect: true,
                ),
                QuestionChoiceDraft(text: '정리하고 결과를 저장한다.', isCorrect: true),
              ],
              correctOrder: const [1, 2, 3],
              explanation: '처리 전에 설정하고 처리 후 결과를 저장한다.',
            ),
          );
          final question = (await repo.getQuestion(id))!;
          final quizzes = DriftQuizRepository(db);
          final session = await quizzes.createSession(
            filter: QuizFilter(
              rootFolderId: folder,
              enabledQuestionTypes: const {QuestionType.ordering},
              questionCount: 1,
              feedbackTiming: AnswerFeedbackTiming.afterCompletion,
            ),
            questions: [question],
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appDatabaseProvider.overrideWithValue(db),
                isWindowsPlatformProvider.overrideWithValue(false),
                syncCredentialsStoreProvider.overrideWithValue(
                  MemorySyncCredentialsStore(),
                ),
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
          Future<void> tap(Finder finder) async {
            await tester.ensureVisible(finder);
            await tester.pumpAndSettle();
            await tester.tap(finder);
            await tester.pumpAndSettle();
          }

          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('submit-answer-button')),
                )
                .onPressed,
            isNull,
          );
          final first = question.correctChoiceIds.first;
          await tap(find.byKey(Key('ordering-choice-$first')));
          expect(
            container
                .read(quizViewModelProvider(session))
                .value!
                .orderedChoiceIds,
            [first],
          );
          await tap(find.byKey(Key('ordering-choice-$first')));
          expect(
            container
                .read(quizViewModelProvider(session))
                .value!
                .orderedChoiceIds,
            isEmpty,
          );
          await tap(find.byKey(Key('ordering-choice-$first')));
          await tap(find.byKey(const Key('ordering-answer-clear')));
          expect(
            container
                .read(quizViewModelProvider(session))
                .value!
                .orderedChoiceIds,
            isEmpty,
          );
          if (mode == 'review') {
            await tap(find.byKey(const Key('request-question-review-button')));
            await tap(find.byKey(const Key('confirm-question-review-button')));
            expect((await repo.getQuestion(id))!.status, QuestionStatus.draft);
            expect(
              (await quizzes.getSession(session))!
                  .items
                  .single
                  .skippedForReview,
              isTrue,
            );
            expect(
              await DriftAttemptRepository(db).getAttemptsForSession(session),
              isEmpty,
            );
          } else {
            if (mode == 'unknown') {
              await tap(find.byKey(Key('ordering-choice-$first')));
              await tap(find.byKey(const Key('unknown-answer-button')));
            } else {
              final order = mode == 'correct'
                  ? question.correctChoiceIds
                  : question.correctChoiceIds.reversed.toList();
              for (final step in order) {
                await tap(find.byKey(Key('ordering-choice-$step')));
              }
              expect(
                tester
                    .widget<FilledButton>(
                      find.byKey(const Key('submit-answer-button')),
                    )
                    .onPressed,
                isNotNull,
              );
              await tap(find.byKey(const Key('submit-answer-button')));
            }
            final attempts = await DriftAttemptRepository(db)
                .getAttemptsForSession(session);
            final answer = attempts.single;
            expect(answer.score, mode == 'correct' ? 1 : 0);
            expect(answer.maxScore, 1);
            expect(answer.isUnknown, mode == 'unknown');
            expect(
              answer.response.containsKey('orderedChoiceIds'),
              mode != 'unknown',
            );
            await tap(find.byKey(Key('quiz-answer-result-$id')));
            expect(find.text('내 답'), findsOneWidget);
            expect(find.text('정답'), findsWidgets);
            expect(find.textContaining('처리 전에 설정하고'), findsOneWidget);
          }
          expect(find.byKey(const Key('quiz-result-view')), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        variant: platforms,
      );
    }
  }

  testWidgets('수동 생성·순서 편집·저장·재진입에서 정답과 단계를 보존한다', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final folder = await DriftFolderRepository(db).createFolder(name: '편집');
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          isWindowsPlatformProvider.overrideWithValue(false),
          syncCredentialsStoreProvider.overrideWithValue(
            MemorySyncCredentialsStore(),
          ),
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
    final router = container.read(routerProvider);
    router.go('${AppRoutes.newQuestion}?folderId=$folder');
    await tester.pumpAndSettle();
    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tap(find.text('순서 배열형'));
    await tester.enterText(
      find.byKey(const Key('question-prompt-field')),
      '과정 배열',
    );
    for (var i = 0; i < 4; i++) {
      final field = find.byKey(Key('ordering-step-field-$i'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '단계 $i');
    }
    await tap(find.byKey(const Key('ordering-step-up-1')));
    await tap(find.byKey(const Key('save-question-button')));
    final repo = DriftQuestionRepository(db);
    final rows = await (db.select(
      db.questions,
    )..where((row) => row.folderId.equals(folder))).get();
    expect(rows, hasLength(1));
    final question = (await repo.getQuestion(rows.single.id))!;
    expect(question.type, QuestionType.ordering);
    expect(question.choices.map((c) => c.text), [
      '단계 1',
      '단계 0',
      '단계 2',
      '단계 3',
    ]);
    expect(question.correctChoiceIds, question.choices.map((c) => c.id));
    router.go(AppRoutes.editQuestion(question.id));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('ordering-step-field-0')))
          .controller!
          .text,
      '단계 1',
    );
    await tap(find.byKey(const Key('ordering-step-add')));
    await tester.enterText(
      find.byKey(const Key('ordering-step-field-4')),
      '마지막',
    );
    await tap(find.byKey(const Key('save-question-button')));
    expect((await repo.getQuestion(question.id))!.choices, hasLength(5));
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}
