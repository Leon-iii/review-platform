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
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_sync.dart';

void main() {
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
