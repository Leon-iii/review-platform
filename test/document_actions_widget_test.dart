import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
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
          final value = tester.widget<Text>(text).data!;
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
        expect(tester.widget<Text>(title).maxLines, 1);
        expect(tester.widget<Text>(title).overflow, TextOverflow.ellipsis);
        expect(paragraphFor(tester, title).didExceedMaxLines, isTrue);
        final shortTitle = find.byKey(Key('concept-title-${second.id}'));
        final shortParagraph = paragraphFor(tester, shortTitle);
        final shortTitleFits =
            scale == 1.0 || defaultTargetPlatform == TargetPlatform.windows;
        expect(shortParagraph.didExceedMaxLines, !shortTitleFits);
        if (shortTitleFits) {
          expect(
            tester.getSize(shortTitle).width,
            closeTo(shortParagraph.getMaxIntrinsicWidth(double.infinity), 0.1),
          );
        }
        expect(
          tester.getTopLeft(find.byKey(Key('concept-status-${second.id}'))).dx -
              tester.getTopRight(shortTitle).dx,
          closeTo(8, 0.1),
        );
        final manualTitle = find.byKey(Key('concept-title-${manual.id}'));
        final manualParagraph = paragraphFor(tester, manualTitle);
        expect(manualParagraph.didExceedMaxLines, !shortTitleFits);
        if (shortTitleFits) {
          expect(
            tester.getSize(manualTitle).width,
            closeTo(manualParagraph.getMaxIntrinsicWidth(double.infinity), 0.1),
          );
        }
        expect(
          tester.getTopLeft(find.byKey(Key('concept-status-${manual.id}'))).dx -
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
      expect(
        tester.getCenter(sourceGenerate).dx,
        greaterThan(tester.getCenter(sourceRevise).dx),
      );
      expect(
        tester.getCenter(sourceGenerate).dy,
        closeTo(tester.getCenter(sourceRevise).dy, 1),
      );
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
      expect(
        tester.getTopLeft(sourceRevise).dx,
        greaterThan(tester.getTopRight(sourceAdd).dx),
      );
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
        expect(
          reference.side!.color,
          badgeTheme.brightness == Brightness.dark
              ? Colors.grey.shade700
              : Colors.grey.shade400,
        );
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
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('ai-source-text-field')),
            )
            .controller!
            .text,
        '${first.title}\n\n${first.content}',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(Key('concept-approval-${saved.concepts[1].id}')),
      );
      await tapVisible(tester, sourceGenerate);
      final label = tester.widget<TextFormField>(
        find.byKey(const Key('ai-source-label-field')),
      );
      final contents = tester.widget<TextFormField>(
        find.byKey(const Key('ai-source-text-field')),
      );
      expect(label.controller!.text, saved.source.fileName);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('ai-source-text-field')),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        isTrue,
      );
      expect(contents.controller!.text, contains('첫 개념'));
      expect(contents.controller!.text, contains('둘째 개념'));
      expect(contents.controller!.text, isNot(contains('보류 개념')));
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
      expect(remote.lastRequest!.sourceText, contents.controller!.text);
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
      final contents = tester
          .widget<TextFormField>(find.byKey(const Key('ai-source-text-field')))
          .controller!
          .text;
      expect(contents, contains('직접 편집한 상세 내용입니다. 테스트 추가'));
      expect(contents, isNot(contains('페이지:')));
      await tapVisible(
        tester,
        find.byKey(const Key('generate-ai-questions-button')),
      );
      expect(remote.lastRequest!.sourceText, contents);
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
