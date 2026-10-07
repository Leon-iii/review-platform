import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/app/theme.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/shared/widgets/app_action_group.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';

import '../tool/ui_preview.dart';

void main() {
  for (final width in [360.0, 720.0, 1280.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '전체 화면 $width · ${scale}x · $brightness',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 900));
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            tester.platformDispatcher.platformBrightnessTestValue = brightness;
            addTearDown(() {
              tester.platformDispatcher.clearAllTestValues();
              tester.binding.setSurfaceSize(null);
            });
            final fixture = await createUiPreviewFixture();
            try {
              final originalErrorHandler = FlutterError.onError;
              FlutterError.onError = (details) {
                if (details.exceptionAsString().contains('overflowed')) {
                  debugPrint(details.toString());
                }
                originalErrorHandler!(details);
              };
              addTearDown(() => FlutterError.onError = originalErrorHandler);
              await tester.pumpWidget(
                UncontrolledProviderScope(
                  container: fixture.container,
                  child: const ReviewApp(),
                ),
              );
              addTearDown(() async {
                await tester.pumpWidget(const SizedBox());
                await tester.pump();
              });
              await tester.pumpAndSettle();
              final router = fixture.container.read(routerProvider);
              final questions = [
                for (final id in fixture.questionIds)
                  (await DriftQuestionRepository(fixture.database)
                      .getQuestion(id))!,
              ];
              final quiz = DriftQuizRepository(fixture.database);
              final sessions = [
                for (final question in questions)
                  await quiz.createSession(
                    filter: QuizFilter(
                      rootFolderId: fixture.folderId,
                      enabledQuestionTypes: {question.type},
                      questionCount: 1,
                    ),
                    questions: [question],
                  ),
              ];
              final routes = [
                AppRoutes.home,
                AppRoutes.library,
                AppRoutes.folder(fixture.folderId),
                AppRoutes.documentsForSource(
                  fixture.folderId,
                  fixture.sourceId,
                ),
                AppRoutes.documentsForSource(fixture.folderId, fixture.pdfId),
                AppRoutes.questionsForConcept(
                  (await DriftSourceRepository(fixture.database)
                          .getSourceWithConcepts(fixture.sourceId))
                      .concepts
                      .first
                      .id,
                  '웹 캐시의 동작과 캐시 히트·미스',
                ),
                AppRoutes.aiGenerateForSource(
                  fixture.folderId,
                  fixture.sourceId,
                ),
                '${AppRoutes.newQuestion}?folderId=${fixture.folderId}',
                for (final id in fixture.questionIds)
                  AppRoutes.editQuestion(id),
                AppRoutes.studySetup,
                for (final id in sessions) AppRoutes.studySession(id),
                AppRoutes.studyResult(sessions.first),
                AppRoutes.statistics,
                AppRoutes.settings,
                AppRoutes.localServer,
                AppRoutes.llmProfiles,
              ];
              for (final route in routes) {
                router.go(route);
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull, reason: route);
                if (route == AppRoutes.llmProfiles &&
                    width == 1280 &&
                    scale == 1) {
                  final modelText = find.text('preview-model').first;
                  final modelBorder = InputDecorator.containerOf(
                    tester.element(modelText),
                  )!;
                  final reasoningBorder = InputDecorator.containerOf(
                    tester.element(find.byType(Slider).first),
                  )!;
                  expect(
                    modelBorder.size.height,
                    reasoningBorder.size.height,
                    reason: 'parallel model / reasoning input borders',
                  );
                }
                final collapse = find.byKey(const Key('collapse-all-concepts'));
                if (collapse.evaluate().isNotEmpty) {
                  await tester.ensureVisible(collapse);
                  await tester.pumpAndSettle();
                  await tester.tap(collapse);
                  await tester.pumpAndSettle();
                  expect(
                    tester.takeException(),
                    isNull,
                    reason: '$route collapse',
                  );
                  final compactBadges = find.byType(Chip);
                  if (compactBadges.evaluate().isNotEmpty) {
                    final heights = [
                      for (var i = 0; i < compactBadges.evaluate().length; i++)
                        tester.getSize(compactBadges.at(i)).height,
                    ];
                    expect(
                      heights.toSet().length,
                      1,
                      reason: '$route badge group',
                    );
                  }
                }
                final scrollables = find.byType(Scrollable);
                if (scrollables.evaluate().isNotEmpty) {
                  await tester.drag(scrollables.first, const Offset(0, -1800));
                  await tester.pumpAndSettle();
                  expect(
                    tester.takeException(),
                    isNull,
                    reason: '$route scroll',
                  );
                }
              }
            } finally {
              await tester.pumpWidget(const SizedBox());
              fixture.container.dispose();
              await fixture.database.close();
            }
          },
          variant: TargetPlatformVariant({
            width >= 840 ? TargetPlatform.windows : TargetPlatform.android,
          }),
        );
      }
    }
  }

  testWidgets('병렬 버튼과 배지는 같은 형상이며 확대 시 잘리지 않는다', (tester) async {
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SizedBox(
                width: 720,
                child: Column(
                  children: [
                    AppActionGroup(
                      children: [
                        FilledButton(
                          onPressed: () {},
                          child: const Text('변경 저장'),
                        ),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('취소'),
                        ),
                      ],
                    ),
                    const Wrap(
                      children: [
                        ConceptBadge(label: '객관식'),
                        ConceptBadge(label: '검토 완료'),
                        ConceptBadge(label: '중요도 매우 높음'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final filled = tester.getSize(find.byType(FilledButton));
      final outlined = tester.getSize(find.byType(OutlinedButton));
      expect(filled, outlined);
      expect(filled.height, greaterThanOrEqualTo(48));
      final badges = find.byType(Chip);
      final heights = [
        for (var i = 0; i < 3; i++) tester.getSize(badges.at(i)).height,
      ];
      expect(heights.toSet().length, 1);
      expect(tester.takeException(), isNull);
    }
  });

  for (final systemBack in [false, true]) {
    testWidgets('좁은 편집 · 키보드 · 직접 진입 복귀 · ${systemBack ? '시스템' : '헤더'}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 900));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearAllTestValues();
        tester.binding.setSurfaceSize(null);
      });
      final fixture = await createUiPreviewFixture();
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: const ReviewApp(),
          ),
        );
        await tester.pumpAndSettle();
        final router = fixture.container.read(routerProvider);
        // go intentionally creates no previous page. Neither form of back
        // may exit the app, lose the draft or bypass the existing confirmation.
        router.go(AppRoutes.editQuestion(fixture.questionIds.first));
        await tester.pumpAndSettle();
        final prompt = find.byKey(const Key('question-prompt-field'));
        await tester.enterText(
          prompt,
          '긴 지문을 편집하며 키보드가 표시되어도 입력과 저장 행동에 접근할 수 있어야 한다.',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 720);
        await tester.pumpAndSettle();
        final save = find.byKey(const Key('save-question-button'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(AppBackButton));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('unsaved-changes-dialog')), findsOneWidget);
        final actionKeys = [
          'unsaved-continue-button',
          'unsaved-discard-button',
          'unsaved-save-button',
        ];
        final widths = [
          for (final key in actionKeys)
            tester.getSize(find.byKey(Key(key))).width,
        ];
        expect(widths.toSet().length, 1);
        await tester.tap(find.byKey(const Key('unsaved-continue-button')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextFormField>(prompt).controller!.text,
          contains('긴 지문을 편집'),
        );
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(AppBackButton));
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('unsaved-discard-button')));
        await tester.pumpAndSettle();
        expect(
          router.routeInformationProvider.value.uri.path,
          AppRoutes.folder(fixture.folderId),
        );
        expect(tester.takeException(), isNull);

        router.go(
          AppRoutes.aiGenerateForSource(fixture.folderId, fixture.sourceId),
        );
        await tester.pumpAndSettle();
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(AppBackButton));
        }
        await tester.pumpAndSettle();
        expect(
          router.routeInformationProvider.value.uri.path,
          AppRoutes.library,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        fixture.container.dispose();
        await fixture.database.close();
      }
    });
  }

  testWidgets('생성 검수의 삭제 확인 · 확대 · 저장 중 중복 승인 방지', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1000));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.platformDispatcher.clearAllTestValues();
      tester.binding.setSurfaceSize(null);
    });
    late _DelayedApprovalRepository repository;
    final fixture = await createUiPreviewFixture(
      questionRepository: (db) {
        repository = _DelayedApprovalRepository(db);
        return repository;
      },
    );
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: const ReviewApp(),
        ),
      );
      await tester.pumpAndSettle();
      fixture.container
          .read(routerProvider)
          .go(
            AppRoutes.aiGenerateForSource(fixture.folderId, fixture.sourceId),
          );
      await tester.pumpAndSettle();
      final generate = find.byKey(const Key('generate-ai-questions-button'));
      await tester.ensureVisible(generate);
      await tester.pumpAndSettle();
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(find.text('Draft'), findsNothing);
      expect(find.text('미승인'), findsWidgets);
      final delete = find.widgetWithText(TextButton, '삭제').first;
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('문제 삭제'), findsOneWidget);
      expect(find.textContaining('다음 생성 문제를 삭제할까요?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      final approveAll = find.byKey(
        const Key('approve-all-ai-questions-button'),
      );
      await tester.ensureVisible(approveAll);
      await tester.pumpAndSettle();
      final originalAction = tester.widget<FilledButton>(approveAll).onPressed!;
      originalAction();
      originalAction(); // A stale same-frame callback must also be harmless.
      await tester.pump();
      expect(repository.approvalCalls, 1);
      expect(tester.widget<FilledButton>(approveAll).onPressed, isNull);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      for (final button in find.widgetWithText(TextButton, '삭제').evaluate()) {
        expect((button.widget as TextButton).onPressed, isNull);
      }
      repository.release.complete();
      await tester.pumpAndSettle();
      expect(find.text('미승인'), findsNothing);
      expect(find.text('승인됨'), findsWidgets);
      expect(tester.takeException(), isNull);
    } finally {
      if (!repository.release.isCompleted) repository.release.complete();
      await tester.pumpWidget(const SizedBox());
      fixture.container.dispose();
      await fixture.database.close();
    }
  });
}

class _DelayedApprovalRepository extends DriftQuestionRepository {
  _DelayedApprovalRepository(super.database);
  final release = Completer<void>();
  int approvalCalls = 0;
  @override
  Future<void> approveQuestions(Iterable<String> ids) async {
    approvalCalls++;
    await release.future;
    await super.approveQuestions(ids);
  }
}
