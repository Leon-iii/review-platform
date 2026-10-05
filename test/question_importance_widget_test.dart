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
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/library/question_editor/question_concept_picker.dart';
import 'package:review_platform/features/library/question_editor/question_editor_view_model.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_sync.dart';

void main() {
  testWidgets('주개념 선택은 로딩·오류·재시도·빈 목록을 표시한다', (tester) async {
    var calls = 0;
    final loading = Completer<List<QuestionConceptOption>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionConceptPicker(
            loadOptions: () {
              calls++;
              return calls == 1 ? loading.future : Future.value([]);
            },
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    loading.completeError(Exception('선택 목록 실패'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('retry-concept-picker-button')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('retry-concept-picker-button')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('선택할 개념이 없어요. 자료에서 개념을 먼저 추가해 주세요.'), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets(
    '수동 문제의 주개념 검색·선택·저장·재선택·해제를 지원한다',
    (tester) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final folders = DriftFolderRepository(db);
      final folder = await folders.createFolder(name: '문제 폴더');
      final other = await folders.createFolder(name: '다른 폴더');
      final sources = DriftSourceRepository(db);
      final questions = DriftQuestionRepository(db);
      final source = (await sources.createSource(
        folderId: other,
        name: '네트워크 자료',
      )).source;
      final first = await sources.addConcept(
        sourceId: source.id,
        title: '패킷 교환',
        content: '내용',
        importance: ConceptImportance.veryHigh,
      );
      final second = await sources.addConcept(
        sourceId: source.id,
        title: '인터넷 연표',
        content: '내용',
        reviewed: false,
        importance: ConceptImportance.veryLow,
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
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      final router = container.read(routerProvider);
      router.go(AppRoutes.folder(folder));
      await tester.pumpAndSettle();
      unawaited(router.push<void>('${AppRoutes.newQuestion}?folderId=$folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('O/X'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('question-prompt-field')),
        '패킷 교환은 데이터를 패킷으로 나눈다.',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      Future<void> tapVisible(String key) async {
        final finder = find.byKey(Key(key));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        if (key == 'select-primary-concept-button') {
          // Drift's first stream subscription completes outside fake time.
          await tester.runAsync(() async {
            await tester.tap(finder);
            for (var i = 0; i < 100; i++) {
              await tester.pump();
              if (find
                  .byKey(const Key('primary-concept-options'))
                  .evaluate()
                  .isNotEmpty) {
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
        } else {
          await tester.runAsync(() async {
            await tester.tap(finder);
            await Future<void>.delayed(Duration.zero);
          });
        }
        await tester.pumpAndSettle();
      }

      Future<void> select(StudyConcept concept) async {
        await tapVisible('select-primary-concept-button');
        await tester.enterText(
          find.byKey(const Key('primary-concept-search-field')),
          concept.title,
        );
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tapVisible('select-primary-concept-${concept.id}');
      }

      await tapVisible('select-primary-concept-button');
      final search = find.byKey(const Key('primary-concept-search-field'));
      for (final query in ['다른 폴더', '네트워크 자료', '패킷 교환']) {
        await tester.enterText(search, query);
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('select-primary-concept-${first.id}')),
          findsOneWidget,
        );
      }
      await tester.enterText(search, '없는 이름');
      await tester.pumpAndSettle();
      expect(find.text('검색 결과가 없어요.'), findsOneWidget);
      await tester.enterText(search, '패킷 교환');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tapVisible('select-primary-concept-${first.id}');
      var slider = tester.widget<Slider>(
        find.byKey(const Key('question-importance-slider')),
      );
      expect(slider.value, 5);
      expect(slider.onChanged, null);
      await tapVisible('save-question-button');
      final saved = await tester.runAsync(
        () => questions.watchQuestions(folder).first,
      );
      final id = saved!.single.id;
      expect(saved.single.primaryConceptId, first.id);
      expect(saved.single.importance, ConceptImportance.veryHigh);

      unawaited(router.push<void>(AppRoutes.editQuestion(id)));
      await tester.pumpAndSettle();
      expect(find.text('네트워크 자료 · 패킷 교환'), findsOneWidget);
      // Canceling a picker must not clear the current association.
      await tapVisible('select-primary-concept-button');
      await tapVisible('close-concept-picker-button');
      expect(find.text('네트워크 자료 · 패킷 교환'), findsOneWidget);
      await select(second);
      slider = tester.widget<Slider>(
        find.byKey(const Key('question-importance-slider')),
      );
      expect(slider.value, 1);
      expect(slider.onChanged, null);
      await tapVisible('save-question-button');
      expect(
        (await tester.runAsync(() => questions.getQuestion(id)))!
            .primaryConceptId,
        second.id,
      );

      unawaited(router.push<void>(AppRoutes.editQuestion(id)));
      await tester.pumpAndSettle();
      await tapVisible('clear-primary-concept-button');
      slider = tester.widget<Slider>(
        find.byKey(const Key('question-importance-slider')),
      );
      expect(slider.value, 1);
      slider.onChanged!(2);
      await tester.pumpAndSettle();
      await tapVisible('save-question-button');
      final detached = (await tester.runAsync(
        () => questions.getQuestion(id),
      ))!;
      expect(detached.primaryConceptId, null);
      expect(detached.importance, ConceptImportance.low);
      expect(detached.sourceReferences.single.sourceId, source.id);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  for (final inherited in [false, true]) {
    testWidgets(
      '중요도 편집은 ${inherited ? '주개념 상속을 표시한다' : '슬라이더 값을 저장한다'}',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final folder = await DriftFolderRepository(db).createFolder(name: '폴더');
        final questions = DriftQuestionRepository(db);
        QuestionSourceDraft? reference;
        if (inherited) {
          final sources = DriftSourceRepository(db);
          final source = (await sources.createSource(
            folderId: folder,
            name: '자료',
          )).source;
          final concept = await sources.addConcept(
            sourceId: source.id,
            title: '핵심 개념',
            content: '내용',
            importance: ConceptImportance.veryHigh,
          );
          reference = QuestionSourceDraft(
            sourceId: source.id,
            conceptId: concept.id,
            pageNumbers: const [],
          );
        }
        final id = (await questions.createQuestions(
          [
            QuestionDraft(
              folderId: folder,
              type: QuestionType.shortAnswer,
              prompt: '문제',
              acceptableAnswers: const ['정답'],
            ),
          ],
          sourceReferences: [reference],
        )).single;
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
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        final router = container.read(routerProvider);
        router.go(AppRoutes.folder(folder));
        await tester.pumpAndSettle();
        unawaited(router.push<void>(AppRoutes.editQuestion(id)));
        await tester.pumpAndSettle();
        final finder = find.byKey(const Key('question-importance-slider'));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final slider = tester.widget<Slider>(finder);
        expect(slider.value, inherited ? 5 : 3);
        if (inherited) {
          expect(slider.onChanged, null);
          expect(
            find.text('출처 개념의 중요도를 따릅니다. 개념에서 수정하면 연결된 문제에도 반영됩니다.'),
            findsOneWidget,
          );
          await tester.pageBack();
          await tester.pumpAndSettle();
        } else {
          slider.onChanged!(1);
          await tester.pumpAndSettle();
          expect(find.text('중요도 · 매우 낮음'), findsOneWidget);
          final save = find.byKey(const Key('save-question-button'));
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.pumpAndSettle();
        }
        final saved = (await tester.runAsync(() => questions.getQuestion(id)))!;
        expect(
          saved.importance,
          inherited ? ConceptImportance.veryHigh : ConceptImportance.veryLow,
        );
        expect(saved.difficulty, 3);
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }
}
