import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/repositories/folder_repository.dart';

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
    );
  });
  tearDown(() async {
    await localServerService.dispose();
    await database.close();
  });

  Widget buildApp({RemoteAiApi? remoteAiApi}) => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      syncCredentialsStoreProvider.overrideWithValue(credentialsStore),
      localServerConfigStoreProvider.overrideWithValue(localServerConfigStore),
      localServerSecretStoreProvider.overrideWithValue(localServerSecretStore),
      localServerServiceProvider.overrideWithValue(localServerService),
      if (remoteAiApi != null)
        remoteAiApiProvider.overrideWithValue(remoteAiApi),
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

    await tester.ensureVisible(
      find.byKey(const Key('local-server-settings-tile')),
    );
    await tester.tap(find.byKey(const Key('local-server-settings-tile')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local-server-view')), findsOneWidget);
    expect(find.text('Review Platform Server'), findsOneWidget);
    expect(find.byKey(const Key('start-local-server-button')), findsOneWidget);
    expect(find.byKey(const Key('local-server-log-view')), findsOneWidget);
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
  LocalServerConfig value = const LocalServerConfig.defaults();

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
