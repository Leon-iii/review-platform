import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:review_platform/shared/widgets/unsaved_changes_guard.dart';

import 'support/fake_sync.dart';

const platforms = TargetPlatformVariant({
  TargetPlatform.windows,
  TargetPlatform.android,
});
final confirmation = find.byKey(const Key('unsaved-changes-dialog'));
final saveExit = find.byKey(const Key('unsaved-save-button'));
final discardExit = find.byKey(const Key('unsaved-discard-button'));
final continueEdit = find.byKey(const Key('unsaved-continue-button'));

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<(AppDatabase, GoRouter)> openApp(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.binding.setSurfaceSize(
    defaultTargetPlatform == TargetPlatform.windows
        ? const Size(1100, 1000)
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
  return (db, container.read(routerProvider));
}

void main() {
  for (final action in ['continue', 'discard', 'save']) {
    testWidgets('문제 수정 후 뒤로 가기: $action', (tester) async {
      final (db, navigation) = await openApp(tester);
      final folder = await DriftFolderRepository(db).createFolder(name: '문제');
      final repo = DriftQuestionRepository(db);
      final id = await repo.createQuestion(
        QuestionDraft(
          folderId: folder,
          type: QuestionType.shortAnswer,
          prompt: '기존 문제',
          acceptableAnswers: const ['Cache Hit'],
        ),
      );
      navigation.push(AppRoutes.editQuestion(id));
      await tester.pumpAndSettle();
      final prompt = find.byKey(const Key('question-prompt-field'));
      await tester.enterText(prompt, '변경한 문제');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(confirmation, findsOneWidget);
      await tapVisible(
        tester,
        action == 'save'
            ? saveExit
            : action == 'discard'
            ? discardExit
            : continueEdit,
      );
      if (action == 'continue') {
        expect(prompt, findsOneWidget);
        expect(tester.widget<TextFormField>(prompt).controller!.text, '변경한 문제');
      } else {
        expect(prompt, findsNothing);
      }
      expect(
        (await repo.getQuestion(id))!.prompt,
        action == 'save' ? '변경한 문제' : '기존 문제',
      );
      expect(confirmation, findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('문제 설정 변경도 확인하며 되돌리면 확인 없이 나가고 입력 오류는 유지한다', (tester) async {
    final (db, navigation) = await openApp(tester);
    final folder = await DriftFolderRepository(db).createFolder(name: '설정');
    final repo = DriftQuestionRepository(db);
    final id = await repo.createQuestion(
      QuestionDraft(
        folderId: folder,
        type: QuestionType.shortAnswer,
        prompt: '기존 문제',
        acceptableAnswers: const ['Cache Hit'],
      ),
    );
    navigation.push(AppRoutes.editQuestion(id));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('short-answer-case-sensitive-switch'));
    await tapVisible(tester, toggle);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(confirmation, findsOneWidget);
    await tapVisible(tester, continueEdit);
    await tapVisible(tester, toggle);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(confirmation, findsNothing);
    expect(find.byKey(const Key('question-prompt-field')), findsNothing);
    navigation.push(AppRoutes.editQuestion(id));
    await tester.pumpAndSettle();
    final prompt = find.byKey(const Key('question-prompt-field'));
    await tester.enterText(prompt, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tapVisible(tester, saveExit);
    expect(prompt, findsOneWidget);
    expect(find.text('문제 내용을 입력해 주세요.'), findsOneWidget);
    expect((await repo.getQuestion(id))!.prompt, '기존 문제');
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  for (final action in ['continue', 'discard', 'save']) {
    testWidgets('개념 수정 후 취소: $action', (tester) async {
      final (db, navigation) = await openApp(tester);
      final folder = await DriftFolderRepository(db).createFolder(name: '개념');
      final repo = DriftSourceRepository(db);
      final source = await repo.createSource(folderId: folder, name: '내 자료');
      final concept = await repo.addConcept(
        sourceId: source.source.id,
        title: '기존 개념',
        content: '기존 내용',
      );
      navigation.push(AppRoutes.documentsForSource(folder, source.source.id));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(Key('concept-menu-${concept.id}')));
      await tapVisible(tester, find.text('수정'));
      final title = find.byKey(const Key('concept-title-field'));
      await tester.enterText(title, '변경한 개념');
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('취소'));
      expect(confirmation, findsOneWidget);
      await tapVisible(
        tester,
        action == 'save'
            ? saveExit
            : action == 'discard'
            ? discardExit
            : continueEdit,
      );
      if (action == 'continue') {
        expect(title, findsOneWidget);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(of: title, matching: find.byType(EditableText)),
              )
              .controller
              .text,
          '변경한 개념',
        );
      } else {
        expect(title, findsNothing);
      }
      final stored = (await repo.getSourceWithConcepts(source.source.id))
          .concepts
          .single;
      expect(stored.title, action == 'save' ? '변경한 개념' : '기존 개념');
      expect(confirmation, findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: platforms);
  }

  testWidgets('개념 중요도 변경은 시스템 뒤로 가기로 확인하며 원복 시 확인하지 않는다', (tester) async {
    final (db, navigation) = await openApp(tester);
    final folder = await DriftFolderRepository(db).createFolder(name: '개념');
    final repo = DriftSourceRepository(db);
    final source = await repo.createSource(folderId: folder, name: '내 자료');
    final concept = await repo.addConcept(
      sourceId: source.source.id,
      title: '기존 개념',
      content: '기존 내용',
    );
    navigation.push(AppRoutes.documentsForSource(folder, source.source.id));
    await tester.pumpAndSettle();
    Future<void> edit() async {
      await tapVisible(tester, find.byKey(Key('concept-menu-${concept.id}')));
      await tapVisible(tester, find.text('수정'));
    }

    await edit();
    final slider = find.byKey(const Key('concept-importance-field'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    tester.widget<Slider>(slider).onChanged!(
      ConceptImportance.high.index.toDouble(),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(confirmation, findsOneWidget);
    await tapVisible(tester, saveExit);
    expect(
      (await repo.getSourceWithConcepts(source.source.id))
          .concepts
          .single
          .importance,
      ConceptImportance.high,
    );
    await edit();
    final title = find.byKey(const Key('concept-title-field'));
    await tester.enterText(title, '변경');
    await tester.enterText(title, '기존 개념');
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('취소'));
    expect(confirmation, findsNothing);
    expect(title, findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: platforms);

  testWidgets('확인 팝업은 중복 생성하지 않고 저장 실패 시 편집을 유지하며 재시도한다', (tester) async {
    final guardKey = GlobalKey<UnsavedChangesGuardState>();
    var calls = 0;
    var fail = true;
    final pending = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => UnsavedChangesGuard(
                    key: guardKey,
                    hasChanges: true,
                    busy: false,
                    onSave: () async {
                      calls++;
                      if (fail) return false;
                      return pending.future;
                    },
                    child: const Scaffold(body: Text('편집 중')),
                  ),
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    unawaited(guardKey.currentState!.requestExit());
    unawaited(guardKey.currentState!.requestExit());
    await tester.pumpAndSettle();
    expect(confirmation, findsOneWidget);
    await tapVisible(tester, saveExit);
    expect(find.text('편집 중'), findsOneWidget);
    expect(calls, 1);
    fail = false;
    unawaited(guardKey.currentState!.requestExit());
    await tester.pumpAndSettle();
    await tester.tap(saveExit);
    await tester.pumpAndSettle();
    unawaited(guardKey.currentState!.requestExit());
    await tester.pumpAndSettle();
    expect(confirmation, findsNothing);
    expect(find.text('편집 중'), findsOneWidget);
    expect(calls, 2);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('편집 중'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
