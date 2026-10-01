import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_ai.dart';
import 'support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late MemorySyncCredentialsStore credentialsStore;
  late _MemoryLocalServerConfigStore localServerConfigStore;
  late _MemoryLocalServerSecretStore localServerSecretStore;
  late LocalServerService localServerService;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    credentialsStore = MemorySyncCredentialsStore();
    localServerConfigStore = _MemoryLocalServerConfigStore();
    localServerSecretStore = _MemoryLocalServerSecretStore();
    localServerService = LocalServerService(
      secretStore: localServerSecretStore,
      isWindows: true,
      healthCheck: (_) async => false,
    );
  });
  tearDown(() async {
    await localServerService.dispose();
    await database.close();
  });

  Widget buildApp({
    RemoteAiApi? remoteAiApi,
    RemoteDocumentApi? remoteDocumentApi,
  }) => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      syncCredentialsStoreProvider.overrideWithValue(credentialsStore),
      localServerConfigStoreProvider.overrideWithValue(localServerConfigStore),
      localServerSecretStoreProvider.overrideWithValue(localServerSecretStore),
      localServerServiceProvider.overrideWithValue(localServerService),
      if (remoteAiApi != null)
        remoteAiApiProvider.overrideWithValue(remoteAiApi),
      if (remoteDocumentApi != null)
        remoteDocumentApiProvider.overrideWithValue(remoteDocumentApi),
    ],
    child: const ReviewApp(),
  );

  testWidgets('홈 화면에 MVP 학습 요약과 시작 기능이 표시된다', (tester) async {
    await tester.pumpWidget(buildApp());

    expect(find.text('오늘 푼 문제'), findsOneWidget);
    expect(find.text('최근 정답률'), findsOneWidget);
    expect(find.text('문제 풀기'), findsOneWidget);
    expect(find.text('최근 오답'), findsOneWidget);
    expect(find.text('최근 학습'), findsOneWidget);
  });

  testWidgets('좁은 화면에서 NavigationBar로 화면을 전환한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildApp());

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-view')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('통계 화면에 기간·폴더·최근 오답 영역을 표시한다', (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('statistics-view')), findsOneWidget);
    expect(find.text('기간별 정답률'), findsOneWidget);
    expect(find.text('폴더별 정답률'), findsOneWidget);
    expect(find.text('최근 오답'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('설정 화면에 동기화 Outbox 대기 건수를 표시한다', (tester) async {
    await DriftFolderRepository(database).createFolder(name: '동기화 대기');
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-view')), findsOneWidget);
    expect(find.text('대기 1건'), findsOneWidget);
    expect(find.text('수동 동기화'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows 설정에서 Local Server 화면으로 이동한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('local-server-settings-tile')), findsOneWidget);
    expect(
      find.byKey(const Key('local-server-status-indicator')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('local-server-settings-tile'))).dy,
      lessThan(tester.getTopLeft(find.text('동기화')).dy),
    );

    await tester.ensureVisible(
      find.byKey(const Key('local-server-settings-tile')),
    );
    await tester.tap(find.byKey(const Key('local-server-settings-tile')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-server-view')), findsOneWidget);
    expect(find.text('Review Platform Server'), findsOneWidget);
    expect(find.byKey(const Key('start-local-server-button')), findsOneWidget);
    expect(find.byKey(const Key('local-server-log-view')), findsOneWidget);
    final autoStart = tester.widget<SwitchListTile>(
      find.byKey(const Key('local-server-auto-start-switch')),
    );
    expect(autoStart.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start Server를 누르면 응답 전까지 버튼을 잠그고 Starting 상태를 표시한다', (
    tester,
  ) async {
    await localServerService.dispose();
    var serverReady = false;
    final process = _FakeManagedServerProcess();
    localServerService = LocalServerService(
      secretStore: localServerSecretStore,
      isWindows: true,
      directoryResolver: () async => r'C:\project\server',
      processLauncher: (
        executable,
        arguments, {
        required workingDirectory,
        required environment,
      }) async => process,
      healthCheck: (_) async => serverReady,
      portAvailabilityCheck: (_) async => true,
      healthInterval: const Duration(milliseconds: 10),
      healthTimeout: const Duration(seconds: 1),
    );
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('local-server-settings-tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-local-server-button')));
    await tester.pump();

    final startingButton = tester.widget<FilledButton>(
      find.byKey(const Key('start-local-server-button')),
    );
    expect(startingButton.onPressed, isNull);
    expect(find.text('Starting...'), findsAtLeastNWidgets(1));

    serverReady = true;
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(find.text('Running'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows가 아니면 Local Server 메뉴를 숨긴다', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          syncCredentialsStoreProvider.overrideWithValue(credentialsStore),
          localServerConfigStoreProvider.overrideWithValue(
            localServerConfigStore,
          ),
          localServerSecretStoreProvider.overrideWithValue(
            localServerSecretStore,
          ),
          localServerServiceProvider.overrideWithValue(localServerService),
          isWindowsPlatformProvider.overrideWithValue(false),
        ],
        child: const ReviewApp(),
      ),
    );

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-server-settings-tile')), findsNothing);
    expect(find.byKey(const Key('llm-profiles-settings-tile')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('문제 관리에서 새 폴더를 생성한다', (tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '전자기학');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('전자기학'), findsOneWidget);
    expect(find.text('전자기학 폴더를 생성했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('폴더에 객관식 문제를 추가한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await DriftFolderRepository(database).createFolder(name: '전자기학');
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('전자기학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-question-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('question-prompt-field')),
      '전기장의 SI 단위는?',
    );
    expect(find.byKey(const Key('question-difficulty-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('choice-field-0')), 'V/m');
    await tester.enterText(find.byKey(const Key('choice-field-1')), 'A/m');
    await tester.enterText(find.byKey(const Key('choice-field-2')), 'T');
    await tester.enterText(find.byKey(const Key('choice-field-3')), 'Wb');
    await tester.tap(find.byKey(const Key('save-question-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('save-question-button')), findsNothing);
    expect(find.text('전기장의 SI 단위는?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('폴더에 O/X 문제를 추가한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await DriftFolderRepository(database).createFolder(name: '물리학');
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('물리학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-question-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('O/X'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('question-prompt-field')),
      '지구는 태양 주위를 돈다.',
    );
    await tester.tap(find.byKey(const Key('true-false-answer-x')));
    await tester.tap(find.byKey(const Key('save-question-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('save-question-button')), findsNothing);
    expect(find.text('지구는 태양 주위를 돈다.'), findsOneWidget);
    expect(find.text('O/X'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('폴더에서 AI 문제 생성 화면으로 이동한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final folderRepository = DriftFolderRepository(database);
    final rootId = await folderRepository.createFolder(name: '전자기학');
    final childId = await folderRepository.createFolder(
      name: '3주차',
      parentId: rootId,
    );
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('전자기학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('generate-ai-questions-nav-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-generation-view')), findsOneWidget);
    expect(find.text('AI 문제 생성'), findsOneWidget);
    expect(find.byKey(const Key('ai-source-text-field')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-folder-field')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('folder-picker-search-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('folder-picker-search-field')),
      '3주차',
    );
    await tester.pumpAndSettle();
    expect(find.text('전자기학 › 3주차'), findsOneWidget);
    await tester.tap(find.byKey(Key('folder-picker-item-$childId')));
    await tester.pumpAndSettle();
    expect(find.text('전자기학 › 3주차'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-folder-field')));
    await tester.pumpAndSettle();
    expect(find.text('최근 사용'), findsOneWidget);
    expect(
      find.byKey(Key('folder-picker-recent-item-$childId')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-automatic-density-field')), findsOneWidget);
    expect(find.text('보통 · 개념별 3~4개'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-count-mode-manual')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-automatic-density-field')), findsNothing);
    expect(
      find.byKey(const Key('ai-manual-question-count-field')),
      findsOneWidget,
    );
    expect(find.text('10'), findsOneWidget);
    expect(
      find.byKey(const Key('generate-ai-questions-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('폴더에서 PDF 학습자료 화면으로 이동한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await DriftFolderRepository(database).createFolder(name: '물리학');
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('물리학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-pdf-nav-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('document-import-view')), findsOneWidget);
    expect(find.byKey(const Key('pick-pdf-button')), findsOneWidget);
    expect(find.text('가져온 자료'), findsNothing);
    expect(find.text('자료 목록'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('PDF 강의자료를 문제보다 먼저 표시하고 이름 변경 메뉴를 사용한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '전자기학');
    final saved = await DriftSourceRepository(database).saveImport(
      folderId: folderId,
      result: DocumentImportResult(
        source: ImportedSource(
          id: 'source-widget-test',
          fileName: '1주차.pdf',
          contentHash: List.filled(64, 'a').join(),
          pageCount: 12,
          extractionMethod: 'textLayer',
          importedAt: DateTime.utc(2026, 10, 1),
        ),
        concepts: const [
          ImportedConcept(
            title: '전자기파',
            content: '전자기파의 성질을 설명한다.',
            pageNumbers: [8],
          ),
          ImportedConcept(
            title: '맥스웰 방정식',
            content: '전기장과 자기장의 관계를 네 개의 방정식으로 설명한다.',
            pageNumbers: [2, 3],
          ),
        ],
      ),
    );
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final remoteDocumentApi = _FakeRemoteDocumentApi(
      revision: ConceptRevision(
        id: saved.concepts.first.id,
        title: saved.concepts.first.title,
        content: '전기장과 자기장의 관계를 더 자연스럽게 설명한다.',
        pageNumbers: saved.concepts.first.pageNumbers,
        importance: ConceptImportance.high,
      ),
    );
    await tester.pumpWidget(buildApp(remoteDocumentApi: remoteDocumentApi));

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    expect(find.text('하위 폴더 0개, 문제 0개, PDF 강의자료 1개'), findsOneWidget);
    await tester.tap(find.text('전자기학'));
    await tester.pumpAndSettle();

    expect(find.text('PDF 강의자료'), findsOneWidget);
    expect(find.text('1주차.pdf'), findsOneWidget);
    expect(find.byTooltip('PDF 강의자료 메뉴'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('PDF 강의자료')).dy,
      lessThan(tester.getTopLeft(find.text('문제')).dy),
    );

    await tester.tap(find.byTooltip('PDF 강의자료 메뉴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 변경'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pdf-source-name-field')),
      '전자기학 1주차',
    );
    await tester.tap(find.byKey(const Key('save-pdf-source-button')));
    await tester.pumpAndSettle();
    expect(find.text('전자기학 1주차.pdf'), findsOneWidget);

    await tester.tap(find.text('전자기학 1주차.pdf'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('document-import-view')), findsOneWidget);
    expect(find.text('1. 맥스웰 방정식'), findsOneWidget);
    expect(find.text('2. 전자기파'), findsOneWidget);
    expect(find.text('자료 목록'), findsNothing);
    expect(find.text('보류됨'), findsNWidgets(2));
    expect(find.text('중요도 보통'), findsNWidgets(2));
    expect(find.text('Draft'), findsNothing);
    expect(find.text('수정 후 승인'), findsNothing);
    expect(find.byTooltip('개념 메뉴'), findsNWidgets(2));
    expect(find.text('AI 수정 요청'), findsNWidgets(2));

    await tester.tap(find.byTooltip('개념 메뉴').first);
    await tester.pumpAndSettle();
    expect(find.text('수정'), findsOneWidget);
    expect(find.text('삭제'), findsOneWidget);
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();
    expect(find.text('개념 수정'), findsOneWidget);
    expect(find.text('저장 및 승인'), findsNothing);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    final firstConceptId = saved.concepts.first.id;
    await tester.tap(find.byKey(ValueKey('concept-approval-$firstConceptId')));
    await tester.pumpAndSettle();
    expect(find.text('승인됨'), findsOneWidget);
    final approvedBadge = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(ValueKey('concept-status-$firstConceptId')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final approvedDecoration = approvedBadge.decoration as BoxDecoration;
    expect(approvedDecoration.gradient, isA<LinearGradient>());
    expect((approvedDecoration.gradient! as LinearGradient).colors, const [
      Color(0xFF66BB6A),
      Color(0xFF388E3C),
    ]);

    final perConceptRevisionButton = find.byKey(
      ValueKey('request-concept-revision-$firstConceptId'),
    );
    await tester.ensureVisible(perConceptRevisionButton);
    await tester.tap(perConceptRevisionButton);
    await tester.pumpAndSettle();
    var targetTile = tester.widget<CheckboxListTile>(
      find.byKey(ValueKey('concept-revision-target-$firstConceptId')),
    );
    expect(targetTile.value, isTrue);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('request-concept-revision-button')),
    );
    await tester.tap(find.byKey(const Key('request-concept-revision-button')));
    await tester.pumpAndSettle();
    expect(find.text('미승인'), findsNothing);
    expect(find.text('모두'), findsNothing);
    targetTile = tester.widget<CheckboxListTile>(
      find.byKey(ValueKey('concept-revision-target-$firstConceptId')),
    );
    expect(targetTile.value, isFalse);
    await tester.enterText(
      find.byKey(const Key('concept-revision-instruction-field')),
      '설명을 더 자연스럽게 고쳐 줘.',
    );
    await tester.tap(
      find.byKey(ValueKey('concept-revision-target-$firstConceptId')),
    );
    await tester.tap(find.byKey(const Key('send-concept-revision-button')));
    await tester.pumpAndSettle();

    expect(remoteDocumentApi.capturedConcepts, hasLength(2));
    expect(remoteDocumentApi.capturedInstruction, '설명을 더 자연스럽게 고쳐 줘.');
    expect(remoteDocumentApi.capturedTargetConceptIds, {firstConceptId});
    expect(find.text('AI 수정안 검토'), findsOneWidget);
    expect(find.text('변경 전'), findsNWidgets(2));
    expect(find.text('변경 후'), findsNWidgets(2));
    expect(find.text('승인됨'), findsOneWidget);
    expect(find.text('수정안 적용'), findsOneWidget);

    await tester.tap(find.byKey(const Key('apply-concept-revisions-button')));
    await tester.pumpAndSettle();

    expect(find.text('승인됨'), findsNothing);
    expect(find.text('보류됨'), findsNWidgets(2));
    expect(find.text('1개 개념을 수정하고 보류 상태로 변경했어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('AI 문제 생성 요청 중 Progress bar를 표시한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await DriftFolderRepository(database).createFolder(name: '수학');
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final remoteAiApi = FakeRemoteAiApi()..gate = Completer<void>();
    await tester.pumpWidget(buildApp(remoteAiApi: remoteAiApi));

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('generate-ai-questions-nav-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ai-source-text-field')),
      '사칙연산은 덧셈, 뺄셈, 곱셈, 나눗셈으로 구성됩니다.',
    );
    await tester.tap(find.byKey(const Key('generate-ai-questions-button')));
    await tester.pump();

    expect(find.byKey(const Key('ai-generation-progress-bar')), findsOneWidget);
    expect(find.text('학습 내용을 분석하고 문제를 생성하고 있어요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 문제 검토에서 정답에만 체크를 표시한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await DriftFolderRepository(database).createFolder(name: '수학');
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    await tester.pumpWidget(buildApp(remoteAiApi: FakeRemoteAiApi()));

    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수학'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('generate-ai-questions-nav-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ai-source-text-field')),
      '사칙연산은 덧셈, 뺄셈, 곱셈, 나눗셈으로 구성됩니다.',
    );
    await tester.tap(find.byKey(const Key('generate-ai-questions-button')));
    await tester.pumpAndSettle();

    expect(find.text('✓ 정답'), findsWidgets);
    expect(find.text('난이도 2/5'), findsWidgets);
    expect(find.text('오답'), findsWidgets);
    expect(find.text('○ 오답'), findsNothing);
    expect(find.text('✓ O'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('○ X'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('넓은 화면에서 NavigationRail을 사용한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildApp());

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material 3와 시스템 테마를 사용한다', (tester) async {
    await tester.pumpWidget(buildApp());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.useMaterial3, isTrue);
    expect(app.darkTheme?.useMaterial3, isTrue);
  });
}

class _MemoryLocalServerConfigStore implements LocalServerConfigStore {
  LocalServerConfig value = const LocalServerConfig(
    port: 5080,
    autoStart: false,
  );

  @override
  Future<LocalServerConfig> read() async => value;

  @override
  Future<void> write(LocalServerConfig config) async {
    value = config;
  }
}

class _MemoryLocalServerSecretStore implements LocalServerSecretStore {
  final Map<LocalLlmProvider, String> _values = {};

  @override
  Future<String?> read(LocalLlmProvider provider) async => _values[provider];

  @override
  Future<void> write(LocalLlmProvider provider, String value) async {
    _values[provider] = value;
  }
}

class _FakeManagedServerProcess implements ManagedServerProcess {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exitCode = Completer<int>();

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill() {
    if (!_exitCode.isCompleted) {
      _exitCode.complete(0);
      unawaited(_stdout.close());
      unawaited(_stderr.close());
    }
    return true;
  }
}

class _FakeRemoteDocumentApi implements RemoteDocumentApi {
  _FakeRemoteDocumentApi({required this.revision});

  final ConceptRevision revision;
  List<StudyConcept>? capturedConcepts;
  String? capturedInstruction;
  Set<String>? capturedTargetConceptIds;

  @override
  Future<void> deletePdf({
    required SyncConfiguration configuration,
    required String sourceId,
  }) async {}

  @override
  Future<DocumentImportResult> importPdf({
    required SyncConfiguration configuration,
    required String fileName,
    required Uint8List bytes,
  }) => throw UnimplementedError();

  @override
  Future<List<ConceptRevision>> reviseConcepts({
    required SyncConfiguration configuration,
    required StudySource source,
    required List<StudyConcept> concepts,
    required String instruction,
    required Set<String> targetConceptIds,
  }) async {
    capturedConcepts = List.of(concepts);
    capturedInstruction = instruction;
    capturedTargetConceptIds = Set.of(targetConceptIds);
    return [revision];
  }
}
