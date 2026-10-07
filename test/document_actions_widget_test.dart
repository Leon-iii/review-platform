import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/features/ai_generation/ai_question_generation_view_model.dart';
import 'package:review_platform/features/ai_generation/ai_source_picker.dart';

import 'dart:async';

import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_ai.dart';
import 'support/fake_documents.dart';
import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late DriftSourceRepository sources;
  late StudySourceWithConcepts saved;
  late FakeRemoteAiApi remote;
  late MemorySyncCredentialsStore credentials;
  late FakeConceptRevisionApi documentApi;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    sources = DriftSourceRepository(database);
    remote = FakeRemoteAiApi();
    documentApi = FakeConceptRevisionApi();
    credentials = MemorySyncCredentialsStore(
      configuration: const SyncConfiguration(
        serverUrl: 'http://127.0.0.1:5080',
        accessToken: 'test-token',
      ),
    );
    final folder = await DriftFolderRepository(database)
        .createFolder(name: '자료');
    saved = await sources.saveImport(
      folderId: folder,
      result: DocumentImportResult(
        source: ImportedSource(
          id: 'source-actions',
          fileName: '동작 테스트.pdf',
          contentHash: List.filled(64, 'a').join(),
          pageCount: 10,
          extractionMethod: 'textLayer',
          importedAt: DateTime.utc(2026),
        ),
        concepts: const [
          ImportedConcept(
            title: '첫 개념',
            content: '첫 번째 승인 대상 개념의 상세 내용입니다.',
            pageNumbers: [1, 2],
          ),
          ImportedConcept(
            title: '둘째 개념',
            content: '두 번째 승인 대상 개념의 상세 내용입니다.',
            pageNumbers: [4],
          ),
          ImportedConcept(
            title: '보류 개념',
            content: '문제 생성에 포함하면 안 되는 보류 내용입니다.',
            pageNumbers: [9],
          ),
        ],
      ),
    );
  });
  tearDown(() => database.close());

  Widget app() => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      isWindowsPlatformProvider.overrideWithValue(false),
      syncCredentialsStoreProvider.overrideWithValue(credentials),
      remoteSyncApiProvider.overrideWithValue(FakeRemoteSyncApi()),
      remoteAiApiProvider.overrideWithValue(remote),
      remoteDocumentApiProvider.overrideWithValue(documentApi),
    ],
    child: const ReviewApp(),
  );

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> setImportance(
    WidgetTester tester,
    ConceptImportance importance,
  ) async {
    final finder = find.byKey(const Key('concept-importance-field'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    final rect = tester.getRect(finder);
    await tester.tapAt(
      Offset(
        rect.left + 24 + (rect.width - 48) * importance.index / 4,
        rect.center.dy,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(finder).value, importance.index.toDouble());
  }

  RenderParagraph paragraphFor(WidgetTester tester, Finder text) =>
      tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );

  testWidgets(
    '개념 접기·펼치기와 전체 접기도 본문 높이를 연속적으로 전환한다',
    (tester) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      container
          .read(routerProvider)
          .go(
            AppRoutes.documentsForSource(
              saved.source.folderId,
              saved.source.id,
            ),
          );
      await tester.pumpAndSettle();
      final concept = saved.concepts.first;
      final toggle = find.byKey(Key('concept-toggle-${concept.id}'));
      final body = find.byKey(Key('concept-details-${concept.id}'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      final opened = tester.getSize(body).height;
      expect(opened, greaterThan(0));
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final closing = tester.getSize(body).height;
      expect(closing, greaterThan(0));
      expect(closing, lessThan(opened));
      await tester.tap(toggle);
      await tester.pump();
      expect(tester.getSize(body).height, closeTo(closing, 0.1));
      await tester.pumpAndSettle();
      expect(tester.getSize(body).height, closeTo(opened, 0.1));
      await tester.ensureVisible(
        find.byKey(const Key('collapse-all-concepts')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('collapse-all-concepts')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getSize(body).height, greaterThan(0));
      expect(tester.getSize(body).height, lessThan(opened));
      await tester.pumpAndSettle();
      expect(tester.getSize(body).height, 0);
      expect(find.byKey(Key('concept-content-${concept.id}')), findsNothing);
      await tapVisible(tester, find.byKey(const Key('expand-all-concepts')));
      expect(tester.getSize(body).height, closeTo(opened, 0.1));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    '일반 생성에서 실제 자료를 폴더로 검색하고 변경·해제하며 출처를 연결한다',
    (tester) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      for (final concept in saved.concepts.take(2)) {
        await sources.setConceptApproval(id: concept.id, approved: true);
      }
      final folderRepository = DriftFolderRepository(database);
      final otherFolder = await folderRepository.createFolder(name: '다른 폴더');
      final child = await folderRepository.createFolder(
        name: '하위 폴더',
        parentId: otherFolder,
      );
      final manual = (await sources.createSource(
        folderId: child,
        name: saved.source.fileName,
      )).source;
      final manualConcept = await sources.addConcept(
        sourceId: manual.id,
        title: '다른 자료의 개념',
        content: '수동 자료에 실제로 저장된 개념의 학습 내용입니다.',
      );
      final empty = (await sources.createSource(
        folderId: child,
        name: '빈 자료',
      )).source;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      container
          .read(routerProvider)
          .go('${AppRoutes.aiGenerate}?folderId=${saved.source.folderId}');
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('ai-source-label-field'));
      expect(tester.widget<AiSourcePickerField>(field).locked, false);
      expect(find.text('자료 이름 (선택)'), findsNothing);
      final decorator = tester.widget<InputDecorator>(
        find.descendant(of: field, matching: find.byType(InputDecorator)),
      );
      expect(decorator.decoration.labelText, '자료 이름');
      await tapVisible(
        tester,
        find.byKey(const Key('ai-source-picker-button')),
      );
      await tester.enterText(
        find.byKey(const Key('ai-source-search-field')),
        '없는 자료',
      );
      await tester.pumpAndSettle();
      expect(find.text('검색 결과가 없어요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('ai-source-search-field')),
        '하위 폴더',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('ai-source-option-${saved.source.id}')),
        findsNothing,
      );
      expect(find.text('다른 폴더 / 하위 폴더'), findsNWidgets(2));
      await tapVisible(tester, find.byKey(Key('ai-source-option-${empty.id}')));
      expect(tester.widget<AiSourcePickerField>(field).source!.id, empty.id);
      expect(find.text('문제를 생성하려면 개념을 하나 이상 검토 완료로 표시해 주세요.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('generate-ai-questions-button')),
            )
            .onPressed,
        isNull,
      );
      await tapVisible(
        tester,
        find.byKey(const Key('ai-source-picker-button')),
      );
      await tapVisible(
        tester,
        find.byKey(Key('ai-source-option-${manual.id}')),
      );
      expect(tester.widget<AiSourcePickerField>(field).source!.id, manual.id);
      expect(find.byKey(const Key('ai-source-text-field')), findsNothing);
      expect(find.byKey(Key('ai-concept-${manualConcept.id}')), findsOneWidget);
      expect(
        find.byKey(Key('ai-concept-page-source-${manualConcept.id}')),
        findsNothing,
      );
      await tapVisible(
        tester,
        find.byKey(const Key('ai-source-picker-button')),
      );
      await tapVisible(tester, find.byKey(const Key('close-ai-source-picker')));
      expect(tester.widget<AiSourcePickerField>(field).source!.id, manual.id);
      await tapVisible(
        tester,
        find.byKey(const Key('ai-source-picker-button')),
      );
      await tapVisible(
        tester,
        find.byKey(Key('ai-source-option-${saved.source.id}')),
      );
      expect(
        find.byKey(Key('ai-concept-${saved.concepts.first.id}')),
        findsOneWidget,
      );
      expect(find.byKey(Key('ai-concept-${manualConcept.id}')), findsNothing);
      await tapVisible(tester, find.byKey(const Key('clear-ai-source-button')));
      expect(tester.widget<AiSourcePickerField>(field).source, isNull);
      expect(find.byKey(const Key('ai-source-text-field')), findsOneWidget);
      expect(find.byKey(const Key('ai-source-search-field')), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const Key('ai-source-picker-button')),
      );
      await tapVisible(
        tester,
        find.byKey(Key('ai-source-option-${manual.id}')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('generate-ai-questions-button')),
      );
      expect(remote.lastRequest!.concepts.single.id, manualConcept.id);
      expect(remote.lastRequest!.sourceLabel, manual.fileName);
      expect(remote.lastRequest!.sourceText, isEmpty);
      final questions = (await tester.runAsync(
        () =>
            DriftQuestionRepository(database)
                .watchQuestions(saved.source.folderId)
                .first,
      ))!;
      expect(questions, hasLength(4));
      expect(
        questions.every(
          (question) =>
              question.primaryConceptId == manualConcept.id &&
              question.sourceReferences.single.sourceId == manual.id,
        ),
        true,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  for (final fromConcept in [false, true]) {
    testWidgets(
      '자료 또는 개념에서 시작하면 실제 자료 이름을 자동 입력하고 선택을 잠근다 ($fromConcept)',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final concept = saved.concepts.first;
        await sources.setConceptApproval(id: concept.id, approved: true);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          fromConcept
              ? find.byKey(Key('generate-concept-questions-${concept.id}'))
              : find.byKey(const Key('generate-source-questions-button')),
        );
        final field = find.byKey(const Key('ai-source-label-field'));
        final picker = tester.widget<AiSourcePickerField>(field);
        expect(picker.source!.id, saved.source.id);
        expect(picker.source!.fileName, saved.source.fileName);
        expect(picker.locked, true);
        expect(find.text('자료 이름 (선택)'), findsNothing);
        expect(find.byKey(const Key('ai-source-picker-lock')), findsOneWidget);
        expect(find.byKey(const Key('clear-ai-source-button')), findsNothing);
        final open = find.byKey(const Key('ai-source-picker-button'));
        expect(tester.widget<InkWell>(open).onTap, isNull);
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('ai-source-search-field')), findsNothing);
        expect(find.byKey(Key('ai-concept-${concept.id}')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  for (final scale in [1.0, 1.6]) {
    testWidgets(
      '문제 생성 개념 박스의 독립 스크롤·왼쪽 체크박스·자료 배지를 유지한다 ($scale)',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final first = saved.concepts.first;
        await sources.updateConcept(
          id: first.id,
          title: '기본 명령어 및 지시어 집합의 구성과 기능을 통해 컴퓨터 시스템의 핵심 동작과 세부 구조를 정확하게 이해하기 위한 아주 긴 개념 제목',
          content: first.content,
          importance: ConceptImportance.veryHigh,
        );
        for (final concept in saved.concepts.take(2)) {
          await sources.setConceptApproval(id: concept.id, approved: true);
        }
        for (var index = 0; index < 12; index++) {
          await sources.addConcept(
            sourceId: saved.source.id,
            title: '추가 개념 $index',
            content: '독립 스크롤을 확인하는 직접 작성한 개념 내용입니다.',
          );
        }
        final seed = await sources.getSourceGenerationSeed(saved.source.id);
        final last = seed.concepts.last;
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        final router = container.read(routerProvider);
        router.go(
          AppRoutes.documentsForSource(saved.source.folderId, saved.source.id),
        );
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.byKey(const Key('collapse-all-concepts')),
        );
        Chip chipIn(Finder finder) => tester.widget<Chip>(
          find.descendant(of: finder, matching: find.byType(Chip)),
        );
        final referenceImportance = chipIn(
          find.byKey(Key('concept-importance-${first.id}')),
        );
        final referencePage = chipIn(
          find.byKey(Key('concept-page-source-${first.id}')),
        );
        router.go(
          '${AppRoutes.aiGenerate}?folderId=${saved.source.folderId}&sourceId=${saved.source.id}',
        );
        await tester.pumpAndSettle();
        final header = find.byKey(const Key('ai-concept-list-header'));
        final selectionLabel = find.byKey(
          const Key('ai-concept-selection-label'),
        );
        final selectAll = find.byKey(const Key('ai-select-all-concepts'));
        final deselectAll = find.byKey(const Key('ai-deselect-all-concepts'));
        final headerInline = tester.getSize(header).width >= 300 * scale;
        for (final button in [selectAll, deselectAll]) {
          if (headerInline) {
            expect(
              tester.getCenter(button).dy,
              closeTo(tester.getCenter(selectionLabel).dy, 0.1),
            );
            expect(
              tester.getTopLeft(button).dx,
              greaterThan(tester.getTopRight(selectionLabel).dx),
            );
          } else {
            expect(
              tester.getTopLeft(button).dy,
              greaterThanOrEqualTo(tester.getBottomLeft(selectionLabel).dy),
            );
          }
        }
        if (headerInline) {
          expect(
            tester.getTopRight(deselectAll).dx,
            closeTo(tester.getTopRight(header).dx, 0.1),
          );
        }
        final box = find.byKey(const Key('ai-concept-list-box'));
        final list = find.byKey(const Key('ai-concept-list'));
        await tester.ensureVisible(box);
        await tester.pumpAndSettle();
        expect(tester.getSize(box).height, lessThanOrEqualTo(420));
        final innerScrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final inner = tester.state<ScrollableState>(innerScrollable);
        final outer = tester.state<ScrollableState>(
          find.ancestor(of: box, matching: find.byType(Scrollable)).first,
        );
        expect(inner.position, isNot(same(outer.position)));
        expect(inner.position.maxScrollExtent, greaterThan(0));
        final card = find.byKey(Key('ai-concept-${first.id}'));
        final checkboxTile = find.descendant(
          of: card,
          matching: find.byType(CheckboxListTile),
        );
        expect(
          tester.widget<CheckboxListTile>(checkboxTile).controlAffinity,
          ListTileControlAffinity.leading,
        );
        final checkbox = find.descendant(
          of: card,
          matching: find.byType(Checkbox),
        );
        final title = find.byKey(Key('ai-concept-title-${first.id}'));
        expect(
          tester.getCenter(checkbox).dx,
          lessThan(tester.getTopLeft(title).dx),
        );
        expect(tester.widget<StudyText>(title).maxLines, 1);
        expect(tester.widget<StudyText>(title).overflow, TextOverflow.ellipsis);
        expect(paragraphFor(tester, title).didExceedMaxLines, true);
        expect(find.text(first.content), findsNothing);
        final importance = chipIn(
          find.byKey(Key('ai-concept-importance-${first.id}')),
        );
        final page = chipIn(
          find.byKey(Key('ai-concept-page-source-${first.id}')),
        );
        expect(find.text('매우 높음'), findsOneWidget);
        expect(find.text('중요도 매우 높음'), findsNothing);
        final importanceBadge = find.byKey(
          Key('ai-concept-importance-${first.id}'),
        );
        final pageBadge = find.byKey(Key('ai-concept-page-source-${first.id}'));
        expect(
          tester.getCenter(importanceBadge).dy,
          closeTo(tester.getCenter(title).dy, 0.1),
        );
        expect(
          tester.getCenter(pageBadge).dy,
          closeTo(tester.getCenter(title).dy, 0.1),
        );
        expect(
          tester.getTopLeft(importanceBadge).dx - tester.getTopRight(title).dx,
          closeTo(8, 0.1),
        );
        for (final (actual, reference) in [
          (importance, referenceImportance),
          (page, referencePage),
        ]) {
          expect(actual.backgroundColor, reference.backgroundColor);
          expect(actual.labelStyle, reference.labelStyle);
          expect(actual.shape, reference.shape);
          expect(actual.side, reference.side);
          expect(actual.padding, reference.padding);
        }
        expect(find.text('p.1 - 2'), findsOneWidget);
        expect(find.byKey(Key('ai-concept-${last.id}')), findsNothing);
        final outerOffset = outer.position.pixels;
        await tester.drag(list, const Offset(0, -260));
        await tester.pumpAndSettle();
        expect(inner.position.pixels, greaterThan(0));
        expect(outer.position.pixels, closeTo(outerOffset, 0.1));
        if (defaultTargetPlatform == TargetPlatform.windows) {
          final beforeWheel = inner.position.pixels;
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(list),
              kind: PointerDeviceKind.mouse,
              scrollDelta: const Offset(0, 80),
            ),
          );
          await tester.pumpAndSettle();
          expect(inner.position.pixels, greaterThan(beforeWheel));
          expect(outer.position.pixels, closeTo(outerOffset, 0.1));
        }
        await tester.scrollUntilVisible(
          find.byKey(Key('ai-concept-${last.id}')),
          350,
          scrollable: innerScrollable,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('ai-concept-page-source-${last.id}')),
          findsNothing,
        );
        final scrolledOffset = inner.position.pixels;
        await tapVisible(tester, find.text('선택 해제'));
        expect(
          find.text('학습 개념 · 선택 0/${seed.concepts.length}개'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('generate-ai-questions-button')),
              )
              .onPressed,
          isNull,
        );
        expect(inner.position.pixels, closeTo(scrolledOffset, 0.1));
        await tapVisible(tester, find.text('전체 선택'));
        expect(
          find.text(
            '학습 개념 · 선택 ${seed.concepts.length}/${seed.concepts.length}개',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    '구조화된 개념 선택과 진행률을 표시하고 부분 실패 뒤에도 검토를 유지한다',
    (tester) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      for (final concept in saved.concepts.take(2)) {
        await sources.setConceptApproval(id: concept.id, approved: true);
      }
      remote.gate = Completer<void>();
      remote.progress = const AiGenerationProgress(
        completedConcepts: 0,
        totalConcepts: 2,
        generatedQuestions: 0,
        failedConcepts: 0,
        conceptTitle: '첫째 개념',
      );
      remote.failures = [
        AiConceptGenerationFailure(
          conceptId: saved.concepts[1].id,
          title: '둘째 개념',
          error: '모의 요청 실패',
        ),
      ];
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      container
          .read(routerProvider)
          .go(
            '${AppRoutes.aiGenerate}?folderId=${saved.source.folderId}&sourceId=${saved.source.id}',
          );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-source-text-field')), findsNothing);
      expect(find.text('학습 개념 · 선택 2/2개'), findsOneWidget);
      final generate = find.byKey(const Key('generate-ai-questions-button'));
      await tapVisible(tester, find.text('선택 해제'));
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      await tapVisible(tester, find.text('전체 선택'));
      final second = find.descendant(
        of: find.byKey(Key('ai-concept-${saved.concepts[1].id}')),
        matching: find.byType(CheckboxListTile),
      );
      await tapVisible(tester, second);
      expect(find.text('학습 개념 · 선택 1/2개'), findsOneWidget);
      await tapVisible(tester, second);
      await tester.ensureVisible(generate);
      await tester.pumpAndSettle();
      await tester.tap(generate);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        remote.lastRequest!.concepts.map((concept) => concept.id),
        saved.concepts.take(2).map((concept) => concept.id),
      );
      expect(remote.lastRequest!.sourceText, isEmpty);
      expect(find.text('개념 1/2 - "첫째 개념"'), findsOneWidget);
      expect(find.text('성공 0건 · 실패 0건'), findsOneWidget);
      expect(find.text('총 0문항 생성'), findsOneWidget);
      remote.emitProgress(
        const AiGenerationProgress(
          completedConcepts: 1,
          totalConcepts: 2,
          generatedQuestions: 4,
          failedConcepts: 0,
          conceptTitle: '둘째 개념',
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('ai-generation-progress-bar')),
            )
            .value,
        0.5,
      );
      expect(find.text('개념 2/2 - "둘째 개념"'), findsOneWidget);
      expect(find.text('성공 1건 · 실패 0건'), findsOneWidget);
      expect(find.text('총 4문항 생성'), findsOneWidget);
      remote.emitProgress(
        const AiGenerationProgress(
          completedConcepts: 2,
          totalConcepts: 2,
          generatedQuestions: 4,
          failedConcepts: 1,
        ),
      );
      await tester.pump();
      expect(find.text('개념 2/2 - "둘째 개념"'), findsOneWidget);
      expect(find.text('성공 1건 · 실패 1건'), findsOneWidget);
      expect(find.text('총 4문항 생성'), findsOneWidget);
      final first = find.byKey(const Key('ai-generation-concept-progress'));
      final secondLine = find.byKey(const Key('ai-generation-concept-counts'));
      final third = find.byKey(const Key('ai-generation-question-count'));
      expect(
        tester.getTopLeft(first).dy,
        lessThan(tester.getTopLeft(secondLine).dy),
      );
      expect(
        tester.getTopLeft(secondLine).dy,
        lessThan(tester.getTopLeft(third).dy),
      );
      remote.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('둘째 개념: 모의 요청 실패'), findsOneWidget);
      expect(find.text('생성된 문제 4개'), findsOneWidget);
      expect(
        container
            .read(aiQuestionGenerationControllerProvider(saved.source.folderId))
            .requireValue!
            .failures,
        hasLength(1),
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  for (final compact in [false, true]) {
    testWidgets(
      '개념 배지로 검토 상태와 중요도를 편집한다 (${compact ? '접힘' : '펼침'})',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        final concept = saved.concepts.first;
        if (compact) {
          await tapVisible(
            tester,
            find.byKey(Key('concept-toggle-${concept.id}')),
          );
        }
        final content = find.byKey(Key('concept-content-${concept.id}'));
        final status = find.byKey(Key('concept-status-${concept.id}'));
        final importance = find.byKey(Key('concept-importance-${concept.id}'));
        expect(content, compact ? findsNothing : findsOneWidget);
        await tapVisible(tester, status);
        expect(
          find.descendant(of: status, matching: find.text('검토 완료')),
          findsOneWidget,
        );
        expect(content, compact ? findsNothing : findsOneWidget);
        if (!compact) {
          expect(
            tester
                .widget<Switch>(
                  find.byKey(Key('concept-approval-${concept.id}')),
                )
                .value,
            true,
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(Key('generate-concept-questions-${concept.id}')),
                )
                .onPressed,
            isNotNull,
          );
        }
        await tapVisible(tester, status);
        expect(
          find.descendant(of: status, matching: find.text('검토 필요')),
          findsOneWidget,
        );
        await tapVisible(tester, importance);
        expect(
          find.byKey(const Key('concept-importance-dialog')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('concept-title-field')), findsNothing);
        expect(
          tester
              .widget<Slider>(find.byKey(const Key('concept-importance-field')))
              .value,
          2,
        );
        await setImportance(tester, ConceptImportance.veryHigh);
        await tapVisible(
          tester,
          find.byKey(const Key('cancel-concept-importance-button')),
        );
        var stored = (await tester.runAsync(
          () => sources.getSourceWithConcepts(saved.source.id),
        ))!.concepts.first;
        expect(stored.importance, ConceptImportance.medium);
        await tapVisible(tester, importance);
        for (final value in ConceptImportance.values) {
          await setImportance(tester, value);
          expect(
            find.byKey(const Key('concept-importance-dialog')),
            findsOneWidget,
          );
        }
        await tapVisible(
          tester,
          find.byKey(const Key('save-concept-importance-button')),
        );
        expect(
          find.byKey(const Key('concept-importance-dialog')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: importance,
            matching: find.text(compact ? '매우 높음' : '중요도 매우 높음'),
          ),
          findsOneWidget,
        );
        expect(content, compact ? findsNothing : findsOneWidget);
        stored = (await tester.runAsync(
          () => sources.getSourceWithConcepts(saved.source.id),
        ))!.concepts.first;
        expect(stored.importance, ConceptImportance.veryHigh);
        expect(stored.title, concept.title);
        expect(stored.content, concept.content);
        expect(stored.status, ConceptStatus.held);
        expect(stored.pageNumbers, concept.pageNumbers);
        container
            .read(routerProvider)
            .go(AppRoutes.folder(saved.source.folderId));
        await tester.pumpAndSettle();
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: importance, matching: find.text('중요도 매우 높음')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    '개념 배지·수정 대상·문제 출처의 연속 페이지를 동일한 범위로 표시한다',
    (tester) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 1000),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final concept = saved.concepts.first;
      await tester.runAsync(
        () => DriftQuestionRepository(database).createQuestions(
          [
            QuestionDraft(
              folderId: saved.source.folderId,
              type: QuestionType.shortAnswer,
              prompt: '출처 범위 테스트',
              acceptableAnswers: const ['정답'],
            ),
          ],
          sourceReferences: [
            QuestionSourceDraft(
              sourceId: saved.source.id,
              conceptId: concept.id,
              pageNumbers: concept.pageNumbers,
            ),
          ],
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      final router = container.read(routerProvider);
      router.go(
        AppRoutes.documentsForSource(saved.source.folderId, saved.source.id),
      );
      await tester.pumpAndSettle();
      void expectPages() {
        expect(
          find.descendant(
            of: find.byKey(Key('concept-page-source-${concept.id}')),
            matching: find.text('p.1 - 2'),
          ),
          findsOneWidget,
        );
        expect(find.byTooltip('p.1 - 2'), findsOneWidget);
      }

      expectPages();
      await tapVisible(tester, find.byKey(Key('concept-toggle-${concept.id}')));
      expectPages();
      await tapVisible(
        tester,
        find.byKey(const Key('request-concept-revision-button')),
      );
      expect(
        find.widgetWithText(CheckboxListTile, '검토 필요 · 중요도 보통 · p.1 - 2'),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('취소'));
      router.go(AppRoutes.folder(saved.source.folderId));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('출처 범위 테스트'));
      expect(find.text('출처: 동작 테스트.pdf · p.1 - 2 · 첫 개념'), findsOneWidget);
      final stored = await tester.runAsync(
        () => sources.getSourceWithConcepts(saved.source.id),
      );
      expect(stored!.concepts.first.pageNumbers, [1, 2]);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    '개념 화면의 접근성: 툴팁 전환·접기 및 배지 조작에도 안전한 스크롤 구조를 유지한다',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.binding.setSurfaceSize(const Size(1100, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        final concept = saved.concepts.first;
        final scroll = find.byKey(const Key('concept-review-scroll-view'));
        expect(tester.widget(scroll), isA<SingleChildScrollView>());
        // Native Windows AXTree errors cannot be caught by takeException().
        // Guard the actual cause: ListView's two-pane viewport + tooltip grafts.
        expect(
          find.descendant(of: scroll, matching: find.byType(Viewport)),
          findsNothing,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(4, 4));
        addTearDown(mouse.removePointer);
        Future<void> hover(String key) async {
          final finder = find.byKey(Key(key));
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          final originalId = tester.getSemantics(finder).id;
          await mouse.moveTo(tester.getCenter(finder));
          await tester.pump(const Duration(milliseconds: 700));
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            tester.getSemantics(finder).id,
            originalId,
            reason: '$key 접근성 노드',
          );
          expect(tester.takeException(), isNull, reason: '$key 호버');
        }

        for (final expanded in [true, false, true]) {
          final currentlyExpanded = find
              .byKey(Key('concept-content-${concept.id}'))
              .evaluate()
              .isNotEmpty;
          if (expanded != currentlyExpanded) {
            await tapVisible(
              tester,
              find.byKey(Key('concept-toggle-${concept.id}')),
            );
          }
          for (final key in [
            'concept-toggle-${concept.id}',
            'concept-status-${concept.id}',
            'concept-importance-${concept.id}',
            'concept-page-source-${concept.id}',
            'concept-menu-${concept.id}',
            if (expanded) ...[
              'concept-approval-${concept.id}',
              'request-concept-revision-${concept.id}',
              'generate-concept-questions-${concept.id}',
            ],
          ]) {
            await hover(key);
            if (key == 'concept-importance-${concept.id}') {
              expect(find.text('중요도 변경', findRichText: true), findsOneWidget);
            }
            if (key == 'concept-menu-${concept.id}') {
              expect(find.text('개념 메뉴', findRichText: true), findsOneWidget);
            }
          }
        }
        await hover('concept-toggle-${concept.id}');
        await tapVisible(
          tester,
          find.byKey(Key('concept-status-${concept.id}')),
        );
        await hover('generate-concept-questions-${concept.id}');
        await hover('concept-importance-${concept.id}');
        await tapVisible(
          tester,
          find.byKey(Key('concept-importance-${concept.id}')),
        );
        await tapVisible(
          tester,
          find.byKey(const Key('cancel-concept-importance-button')),
        );
        await hover('concept-menu-${concept.id}');
        await tapVisible(tester, find.byKey(Key('concept-menu-${concept.id}')));
        expect(find.text('수정'), findsOneWidget);
        expect(find.text('삭제'), findsOneWidget);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        for (final key in ['collapse-all-concepts', 'expand-all-concepts']) {
          await tapVisible(tester, find.byKey(Key(key)));
          await hover('concept-toggle-${concept.id}');
        }
        for (final key in [
          'concept-toggle-${concept.id}',
          'concept-status-${concept.id}',
          'concept-importance-${concept.id}',
          'concept-menu-${concept.id}',
        ]) {
          final finder = find.byKey(Key(key));
          final button = key == 'concept-menu-${concept.id}'
              ? find.descendant(of: finder, matching: find.byType(IconButton))
              : finder;
          final data = tester.getSemantics(button).getSemanticsData();
          expect(data.hasAction(SemanticsAction.tap), isTrue, reason: key);
        }
        // Exercise screen-reader activation, not just pointer gestures.
        final status = find.byKey(Key('concept-status-${concept.id}'));
        final statusNode = tester.getSemantics(status);
        statusNode.owner!.performAction(statusNode.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: status, matching: find.text('검토 필요')),
          findsOneWidget,
        );
        final importanceNode = tester.getSemantics(
          find.byKey(Key('concept-importance-${concept.id}')),
        );
        importanceNode.owner!.performAction(
          importanceNode.id,
          SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('concept-importance-dialog')),
          findsOneWidget,
        );
        await tapVisible(
          tester,
          find.byKey(const Key('cancel-concept-importance-button')),
        );
        await hover('concept-toggle-${saved.concepts[1].id}');
        await hover('concept-toggle-${concept.id}');
        container.read(routerProvider).go(AppRoutes.home);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'PC 개념 제목과 본문만 마우스로 선택·복사하고 모바일은 기존 동작을 유지한다',
    (tester) async {
      final desktop = defaultTargetPlatform == TargetPlatform.windows;
      await tester.binding.setSurfaceSize(
        desktop ? const Size(1100, 1000) : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      container
          .read(routerProvider)
          .go(
            AppRoutes.documentsForSource(
              saved.source.folderId,
              saved.source.id,
            ),
          );
      await tester.pumpAndSettle();
      final concept = saved.concepts.first;
      final title = find.byKey(Key('concept-title-${concept.id}'));
      final content = find.byKey(Key('concept-content-${concept.id}'));
      for (final text in [title, content]) {
        expect(
          find.ancestor(of: text, matching: find.byType(SelectionArea)),
          desktop ? findsOneWidget : findsNothing,
        );
      }
      expect(
        find.ancestor(
          of: find.byKey(Key('concept-approval-${concept.id}')),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );
      if (desktop) {
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': clipboard};
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        for (final text in [content, title]) {
          await tester.ensureVisible(text);
          await tester.pumpAndSettle();
          final paragraph = paragraphFor(tester, text);
          final value = tester.widget<StudyText>(text).data;
          final start =
              paragraph.localToGlobal(
                paragraph.getOffsetForCaret(
                  const TextPosition(offset: 0),
                  Rect.zero,
                ),
              ) +
              const Offset(1, 8);
          final end =
              paragraph.localToGlobal(
                paragraph.getOffsetForCaret(
                  TextPosition(offset: value.length - 1),
                  Rect.zero,
                ),
              ) +
              const Offset(0, 8);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: start);
          await mouse.down(start);
          await mouse.moveTo(end);
          await mouse.up();
          await tester.pumpAndSettle();
          clipboard = null;
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expect(clipboard, isNotNull);
          expect(clipboard!.length, greaterThan(1));
          expect(value, contains(clipboard!));
          expect(
            content,
            findsOneWidget,
          ); // Title drag must not collapse the card.
          await mouse.removePointer();
        }
      }
      await tapVisible(tester, find.byKey(Key('concept-toggle-${concept.id}')));
      expect(content, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final mode in ['independent', 'group', 'cancel']) {
    testWidgets(
      'AI 추가·삭제 확인, 기본 선택과 연결 그룹: $mode',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final first = saved.concepts.first;
        final second = saved.concepts[1];
        await sources.setConceptApproval(id: first.id, approved: true);
        final group = mode == 'group' ? 'replace' : '';
        documentApi.changes = [
          ConceptRevision(
            id: first.id,
            title: first.title,
            content: '${first.content} 수정',
            pageNumbers: first.pageNumbers,
            importance: first.importance,
          ),
          ConceptRevision(
            id: 'new',
            title: '새 개념',
            content: '추가 요청한 개념',
            pageNumbers: const [],
            importance: ConceptImportance.high,
            kind: ConceptChangeKind.add,
            groupId: group,
            reason: '요청한 추가',
          ),
          ConceptRevision(
            id: second.id,
            title: '',
            content: '',
            pageNumbers: const [],
            importance: ConceptImportance.medium,
            kind: ConceptChangeKind.delete,
            groupId: group,
            reason: '요청한 삭제',
          ),
        ];
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.byKey(const Key('request-concept-revision-button')),
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('allow-concept-additions')),
              )
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const Key('allow-concept-deletions')),
              )
              .value,
          isFalse,
        );
        await tester.enterText(
          find.byKey(const Key('concept-revision-instruction-field')),
          '개념을 수정·추가·삭제해 줘.',
        );
        await tapVisible(
          tester,
          find.byKey(const Key('allow-concept-additions')),
        );
        await tapVisible(
          tester,
          find.byKey(const Key('allow-concept-deletions')),
        );
        for (final id in [first.id, second.id]) {
          await tapVisible(
            tester,
            find.byKey(Key('concept-revision-target-$id')),
          );
        }
        await tapVisible(
          tester,
          find.byKey(const Key('send-concept-revision-button')),
        );
        expect(documentApi.lastAllowAdditions, isTrue);
        expect(documentApi.lastAllowDeletions, isTrue);
        expect(find.text('수정 1개 · 추가 1개 · 삭제 1개'), findsOneWidget);
        bool selected(int i) => tester
            .widget<CheckboxListTile>(
              find.byKey(Key('select-concept-change-$i')),
            )
            .value!;
        Future<void> reveal(int index, double delta) async {
          await tester.scrollUntilVisible(
            find.byKey(Key('select-concept-change-$index')),
            delta,
            scrollable: find
                .descendant(
                  of: find.byKey(const Key('concept-changes-list')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }

        await reveal(2, 120);
        expect(selected(2), isFalse);
        await reveal(1, -120);
        expect(selected(1), mode != 'group');
        final before = await sources.getSourceWithConcepts(saved.source.id);
        expect(before.concepts, hasLength(3));
        expect(before.concepts.first.content, first.content);
        if (mode == 'group') {
          await tapVisible(
            tester,
            find.byKey(const Key('select-concept-change-1')),
          );
          await reveal(2, 120);
          expect(selected(2), isTrue);
          await reveal(0, -120);
          await tapVisible(
            tester,
            find.byKey(const Key('select-concept-change-0')),
          );
        }
        await tapVisible(
          tester,
          find.byKey(
            Key(
              mode == 'cancel'
                  ? 'cancel-concept-revisions-button'
                  : 'apply-concept-revisions-button',
            ),
          ),
        );
        final after = await sources.getSourceWithConcepts(saved.source.id);
        if (mode == 'cancel') {
          expect(
            after.concepts.map((item) => item.id),
            before.concepts.map((item) => item.id),
          );
          expect(after.concepts.first.content, first.content);
        } else {
          final added = after.concepts.singleWhere(
            (item) => item.title == '새 개념',
          );
          expect(added.status, ConceptStatus.held);
          expect(added.pageNumbers, isEmpty);
          expect(added.id, isNot('new'));
          expect(
            after.concepts.any((item) => item.id == second.id),
            mode != 'group',
          );
          final updated = after.concepts.singleWhere(
            (item) => item.id == first.id,
          );
          expect(
            updated.content,
            mode == 'group' ? first.content : '${first.content} 수정',
          );
          expect(
            updated.status,
            mode == 'group' ? ConceptStatus.approved : ConceptStatus.held,
          );
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets('빈 자료에서 기존 대상 없이 AI 개념을 추가한다', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final material = await sources.createSource(
      folderId: saved.source.folderId,
      name: '빈 자료',
    );
    documentApi.changes = const [
      ConceptRevision(
        id: 'new',
        title: '새 개념',
        content: '새 내용',
        pageNumbers: [],
        importance: ConceptImportance.high,
        kind: ConceptChangeKind.add,
      ),
    ];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    container
        .read(routerProvider)
        .go(
          AppRoutes.documentsForSource(
            material.source.folderId,
            material.source.id,
          ),
        );
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const Key('request-concept-revision-button')),
    );
    await tester.enterText(
      find.byKey(const Key('concept-revision-instruction-field')),
      '새 개념을 추가해 줘.',
    );
    await tapVisible(tester, find.byKey(const Key('allow-concept-additions')));
    await tapVisible(
      tester,
      find.byKey(const Key('send-concept-revision-button')),
    );
    expect(documentApi.lastConcepts, isEmpty);
    await tapVisible(
      tester,
      find.byKey(const Key('apply-and-review-concept-revisions-button')),
    );
    final created = (await sources.getSourceWithConcepts(material.source.id))
        .concepts
        .single;
    expect(created.status, ConceptStatus.approved);
    expect(find.byKey(Key('concept-page-source-${created.id}')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.6]) {
    testWidgets(
      '개념별/전체 접기와 배지 위치, 접힌 개념 편집 상태를 유지한다 ($scale)',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final first = saved.concepts.first;
        await sources.updateConcept(
          id: first.id,
          title:
              '기본 명령어/지시어 집합의 구성 및 기능과 컴퓨터 시스템의 구조 및 핵심 동작을 정확하게 이해하기 위한 학습 개념',
          content: first.content,
          importance: ConceptImportance.veryLow,
        );
        await sources.setConceptApproval(id: first.id, approved: true);
        final second = saved.concepts[1];
        await sources.updateConcept(
          id: second.id,
          title: '가',
          content: second.content,
          importance: second.importance,
        );
        await sources.addConcept(
          sourceId: saved.source.id,
          title: '가',
          content: '직접 쓴 개념의 내용',
          importance: ConceptImportance.low,
        );
        final manual = (await sources.getSourceWithConcepts(saved.source.id))
            .concepts
            .last;
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        final title = find.byKey(Key('concept-title-${first.id}'));
        final status = find.byKey(Key('concept-status-${first.id}'));
        final importance = find.byKey(Key('concept-importance-${first.id}'));
        final page = find.byKey(Key('concept-page-source-${first.id}'));
        for (final badge in [status, importance, page]) {
          expect(
            tester.getTopLeft(badge).dy,
            greaterThan(tester.getBottomLeft(title).dy),
          );
        }
        final expandAll = find.byKey(const Key('expand-all-concepts'));
        final collapseAll = find.byKey(const Key('collapse-all-concepts'));
        final expansionActions = find.byKey(
          const Key('concept-expansion-actions'),
        );
        expect(
          tester.widget<Align>(expansionActions).alignment,
          Alignment.centerLeft,
        );
        expect(
          tester.getTopLeft(expandAll).dx,
          closeTo(tester.getTopLeft(expansionActions).dx, 0.1),
        );
        expect(tester.widget<TextButton>(expandAll).onPressed, isNull);
        await tapVisible(tester, collapseAll);
        expect(tester.widget<TextButton>(collapseAll).onPressed, isNull);
        expect(find.byKey(Key('concept-content-${first.id}')), findsNothing);
        expect(find.byKey(Key('concept-actions-${first.id}')), findsNothing);
        expect(find.text('중요도 매우 낮음'), findsNothing);
        expect(
          find.descendant(of: importance, matching: find.text('매우 낮음')),
          findsOneWidget,
        );
        expect(tester.widget<StudyText>(title).maxLines, 1);
        expect(tester.widget<StudyText>(title).overflow, TextOverflow.ellipsis);
        expect(paragraphFor(tester, title).didExceedMaxLines, isTrue);
        final shortTitle = find.byKey(Key('concept-title-${second.id}'));
        final shortParagraph = paragraphFor(tester, shortTitle);
        // 48dp interactive badges/menu reserve space before the title. Its
        // ellipsis is allowed only when the actual remaining width needs it.
        final shortTitleFits =
            tester.getSize(shortTitle).width >=
            shortParagraph.getMaxIntrinsicWidth(double.infinity) - 0.1;
        expect(shortParagraph.didExceedMaxLines, !shortTitleFits);
        if (shortTitleFits) {
          expect(
            tester.getSize(shortTitle).width,
            closeTo(shortParagraph.getMaxIntrinsicWidth(double.infinity), 0.1),
          );
        }
        final inlineBadges = defaultTargetPlatform == TargetPlatform.windows;
        if (inlineBadges) {
          expect(
            tester
                    .getTopLeft(find.byKey(Key('concept-status-${second.id}')))
                    .dx -
                tester.getTopRight(shortTitle).dx,
            closeTo(8, 0.1),
          );
          final manualTitle = find.byKey(Key('concept-title-${manual.id}'));
          final manualParagraph = paragraphFor(tester, manualTitle);
          final manualTitleFits =
              tester.getSize(manualTitle).width >=
              manualParagraph.getMaxIntrinsicWidth(double.infinity) - 0.1;
          expect(manualParagraph.didExceedMaxLines, !manualTitleFits);
          if (manualTitleFits) {
            expect(
              tester.getSize(manualTitle).width,
              closeTo(
                manualParagraph.getMaxIntrinsicWidth(double.infinity),
                0.1,
              ),
            );
          }
          expect(
            tester
                    .getTopLeft(find.byKey(Key('concept-status-${manual.id}')))
                    .dx -
                tester.getTopRight(manualTitle).dx,
            closeTo(8, 0.1),
          );
          expect(
            tester.getTopLeft(status).dx - tester.getTopRight(title).dx,
            closeTo(8, 0.1),
          );
          expect(
            tester.getTopRight(title).dx,
            lessThan(tester.getTopLeft(status).dx),
          );
          expect(
            tester.getTopRight(status).dx,
            lessThan(tester.getTopLeft(importance).dx),
          );
          expect(
            tester.getTopRight(importance).dx,
            lessThan(tester.getTopLeft(page).dx),
          );
          for (final badge in [status, importance, page]) {
            expect(
              tester.getCenter(badge).dy,
              closeTo(tester.getCenter(title).dy, 4),
            );
          }
        } else {
          for (final badge in [status, importance, page]) {
            expect(
              tester.getTopLeft(badge).dy,
              greaterThan(tester.getBottomLeft(title).dy),
            );
          }
          final chipHeights = [
            for (final badge in [status, importance, page])
              tester
                  .getSize(
                    find.descendant(of: badge, matching: find.byType(Chip)),
                  )
                  .height,
          ];
          expect(chipHeights.toSet().length, 1);
        }
        expect(
          find.byKey(Key('concept-page-source-${manual.id}')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        final toggle = find.byKey(Key('concept-toggle-${first.id}'));
        await tapVisible(tester, toggle);
        expect(find.byKey(Key('concept-content-${first.id}')), findsOneWidget);
        expect(find.text('중요도 매우 낮음'), findsOneWidget);
        expect(
          find.byKey(Key('concept-content-${saved.concepts[1].id}')),
          findsNothing,
        );
        await tapVisible(
          tester,
          find.byKey(Key('concept-approval-${first.id}')),
        );
        expect(find.byKey(Key('concept-content-${first.id}')), findsOneWidget);
        expect(
          find.byKey(Key('concept-content-${saved.concepts[1].id}')),
          findsNothing,
        );
        await tapVisible(tester, toggle);
        await tapVisible(tester, find.byKey(Key('concept-menu-${first.id}')));
        await tapVisible(tester, find.text('수정'));
        for (final level in ConceptImportance.values) {
          await setImportance(tester, level);
          expect(
            tester
                .widget<Text>(find.byKey(const Key('concept-importance-label')))
                .data,
            level.label,
          );
        }
        await tapVisible(tester, find.byKey(const Key('save-concept-button')));
        expect(find.byKey(Key('concept-content-${first.id}')), findsNothing);
        expect(
          find.descendant(of: importance, matching: find.text('매우 높음')),
          findsOneWidget,
        );
        final stored = (await sources.getSourceWithConcepts(saved.source.id))
            .concepts
            .first;
        expect(stored.importance, ConceptImportance.veryHigh);
        expect(stored.status, ConceptStatus.held);
        expect(stored.pageNumbers, first.pageNumbers);
        await tapVisible(tester, expandAll);
        for (final concept in (await sources.getSourceWithConcepts(
          saved.source.id,
        )).concepts) {
          expect(
            find.byKey(Key('concept-content-${concept.id}')),
            findsOneWidget,
          );
        }
        expect(tester.widget<TextButton>(expandAll).onPressed, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'PDF와 개념별 버튼 순서 및 승인 토글이 문제 생성과 출처에 연결된다',
    (tester) async {
      final wide = defaultTargetPlatform == TargetPlatform.windows;
      await tester.binding.setSurfaceSize(
        wide ? const Size(1100, 1000) : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      container
          .read(routerProvider)
          .go(
            AppRoutes.documentsForSource(
              saved.source.folderId,
              saved.source.id,
            ),
          );
      await tester.pumpAndSettle();
      final sourceGenerate = find.byKey(
        const Key('generate-source-questions-button'),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('document-title'))).data,
        saved.source.fileName,
      );
      final sourceRevise = find.byKey(
        const Key('request-concept-revision-button'),
      );
      expect(tester.widget<FilledButton>(sourceGenerate).onPressed, isNull);
      if (wide) {
        expect(
          tester.getCenter(sourceGenerate).dx,
          greaterThan(tester.getCenter(sourceRevise).dx),
        );
        expect(
          tester.getCenter(sourceGenerate).dy,
          closeTo(tester.getCenter(sourceRevise).dy, 1),
        );
      } else {
        expect(
          tester.getTopLeft(sourceGenerate).dx,
          tester.getTopLeft(sourceRevise).dx,
        );
        expect(
          tester.getTopLeft(sourceGenerate).dy,
          greaterThan(tester.getBottomLeft(sourceRevise).dy),
        );
      }
      final sourceActions = find.byKey(const Key('source-actions'));
      final sourceAdd = find.byKey(const Key('add-concept-button'));
      final badgeTheme = Theme.of(tester.element(sourceAdd));
      // Outlined actions show the card underneath their transparent fills.
      for (final buttonFinder in [sourceAdd, sourceRevise]) {
        final button = tester.widget<OutlinedButton>(buttonFinder);
        expect(
          button
              .defaultStyleOf(tester.element(buttonFinder))
              .backgroundColor!
              .resolve({}),
          Colors.transparent,
        );
      }
      expect(
        tester.getSize(sourceGenerate).width,
        closeTo(tester.getSize(sourceRevise).width, 1),
      );
      expect(
        tester.getTopLeft(sourceAdd).dx,
        closeTo(tester.getTopLeft(sourceActions).dx, 1),
      );
      expect(
        tester.getSize(sourceAdd).width,
        closeTo(tester.getSize(sourceRevise).width, 1),
      );
      if (wide) {
        expect(
          tester.getTopLeft(sourceRevise).dx,
          greaterThan(tester.getTopRight(sourceAdd).dx),
        );
      } else {
        expect(
          tester.getTopLeft(sourceRevise).dx,
          tester.getTopLeft(sourceAdd).dx,
        );
        expect(
          tester.getTopLeft(sourceRevise).dy,
          greaterThan(tester.getBottomLeft(sourceAdd).dy),
        );
      }
      expect(
        tester.getTopRight(sourceGenerate).dx,
        closeTo(tester.getTopRight(sourceActions).dx, 1),
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('이 개념으로 문제 생성'), findsNWidgets(3));
      for (final concept in saved.concepts) {
        expect(
          find.byKey(Key('concept-actions-divider-${concept.id}')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Switch>(find.byKey(Key('concept-approval-${concept.id}')))
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(Key('generate-concept-questions-${concept.id}')),
              )
              .onPressed,
          isNull,
        );
        final actions = find.byKey(Key('concept-actions-${concept.id}'));
        final divider = find.byKey(
          Key('concept-actions-divider-${concept.id}'),
        );
        final generation = find.byKey(
          Key('generate-concept-questions-${concept.id}'),
        );
        expect(
          tester.getSize(actions).width,
          closeTo(tester.getSize(divider).width, 1),
        );
        expect(
          tester.getTopRight(generation).dx,
          closeTo(tester.getTopRight(divider).dx, 1),
        );
        if (!wide) {
          final revision = find.byKey(
            Key('request-concept-revision-${concept.id}'),
          );
          expect(
            tester.getSize(revision).width,
            closeTo(tester.getSize(divider).width, 1),
          );
          expect(
            tester.getSize(generation).width,
            closeTo(tester.getSize(divider).width, 1),
          );
          expect(
            tester.getTopLeft(generation).dy,
            greaterThan(tester.getBottomLeft(revision).dy),
          );
        }
      }
      final first = saved.concepts[0];
      void expectMatchingBadges() {
        final chips = [
          for (final prefix in [
            'concept-status',
            'concept-importance',
            'concept-page-source',
          ])
            find.descendant(
              of: find.byKey(Key('$prefix-${first.id}')),
              matching: find.byType(Chip),
            ),
        ];
        final reference = tester.widget<Chip>(chips[1]);
        expect(reference.backgroundColor, badgeTheme.cardTheme.color);
        expect(
          tester.widget<Chip>(chips[2]).backgroundColor,
          badgeTheme.colorScheme.surfaceContainerHighest,
        );
        final approved = tester
            .widget<Switch>(find.byKey(Key('concept-approval-${first.id}')))
            .value;
        final expectedSides = [
          approved ? reference.side : BorderSide.none,
          reference.side,
          BorderSide.none,
        ];
        expect(reference.side!.width, 1);
        expect(reference.side!.color, badgeTheme.colorScheme.outlineVariant);
        for (var index = 0; index < chips.length; index++) {
          final finder = chips[index];
          final chip = tester.widget<Chip>(finder);
          expect(chip.shape, reference.shape);
          expect(
            (chip.shape! as RoundedRectangleBorder).borderRadius,
            BorderRadius.circular(8),
          );
          expect(chip.side, expectedSides[index]);
          expect(chip.materialTapTargetSize, reference.materialTapTargetSize);
          expect(chip.padding, reference.padding);
          expect(chip.labelPadding, reference.labelPadding);
          expect(chip.labelStyle!.fontSize, reference.labelStyle!.fontSize);
          expect(
            tester.getSize(finder).height,
            closeTo(tester.getSize(chips[1]).height, 0.01),
          );
        }
      }

      expectMatchingBadges();
      expect(
        tester
            .widget<Chip>(
              find.descendant(
                of: find.byKey(Key('concept-status-${first.id}')),
                matching: find.byType(Chip),
              ),
            )
            .backgroundColor,
        badgeTheme.colorScheme.surfaceContainerHighest,
      );
      final firstApproval = find.byKey(Key('concept-approval-${first.id}'));
      final firstGenerate = find.byKey(
        Key('generate-concept-questions-${first.id}'),
      );
      final firstRevise = find.byKey(
        Key('request-concept-revision-${first.id}'),
      );
      await tapVisible(tester, firstApproval);
      expectMatchingBadges();
      expect(
        tester
            .widget<Chip>(
              find.descendant(
                of: find.byKey(Key('concept-status-${first.id}')),
                matching: find.byType(Chip),
              ),
            )
            .backgroundColor,
        badgeTheme.cardTheme.color,
      );
      expect(tester.widget<Switch>(firstApproval).value, isTrue);
      expect(tester.widget<FilledButton>(firstGenerate).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(sourceGenerate).onPressed, isNotNull);
      if (wide) {
        expect(
          tester.getTopLeft(firstRevise).dx,
          greaterThan(tester.getTopRight(firstApproval).dx),
        );
        expect(
          tester.getTopLeft(firstGenerate).dx,
          greaterThan(tester.getTopRight(firstRevise).dx),
        );
        expect(
          tester.getCenter(firstGenerate).dy,
          closeTo(tester.getCenter(firstApproval).dy, 1),
        );
      }
      await tapVisible(tester, firstApproval);
      expect(tester.widget<FilledButton>(sourceGenerate).onPressed, isNull);
      expect(tester.widget<FilledButton>(firstGenerate).onPressed, isNull);
      await tapVisible(tester, firstApproval);
      await tapVisible(tester, firstGenerate);
      expect(find.byKey(const Key('ai-generation-view')), findsOneWidget);
      expect(find.byKey(const Key('ai-source-text-field')), findsNothing);
      expect(find.byKey(Key('ai-concept-${first.id}')), findsOneWidget);
      expect(find.text('1. ${first.title}'), findsOneWidget);
      expect(find.text(first.content), findsNothing);
      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(Key('concept-approval-${saved.concepts[1].id}')),
      );
      await tapVisible(tester, sourceGenerate);
      final label = tester.widget<AiSourcePickerField>(
        find.byKey(const Key('ai-source-label-field')),
      );
      expect(label.source!.fileName, saved.source.fileName);
      expect(label.locked, true);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('ai-source-picker-button')))
            .onTap,
        isNull,
      );
      expect(find.byKey(const Key('ai-source-picker-lock')), findsOneWidget);
      expect(find.byKey(const Key('ai-source-text-field')), findsNothing);
      expect(
        find.byKey(Key('ai-concept-${saved.concepts[0].id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('ai-concept-${saved.concepts[1].id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('ai-concept-${saved.concepts[2].id}')),
        findsNothing,
      );
      final importanceToggle = find.byKey(
        const Key('ai-concept-importance-switch'),
      );
      expect(tester.widget<SwitchListTile>(importanceToggle).value, true);
      await tapVisible(tester, importanceToggle);
      expect(tester.widget<SwitchListTile>(importanceToggle).value, false);
      await tapVisible(
        tester,
        find.byKey(const Key('generate-ai-questions-button')),
      );
      expect(remote.callCount, 1);
      expect(remote.lastRequest!.sourceText, isEmpty);
      expect(remote.lastRequest!.toJson().containsKey('sourceText'), false);
      expect(remote.lastRequest!.reflectConceptImportance, false);
      expect(remote.lastRequest!.concepts.map((c) => c.id).toSet(), {
        saved.concepts[0].id,
        saved.concepts[1].id,
      });
      final generated = (await tester.runAsync(
        () =>
            DriftQuestionRepository(database)
                .watchQuestions(saved.source.folderId)
                .first,
      ))!;
      expect(generated, hasLength(4));
      for (final question in generated) {
        final reference = question.sourceReferences.single;
        expect(reference.sourceId, saved.source.id);
        expect(
          reference.conceptId,
          isIn([saved.concepts[0].id, saved.concepts[1].id]),
        );
        final concept = saved.concepts.firstWhere(
          (c) => c.id == reference.conceptId,
        );
        expect(reference.pageNumbers, concept.pageNumbers);
        expect(question.importance, concept.importance);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    '새 자료 생성과 PDF 수동 개념 추가가 같은 편집·승인·AI 파이프라인을 사용한다',
    (tester) async {
      await tester.binding.setSurfaceSize(
        defaultTargetPlatform == TargetPlatform.windows
            ? const Size(1100, 1000)
            : const Size(390, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final configuration = credentials.configuration;
      credentials.configuration = null;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-view'))),
      );
      container
          .read(routerProvider)
          .go(AppRoutes.folder(saved.source.folderId));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-section-header')), findsOneWidget);
      expect(find.text('PDF 강의자료'), findsNothing);
      await tapVisible(tester, find.byKey(const Key('create-source-button')));
      await tapVisible(tester, find.byKey(const Key('save-new-source-button')));
      expect(find.text('자료 이름을 입력해 주세요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('new-source-name-field')),
        '내 복습 자료',
      );
      await tapVisible(tester, find.byKey(const Key('save-new-source-button')));
      expect(
        tester.widget<Text>(find.byKey(const Key('document-title'))).data,
        '내 복습 자료',
      );
      expect(find.text('사용자 생성 자료 · 개념 0개'), findsOneWidget);
      expect(find.byTooltip('개념 메뉴'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('request-concept-revision-button')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('generate-source-questions-button')),
            )
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.byKey(const Key('add-concept-button')));
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('new-concept-reviewed-field')),
            )
            .value,
        isTrue,
      );
      await tapVisible(tester, find.byKey(const Key('save-concept-button')));
      expect(find.text('제목을 입력해 주세요.'), findsOneWidget);
      expect(find.text('내용을 입력해 주세요.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('concept-title-field')),
        '직접 쓴 개념',
      );
      await tester.enterText(
        find.byKey(const Key('concept-content-field')),
        '사용자가 직접 작성한 개념 내용입니다.',
      );
      final importanceField = find.byKey(const Key('concept-importance-field'));
      expect(tester.widget<Slider>(importanceField).divisions, 4);
      await setImportance(tester, ConceptImportance.veryLow);
      await tapVisible(tester, find.byKey(const Key('save-concept-button')));
      expect(find.text('1. 직접 쓴 개념'), findsOneWidget);
      expect(find.text('중요도 매우 낮음'), findsOneWidget);
      final materials = await sources.getSources(saved.source.folderId);
      final manual = materials.singleWhere((source) => source.isManual);
      final concept = (await sources.getSourceWithConcepts(manual.id))
          .concepts
          .single;
      expect(
        find.byKey(Key('concept-page-source-${concept.id}')),
        findsNothing,
      );
      expect(find.text('검토 완료'), findsNWidgets(2));
      expect(concept.importance, ConceptImportance.veryLow);
      expect(
        tester
            .widget<Chip>(
              find.descendant(
                of: find.byKey(Key('concept-importance-${concept.id}')),
                matching: find.byType(Chip),
              ),
            )
            .labelStyle!
            .color,
        const Color(0xFF3D6075),
      );
      await tapVisible(tester, find.byTooltip('개념 메뉴'));
      await tapVisible(tester, find.text('수정'));
      await tester.enterText(
        find.byKey(const Key('concept-content-field')),
        '직접 편집한 상세 내용입니다.',
      );
      await setImportance(tester, ConceptImportance.veryHigh);
      await tapVisible(tester, find.byKey(const Key('save-concept-button')));
      expect(find.text('직접 편집한 상세 내용입니다.'), findsOneWidget);
      expect(find.text('중요도 매우 높음'), findsOneWidget);
      expect(
        tester
            .widget<Chip>(
              find.descendant(
                of: find.byKey(Key('concept-importance-${concept.id}')),
                matching: find.byType(Chip),
              ),
            )
            .labelStyle!
            .color,
        const Color(0xFF89545C),
      );
      expect(
        tester
            .widget<Switch>(find.byKey(Key('concept-approval-${concept.id}')))
            .value,
        isTrue,
      );
      credentials.configuration = configuration;
      await tapVisible(
        tester,
        find.byKey(Key('request-concept-revision-${concept.id}')),
      );
      await tester.enterText(
        find.byKey(const Key('concept-revision-instruction-field')),
        '끝에 테스트 추가',
      );
      await tapVisible(
        tester,
        find.byKey(const Key('send-concept-revision-button')),
      );
      expect(find.text('AI 수정안 검토'), findsOneWidget);
      expect(documentApi.lastSource!.pageCount, 0);
      expect(documentApi.lastConcepts!.single.pageNumbers, isEmpty);
      expect(
        documentApi.lastConcepts!.single.importance,
        ConceptImportance.veryHigh,
      );
      expect(
        (await sources.getSourceWithConcepts(manual.id))
            .concepts
            .single
            .content,
        '직접 편집한 상세 내용입니다.',
      );
      await tapVisible(
        tester,
        find.byKey(const Key('apply-concept-revisions-button')),
      );
      expect(find.text('직접 편집한 상세 내용입니다. 테스트 추가'), findsOneWidget);
      expect(find.text('중요도 매우 높음'), findsOneWidget);
      expect(
        tester
            .widget<Switch>(find.byKey(Key('concept-approval-${concept.id}')))
            .value,
        isFalse,
      );
      expect(
        find.byKey(Key('concept-page-source-${concept.id}')),
        findsNothing,
      );
      await tapVisible(
        tester,
        find.byKey(Key('concept-approval-${concept.id}')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('generate-source-questions-button')),
      );
      // The revision snackbar can briefly cover the bottom form action.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-source-text-field')), findsNothing);
      expect(find.byKey(Key('ai-concept-title-${concept.id}')), findsOneWidget);
      expect(find.text('직접 편집한 상세 내용입니다. 테스트 추가'), findsNothing);
      await tapVisible(
        tester,
        find.byKey(const Key('generate-ai-questions-button')),
      );
      expect(remote.lastRequest!.sourceText, isEmpty);
      expect(
        remote.lastRequest!.concepts.single.content,
        '직접 편집한 상세 내용입니다. 테스트 추가',
      );
      final questions = (await tester.runAsync(
        () =>
            DriftQuestionRepository(database)
                .watchQuestions(saved.source.folderId)
                .first,
      ))!;
      expect(questions, hasLength(4));
      expect(
        questions.every(
          (question) => question.sourceReferences.single.pageNumbers.isEmpty,
        ),
        isTrue,
      );

      // The same add-concept UI also works on a PDF without inventing a page.
      container
          .read(routerProvider)
          .go(
            AppRoutes.documentsForSource(
              saved.source.folderId,
              saved.source.id,
            ),
          );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('add-concept-button')));
      await tester.enterText(
        find.byKey(const Key('concept-title-field')),
        '개인 메모',
      );
      await tester.enterText(
        find.byKey(const Key('concept-content-field')),
        'PDF에 추가한 개인 설명입니다.',
      );
      await tapVisible(
        tester,
        find.byKey(const Key('new-concept-reviewed-field')),
      );
      await tapVisible(tester, find.byKey(const Key('save-concept-button')));
      final mixed = await sources.getSourceWithConcepts(saved.source.id);
      final added = mixed.concepts.last;
      expect(added.title, '개인 메모');
      expect(added.status, ConceptStatus.held);
      expect(find.text('4. 개인 메모'), findsOneWidget);
      expect(find.byKey(Key('concept-page-source-${added.id}')), findsNothing);
      expect(
        find.byKey(Key('concept-page-source-${mixed.concepts.first.id}')),
        findsOneWidget,
      );

      // User material deletion never attempts a PDF file request or needs credentials.
      credentials.configuration = null;
      container
          .read(routerProvider)
          .go(AppRoutes.folder(saved.source.folderId));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(Key('pdf-source-menu-${manual.id}')));
      await tapVisible(tester, find.text('삭제'));
      await tapVisible(
        tester,
        find.byKey(const Key('confirm-delete-pdf-source-button')),
      );
      expect(documentApi.deleteCount, 0);
      expect(find.text('내 복습 자료'), findsNothing);
      expect(
        (await sources.getSources(saved.source.folderId))
            .any((source) => source.id == manual.id),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  for (final action in ['cancel', 'apply', 'applyAndReview']) {
    testWidgets(
      'AI 수정안 $action 선택은 변경된 개념의 검토 상태만 갱신한다',
      (tester) async {
        await tester.binding.setSurfaceSize(
          defaultTargetPlatform == TargetPlatform.windows
              ? const Size(1100, 1000)
              : const Size(390, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final original = saved.concepts.first;
        await sources.setConceptApproval(id: original.id, approved: true);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('home-view'))),
        );
        container
            .read(routerProvider)
            .go(
              AppRoutes.documentsForSource(
                saved.source.folderId,
                saved.source.id,
              ),
            );
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.byKey(Key('request-concept-revision-${original.id}')),
        );
        await tester.enterText(
          find.byKey(const Key('concept-revision-instruction-field')),
          '내용에 테스트 추가',
        );
        await tapVisible(
          tester,
          find.byKey(const Key('send-concept-revision-button')),
        );
        expect(find.text('AI 수정안 검토'), findsOneWidget);
        expect(find.text('적용'), findsOneWidget);
        expect(find.text('적용 후 검토 완료'), findsOneWidget);
        expect(
          (await sources.getSourceWithConcepts(saved.source.id))
              .concepts
              .first
              .content,
          original.content,
        );
        final key = switch (action) {
          'cancel' => 'cancel-concept-revisions-button',
          'apply' => 'apply-concept-revisions-button',
          _ => 'apply-and-review-concept-revisions-button',
        };
        await tapVisible(tester, find.byKey(Key(key)));
        final updated = await sources.getSourceWithConcepts(saved.source.id);
        final reviewed = action != 'apply';
        expect(
          updated.concepts.first.status,
          reviewed ? ConceptStatus.approved : ConceptStatus.held,
        );
        expect(
          updated.concepts.first.content,
          action == 'cancel' ? original.content : '${original.content} 테스트 추가',
        );
        expect(updated.concepts.first.pageNumbers, original.pageNumbers);
        expect(
          updated.concepts
              .skip(1)
              .every((concept) => concept.status == ConceptStatus.held),
          isTrue,
        );
        expect(
          tester
              .widget<Switch>(
                find.byKey(Key('concept-approval-${original.id}')),
              )
              .value,
          reviewed,
        );
        final button = tester.widget<FilledButton>(
          find.byKey(Key('generate-concept-questions-${original.id}')),
        );
        expect(button.onPressed, reviewed ? isNotNull : isNull);
        if (action != 'cancel') {
          expect(
            find.text(
              reviewed
                  ? '1개 변경을 적용했어요. 추가·수정 개념을 검토 완료로 표시했어요.'
                  : '1개 변경을 적용했어요. 추가·수정 개념은 검토 필요 상태예요.',
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets('검토 완료 개념이 없는 자료의 문제 생성 직접 진입도 안전하게 거부한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('home-view'))),
    );
    container
        .read(routerProvider)
        .go(
          AppRoutes.aiGenerateForSource(saved.source.folderId, saved.source.id),
        );
    await tester.pumpAndSettle();
    expect(find.text('문제를 생성하려면 개념을 하나 이상 검토 완료로 표시해 주세요.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('generate-ai-questions-button')),
          )
          .onPressed,
      isNull,
    );
    expect(remote.callCount, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
