import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/ai/llm_profile_api.dart';
import 'package:review_platform/core/ai/llm_model_filter_store.dart';
import 'package:review_platform/domain/models/llm_model_filter.dart';
import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';

import 'support/fake_ai.dart';
import 'support/fake_sync.dart';

List<String> _reasoningOptions(Slider slider) => [
  for (var index = 0; index <= slider.max; index++)
    slider.semanticFormatterCallback!(index.toDouble()),
];

Future<void> _setReasoningEffort(
  WidgetTester tester,
  String effort, {
  LlmPurpose purpose = LlmPurpose.questionGeneration,
}) async {
  final finder = find.byKey(Key('llm-reasoning-slider-purpose-${purpose.id}'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final slider = tester.widget<Slider>(finder);
  final index = _reasoningOptions(slider).indexOf(effort);
  expect(index, greaterThanOrEqualTo(0));
  expect(slider.onChanged, isNotNull);
  slider.onChanged!(index.toDouble());
  await tester.pumpAndSettle();
}

Future<void> _waitForProfileAutosave(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('save-llm-profiles-button')), findsNothing);
}

void main() {
  late AppDatabase database;
  late MemorySyncCredentialsStore credentialsStore;
  late _MemoryLocalServerConfigStore localServerConfigStore;
  late _MemoryLocalServerSecretStore localServerSecretStore;
  late LocalServerService localServerService;
  late _MemoryLlmModelFilterStore modelFilterStore;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    credentialsStore = MemorySyncCredentialsStore();
    modelFilterStore = _MemoryLlmModelFilterStore();
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
    LlmProfileApi? llmProfileApi,
  }) => ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      syncCredentialsStoreProvider.overrideWithValue(credentialsStore),
      llmModelFilterStoreProvider.overrideWithValue(modelFilterStore),
      localServerConfigStoreProvider.overrideWithValue(localServerConfigStore),
      localServerSecretStoreProvider.overrideWithValue(localServerSecretStore),
      localServerServiceProvider.overrideWithValue(localServerService),
      if (remoteAiApi != null)
        remoteAiApiProvider.overrideWithValue(remoteAiApi),
      if (remoteDocumentApi != null)
        remoteDocumentApiProvider.overrideWithValue(remoteDocumentApi),
      if (llmProfileApi != null)
        llmProfileApiProvider.overrideWithValue(llmProfileApi),
    ],
    child: const ReviewApp(),
  );

  Future<void> openLlmProfiles(
    WidgetTester tester,
    _FakeLlmProfileApi api,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
  }

  for (final openAi in [false, true]) {
    testWidgets(
      'AI 설정 접근성: 툴팁 전환·지연된 목록 갱신에도 입력 노드를 유지한다 (OpenAI=$openAi)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final api = _RefreshingLlmProfileApi(openAi: openAi);
          await openLlmProfiles(tester, api);
          final scroll = find.byKey(const Key('llm-profile-scroll-view'));
          expect(tester.widget(scroll), isA<SingleChildScrollView>());
          // Do not reintroduce the two-pane ListView semantics / tooltip path.
          expect(
            find.descendant(of: scroll, matching: find.byType(Viewport)),
            findsNothing,
          );
          final model = find.byKey(
            const Key('llm-model-purpose-documentVision'),
          );
          final originalField = tester.element(model);
          final originalId = tester.getSemantics(model).id;
          final contextField = find.byKey(
            const Key('llm-context-purpose-documentVision'),
          );
          final originalContext = openAi ? null : tester.element(contextField);
          final refresh = find.byTooltip('모델 목록 새로고침');
          expect(
            tester
                .getSemantics(refresh)
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(tester.getCenter(refresh));
          await tester.pumpAndSettle();
          final filter = find.byKey(
            const Key('llm-model-filter-purpose-documentVision'),
          );
          await mouse.moveTo(tester.getCenter(filter));
          await tester.pumpAndSettle();
          await mouse.moveTo(Offset.zero);
          await tester.pumpAndSettle();

          api.modelGate = Completer<void>();
          await tester.tap(refresh);
          await tester
              .pump(); // Do not settle while indeterminate progress animates.
          expect(tester.element(model), same(originalField));
          expect(tester.getSemantics(model).id, originalId);
          if (!openAi) {
            expect(tester.element(contextField), same(originalContext));
          }
          api.modelGate!.complete();
          await tester.pumpAndSettle();
          expect(tester.element(model), same(originalField));
          expect(tester.getSemantics(model).id, originalId);
          if (!openAi) {
            expect(tester.element(contextField), same(originalContext));
          }
          expect(api.saveCalls, 0);

          await tester.ensureVisible(
            find.byKey(const Key('llm-api-key-openai')),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .getSemantics(find.byKey(const Key('llm-api-key-openai')))
                .getSemanticsData()
                .label,
            contains('OpenAI'),
          );
          await tester.tap(find.byTooltip('뒤로가기'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    '작업별 모델 설정은 OCR·개념 추출·개념 수정·문제 생성 순으로 표시한다',
    (tester) async {
      final api = _FakeLlmProfileApi(openAi: true);
      await openLlmProfiles(tester, api);
      final positions = [
        for (final purpose in [
          LlmPurpose.documentVision,
          LlmPurpose.conceptExtraction,
          LlmPurpose.conceptRevision,
          LlmPurpose.questionGeneration,
        ])
          tester
              .getTopLeft(
                find.byKey(Key('llm-purpose-title-purpose-${purpose.id}')),
              )
              .dy,
      ];
      for (var index = 1; index < positions.length; index++) {
        expect(positions[index], greaterThan(positions[index - 1]));
      }
      await _waitForProfileAutosave(tester);
      expect(api.saveCalls, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('프로필 화면 진입과 모델 목록 갱신만으로는 자동 저장하지 않는다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true);
    await openLlmProfiles(tester, api);
    await _waitForProfileAutosave(tester);
    await tester.tap(find.byTooltip('모델 목록 새로고침'));
    await _waitForProfileAutosave(tester);
    expect(api.saveCalls, 0);
    expect(find.text('변경사항은 자동으로 저장됩니다.'), findsOneWidget);
  });

  testWidgets('네 용도를 직접 설정하고 공유하던 프로필을 독립적으로 저장한다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true);
    await openLlmProfiles(tester, api);
    expect(find.text('용도별 AI 설정'), findsOneWidget);
    for (final purpose in LlmPurpose.values) {
      expect(
        find.byKey(Key('llm-purpose-title-purpose-${purpose.id}')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<LlmProviderKind>>(
              find.byKey(Key('llm-provider-purpose-${purpose.id}')),
            )
            .initialValue,
        LlmProviderKind.openAi,
      );
    }
    expect(find.byKey(const Key('add-llm-profile-button')), findsNothing);
    expect(find.byTooltip('프로필 이름 변경'), findsNothing);
    expect(find.byTooltip('프로필 삭제'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(4));
    await _setReasoningEffort(tester, 'high');
    await _waitForProfileAutosave(tester);
    expect(api.saveCalls, 1);
    expect(api.savedSettings!.profiles, hasLength(4));
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    for (final profile in api.savedSettings!.profiles.skip(1)) {
      expect(profile.model, 'gpt-5-mini');
      expect(profile.reasoningEffort, isNull);
    }
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(
      find.byKey(const Key('llm-reasoning-slider-purpose-questionGeneration')),
    );
    expect(slider.semanticFormatterCallback!(slider.value), 'high');
    expect(api.saveCalls, 1);
    expect(tester.takeException(), isNull);
  });

  for (final openAi in [false, true]) {
    testWidgets(
      '문제 생성 상한 자동 저장과 100/101 경고 경계: OpenAI=$openAi',
      (tester) async {
        final api = _FakeLlmProfileApi(openAi: openAi);
        await openLlmProfiles(tester, api);
        final field = find.byKey(
          const Key('llm-maximum-questions-per-request'),
        );
        final warning = find.byKey(const Key('llm-question-limit-warning'));
        expect(field, findsOneWidget);
        expect(warning, findsOneWidget); // Existing default remains 120.
        await tester.ensureVisible(field);
        await tester.enterText(field, '100');
        await tester.pump();
        expect(warning, findsNothing);
        await _waitForProfileAutosave(tester);
        expect(
          api.savedSettings!.profiles.first.maximumQuestionsPerRequest,
          100,
        );
        await tester.enterText(field, '101');
        await tester.pump();
        expect(warning, findsOneWidget);
        await _waitForProfileAutosave(tester);
        expect(
          api.savedSettings!.profiles.first.maximumQuestionsPerRequest,
          101,
        );
        expect(
          api.savedSettings!.profiles
              .skip(1)
              .every((p) => p.maximumQuestionsPerRequest == 120),
          isTrue,
        );
        await tester.tap(find.byTooltip('뒤로가기'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextFormField>(field).initialValue, '101');
        expect(warning, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.android,
      }),
    );
  }

  for (final invalid in ['', '0', '-1', '1.5', '2147483648']) {
    testWidgets('유효하지 않은 문제 상한은 자동 저장하지 않는다: $invalid', (tester) async {
      final api = _FakeLlmProfileApi(openAi: true);
      await openLlmProfiles(tester, api);
      final field = find.byKey(const Key('llm-maximum-questions-per-request'));
      await tester.ensureVisible(field);
      await tester.enterText(field, invalid);
      await _waitForProfileAutosave(tester);
      expect(api.saveCalls, 0);
      expect(find.text('입력을 완성하면 자동으로 저장됩니다.'), findsOneWidget);
      await tester.enterText(field, '40');
      await _waitForProfileAutosave(tester);
      expect(api.savedSettings!.profiles.first.maximumQuestionsPerRequest, 40);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('자동 저장 실패 시 API Key 입력을 유지하고 재시도 성공 후 지운다', (tester) async {
    final api = _FakeLlmProfileApi()..failWrites = true;
    await openLlmProfiles(tester, api);
    final keyField = find.byKey(const Key('llm-api-key-gemini'));
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, 'gemini-test-secret');
    await _waitForProfileAutosave(tester);
    expect(api.savedSettings, isNull);
    expect(find.byKey(const Key('app-error-dialog')), findsOneWidget);
    expect(find.text('테스트 서버 저장 실패'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(keyField).controller!.text,
      'gemini-test-secret',
    );
    api.failWrites = false;
    await tester.tap(find.byKey(const Key('retry-llm-profile-save')));
    await tester.pumpAndSettle();
    expect(api.saveCalls, 2);
    expect(api.savedApiKeys, {LlmApiKeyProvider.gemini: 'gemini-test-secret'});
    expect(tester.widget<TextFormField>(keyField).controller!.text, isEmpty);
    expect(
      api.savedSettings!.apiKeyConfigured[LlmApiKeyProvider.gemini],
      isTrue,
    );
    expect(find.text('자동 저장됨'), findsOneWidget);
    // A later profile edit keeps the encrypted server key, without re-sending it.
    final context = find.byKey(
      const Key('llm-context-purpose-questionGeneration'),
    );
    await tester.ensureVisible(context);
    await tester.pumpAndSettle();
    await tester.tap(context);
    await tester.pumpAndSettle();
    await tester.tap(find.text('16K (16384 토큰)').last);
    await _waitForProfileAutosave(tester);
    expect(api.savedApiKeys, isEmpty);
    expect(
      api.savedSettings!.apiKeyConfigured[LlmApiKeyProvider.gemini],
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('뒤로 가면 대기 중인 프로필 변경을 즉시 저장한다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true);
    await openLlmProfiles(tester, api);
    await _setReasoningEffort(tester, 'high');
    expect(api.saveCalls, 0);
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('llm-profiles-view')), findsNothing);
    expect(api.saveCalls, 1);
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('저장 중 뒤로 가면 동일 요청 완료를 기다리고 중복 저장하지 않는다', (tester) async {
    final gate = Completer<void>();
    final api = _FakeLlmProfileApi(openAi: true)..saveGate = gate;
    await openLlmProfiles(tester, api);
    await _setReasoningEffort(tester, 'high');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.saveCalls, 1);
    expect(find.text('자동 저장 중...'), findsOneWidget);
    expect(
      tester
          .widget<Slider>(
            find.byKey(
              const Key('llm-reasoning-slider-purpose-questionGeneration'),
            ),
          )
          .onChanged,
      isNull,
    );
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pump();
    expect(find.byKey(const Key('llm-profiles-view')), findsOneWidget);
    expect(api.saveCalls, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('llm-profiles-view')), findsNothing);
    expect(api.saveCalls, 1);
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('탭 전환으로 프로필 화면이 제거돼도 마지막 변경을 저장한다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true);
    await openLlmProfiles(tester, api);
    await _setReasoningEffort(tester, 'high');
    expect(api.saveCalls, 0);
    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('statistics-view')), findsOneWidget);
    expect(api.saveCalls, 1);
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('탭 전환 시 자동 저장 실패는 입력을 보존하고 나가기를 취소할 수 있다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true)..failWrites = true;
    await openLlmProfiles(tester, api);
    await _setReasoningEffort(tester, 'high');
    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않고 나갈까요?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('계속 편집'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('llm-profiles-view')), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const Key('llm-reasoning-slider-purpose-questionGeneration')),
    );
    expect(slider.semanticFormatterCallback!(slider.value), 'high');
    api.failWrites = false;
    await tester.tap(find.byKey(const Key('retry-llm-profile-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('statistics-view')), findsOneWidget);
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    expect(api.saveCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('탭 전환에서 변경사항을 버리면 저장을 다시 시도하지 않는다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true)..failWrites = true;
    await openLlmProfiles(tester, api);
    await _setReasoningEffort(tester, 'high');
    await tester.tap(find.text('통계'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('변경사항 버리기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('statistics-view')), findsOneWidget);
    expect(api.saveCalls, 1);
    expect(api.savedSettings, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('서로 다른 기존 할당의 모델과 옵션을 보존하고 미할당 프로필은 표시하지 않는다', (tester) async {
    final now = DateTime.utc(2026);
    final api = _FakeLlmProfileApi(
      initialSettings: LlmProfileSettings(
        profiles: [
          LlmProfile(
            id: 'cloud',
            name: '클라우드',
            provider: LlmProviderKind.openAi,
            model: 'gpt-6-luna',
            reasoningEffort: 'max',
            updatedAt: now,
          ),
          LlmProfile(
            id: 'local',
            name: '로컬',
            provider: LlmProviderKind.ollama,
            model: 'qwen3-vl:8b-instruct',
            contextWindowTokens: 16384,
            updatedAt: now,
          ),
          LlmProfile(
            id: 'unused',
            name: '사용하지 않는 프로필',
            provider: LlmProviderKind.openAi,
            model: 'not-installed',
            updatedAt: now,
          ),
        ],
        assignments: {
          LlmPurpose.questionGeneration: 'cloud',
          LlmPurpose.conceptExtraction: 'local',
          LlmPurpose.conceptRevision: 'cloud',
          LlmPurpose.documentVision: 'local',
        },
        apiKeyConfigured: {LlmApiKeyProvider.claude: true},
      ),
    );
    await openLlmProfiles(tester, api);
    expect(find.text('사용하지 않는 프로필'), findsNothing);
    expect(
      tester
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('llm-context-purpose-conceptExtraction')),
          )
          .initialValue,
      16384,
    );
    await _setReasoningEffort(tester, 'high');
    await _waitForProfileAutosave(tester);
    final settings = api.savedSettings!;
    expect(settings.profiles, hasLength(4));
    expect(settings.profiles[0].model, 'gpt-6-luna');
    expect(settings.profiles[0].reasoningEffort, 'high');
    expect(settings.profiles[1].contextWindowTokens, 16384);
    expect(settings.profiles[2].reasoningEffort, 'max');
    expect(settings.profiles[3].contextWindowTokens, 16384);
    expect(settings.apiKeyConfigured[LlmApiKeyProvider.claude], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('여러 용도의 대기 중인 변경을 한 번에 저장한다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true);
    await openLlmProfiles(tester, api);
    // Make both edits inside the debounce window. Waiting for scroll/scrollbar
    // animations between edits can legitimately finish the first autosave.
    final generation = tester.widget<Slider>(
      find.byKey(const Key('llm-reasoning-slider-purpose-questionGeneration')),
    );
    final extraction = tester.widget<Slider>(
      find.byKey(const Key('llm-reasoning-slider-purpose-conceptExtraction')),
    );
    generation.onChanged!(
      _reasoningOptions(generation).indexOf('high').toDouble(),
    );
    extraction.onChanged!(
      _reasoningOptions(extraction).indexOf('low').toDouble(),
    );
    await _waitForProfileAutosave(tester);
    expect(api.saveCalls, 1);
    expect(api.savedSettings!.profiles[0].reasoningEffort, 'high');
    expect(api.savedSettings!.profiles[1].reasoningEffort, 'low');
    expect(api.savedSettings!.profiles[2].reasoningEffort, isNull);
    expect(api.savedSettings!.profiles[3].reasoningEffort, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('사용할 수 없는 모델이 있는 프로필은 자동 저장을 보류하고 폐기를 확인한다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true, openAiModel: 'not-installed');
    await openLlmProfiles(tester, api);
    final keyField = find.byKey(const Key('llm-api-key-gemini'));
    await tester.ensureVisible(keyField);
    await tester.enterText(keyField, 'pending-key');
    await _waitForProfileAutosave(tester);
    expect(api.saveCalls, 0);
    expect(find.text('서버에서 사용할 수 있는 모델을 선택해 주세요.'), findsNWidgets(4));
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않고 나갈까요?'), findsOneWidget);
    await tester.tap(find.text('계속 편집'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('llm-profiles-view')), findsOneWidget);
    expect(
      tester.widget<TextFormField>(keyField).controller!.text,
      'pending-key',
    );
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('변경사항 버리기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('llm-profiles-view')), findsNothing);
    expect(api.saveCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('한 용도의 Provider 변경은 다른 용도의 로컬 모델과 컨텍스트를 유지한다', (tester) async {
    final api = _FakeLlmProfileApi();
    await openLlmProfiles(tester, api);
    final provider = find.byKey(
      const Key('llm-provider-purpose-questionGeneration'),
    );
    await tester.ensureVisible(provider);
    await tester.pumpAndSettle();
    await tester.tap(provider);
    await tester.pumpAndSettle();
    await tester.tap(find.text(LlmProviderKind.openAi.displayName).last);
    await _waitForProfileAutosave(tester);
    expect(
      find.byKey(const Key('llm-context-purpose-questionGeneration')),
      findsNothing,
    );
    expect(api.savedSettings!.profiles.first.provider, LlmProviderKind.openAi);
    for (final profile in api.savedSettings!.profiles.skip(1)) {
      expect(profile.provider, LlmProviderKind.ollama);
      expect(profile.model, 'qwen3-vl:8b-instruct');
    }
    expect(api.savedSettings!.assignments.values.toSet(), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('앱이 비활성화되면 대기 중인 변경을 즉시 저장한다', (tester) async {
    final api = _FakeLlmProfileApi(openAi: true);
    await openLlmProfiles(tester, api);
    await _setReasoningEffort(tester, 'high');
    expect(api.saveCalls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(api.saveCalls, 1);
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(tester.takeException(), isNull);
  });

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
    expect(find.byKey(const Key('local-server-api-key-field')), findsNothing);
    final autoStart = tester.widget<SwitchListTile>(
      find.byKey(const Key('local-server-auto-start-switch')),
    );
    expect(autoStart.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LLM 프로필 최하단에서 세 Provider API Key를 저장한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi();
    await tester.pumpWidget(buildApp(llmProfileApi: api));

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('llm-context-purpose-questionGeneration')),
    );
    await tester.tap(
      find.byKey(const Key('llm-context-purpose-questionGeneration')),
    );
    await tester.pumpAndSettle();
    expect(find.text('64K (65536 토큰)'), findsNothing);
    await tester.tap(find.text('32K (32768 토큰)').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('llm-api-key-openai')),
      400,
      scrollable: find.byType(Scrollable).last,
    );

    expect(find.text('API Key'), findsOneWidget);
    expect(find.byKey(const Key('llm-api-key-openai')), findsOneWidget);
    expect(find.byKey(const Key('llm-api-key-gemini')), findsOneWidget);
    expect(find.byKey(const Key('llm-api-key-claude')), findsOneWidget);
    expect(find.text('서버에 저장된 키가 있습니다.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('llm-api-key-gemini')),
      'gemini-secret',
    );
    await _waitForProfileAutosave(tester);

    expect(api.savedApiKeys, {LlmApiKeyProvider.gemini: 'gemini-secret'});
    expect(api.savedSettings?.profiles.first.contextWindowTokens, 32768);
    expect(find.text('자동 저장됨'), findsOneWidget);
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

  testWidgets('OpenAI 미등록 모델을 주황색으로 표시하고 추론 수준을 자동으로 초기화한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true);
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final reasoningFinder = find.byKey(
      const Key('llm-reasoning-purpose-questionGeneration'),
    );
    expect(
      _reasoningOptions(
        tester.widget<Slider>(
          find.byKey(
            const Key('llm-reasoning-slider-purpose-questionGeneration'),
          ),
        ),
      ),
      isNot(contains('none')),
    );
    await _setReasoningEffort(tester, 'high');
    final modelFinder = find.byKey(
      const Key('llm-model-purpose-questionGeneration'),
    );
    await tester.ensureVisible(modelFinder);
    await tester.tap(modelFinder);
    await tester.pumpAndSettle();
    final unknownLabel = find.text('gpt-7-future · 지원 정보 미등록').last;
    final text = tester.widget<Text>(unknownLabel);
    expect(text.style!.color, Colors.orange.shade800);
    expect(tester.widget<Text>(find.text('gpt-5-mini').last).style, isNull);
    await tester.tap(unknownLabel);
    await tester.pumpAndSettle();
    final reasoning = tester.widget<Slider>(
      find.byKey(const Key('llm-reasoning-slider-purpose-questionGeneration')),
    );
    expect(reasoning.value, 0);
    expect(reasoning.onChanged, isNull);
    expect(_reasoningOptions(reasoning).toSet(), {'자동'});
    expect(find.textContaining('주황색: 추론 지원 정보 미등록'), findsWidgets);
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpAndSettle();
    await tester.ensureVisible(modelFinder);
    expect(
      tester.getTopLeft(reasoningFinder).dy,
      greaterThan(tester.getBottomLeft(modelFinder).dy),
    );
    expect(tester.takeException(), isNull);
    await _waitForProfileAutosave(tester);
    expect(api.savedSettings!.profiles.first.model, 'gpt-7-future');
    expect(api.savedSettings!.profiles.first.reasoningEffort, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OpenAI 프로필에 지원하는 추론 수준을 저장한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true);
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    await _setReasoningEffort(tester, 'high');
    await _waitForProfileAutosave(tester);
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('컨텍스트 크기는 Ollama에서만 표시하고 실행 방식 변경 시 갱신한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true);
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final contextFinder = find.byKey(
      const Key('llm-context-purpose-questionGeneration'),
    );
    final providerFinder = find.byKey(
      const Key('llm-provider-purpose-questionGeneration'),
    );
    Future<void> changeProvider(LlmProviderKind provider) async {
      await tester.ensureVisible(providerFinder);
      await tester.pumpAndSettle();
      await tester.tap(providerFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text(provider.displayName).last);
      await tester.pumpAndSettle();
    }

    expect(contextFinder, findsNothing);
    expect(find.text('컨텍스트 크기'), findsNothing);
    expect(
      find.byKey(const Key('llm-reasoning-purpose-questionGeneration')),
      findsOneWidget,
    );
    await changeProvider(LlmProviderKind.ollama);
    expect(contextFinder, findsOneWidget);
    await tester.ensureVisible(contextFinder);
    await tester.pumpAndSettle();
    await tester.tap(contextFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('16K (16384 토큰)').last);
    await tester.pumpAndSettle();
    await changeProvider(LlmProviderKind.openAi);
    expect(contextFinder, findsNothing);
    expect(find.text('컨텍스트 크기'), findsNothing);
    await changeProvider(LlmProviderKind.ollama);
    expect(
      tester.widget<DropdownButtonFormField<int>>(contextFinder).initialValue,
      0,
    );
    await changeProvider(LlmProviderKind.openAi);
    await _waitForProfileAutosave(tester);
    expect(api.savedSettings!.profiles.first.contextWindowTokens, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GPT-6 Luna는 등록된 모델로 추론 max를 저장한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true, openAiModel: 'gpt-6-luna');
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    expect(find.text('gpt-6-luna · 지원 정보 미등록'), findsNothing);
    final reasoningFinder = find.byKey(
      const Key('llm-reasoning-purpose-questionGeneration'),
    );
    expect(
      _reasoningOptions(
        tester.widget<Slider>(
          find.byKey(
            const Key('llm-reasoning-slider-purpose-questionGeneration'),
          ),
        ),
      ),
      contains('none'),
    );
    final modelFinder = find.byKey(
      const Key('llm-model-purpose-questionGeneration'),
    );
    final filterFinder = find.byKey(
      const Key('llm-model-filter-purpose-questionGeneration'),
    );
    expect(
      tester.getTopLeft(reasoningFinder).dy,
      closeTo(tester.getTopLeft(modelFinder).dy, 1),
    );
    expect(
      tester.getTopLeft(filterFinder).dx,
      greaterThan(tester.getTopRight(modelFinder).dx),
    );
    expect(
      tester.getTopLeft(reasoningFinder).dx,
      greaterThan(tester.getTopRight(filterFinder).dx),
    );
    final reasoningRect = tester.getRect(reasoningFinder);
    final rowWidth = reasoningRect.right - tester.getTopLeft(modelFinder).dx;
    expect(reasoningRect.width, closeTo(rowWidth * 0.5, 0.5));
    await _setReasoningEffort(tester, 'max');
    await _waitForProfileAutosave(tester);
    expect(api.savedSettings!.profiles.first.model, 'gpt-6-luna');
    expect(api.savedSettings!.profiles.first.reasoningEffort, 'max');
    expect(tester.takeException(), isNull);
  });

  testWidgets('추론 수준 텍스트는 medium과 minimal을 확대 글꼴에서도 생략하지 않는다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    await tester.pumpWidget(
      buildApp(llmProfileApi: _FakeLlmProfileApi(openAi: true)),
    );
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final valueFinder = find.byKey(
      const Key('llm-reasoning-value-purpose-questionGeneration'),
    );
    for (final size in [const Size(800, 1200), const Size(390, 800)]) {
      await tester.binding.setSurfaceSize(size);
      for (final scale in [1.0, 2.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpAndSettle();
        double? reservedWidth;
        for (final effort in ['medium', 'minimal', 'high']) {
          await _setReasoningEffort(tester, effort);
          expect(tester.widget<Text>(valueFinder).data, effort);
          final paragraph = tester.renderObject<RenderParagraph>(valueFinder);
          expect(paragraph.didExceedMaxLines, isFalse);
          final width = tester.getSize(valueFinder).width;
          reservedWidth ??= width;
          expect(width, reservedWidth);
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('추론 슬라이더를 드래그해 max와 자동을 선택하고 자동으로 저장한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true, openAiModel: 'gpt-6-luna');
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final sliderFinder = find.byKey(
      const Key('llm-reasoning-slider-purpose-questionGeneration'),
    );
    await tester.ensureVisible(sliderFinder);
    await tester.pumpAndSettle();
    await tester.drag(sliderFinder, const Offset(400, 0));
    await tester.pumpAndSettle();
    var slider = tester.widget<Slider>(sliderFinder);
    expect(slider.semanticFormatterCallback!(slider.value), 'max');
    await tester.drag(sliderFinder, const Offset(-400, 0));
    await tester.pumpAndSettle();
    slider = tester.widget<Slider>(sliderFinder);
    expect(slider.semanticFormatterCallback!(slider.value), '자동');
    await _waitForProfileAutosave(tester);
    expect(api.savedSettings!.profiles.first.reasoningEffort, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('등록된 자동 전용 추론 모델을 미등록이나 비추론 모델로 표시하지 않는다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true, openAiModel: 'o3-pro');
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    expect(find.text('o3-pro · 지원 정보 미등록'), findsNothing);
    expect(find.textContaining('추론 모델이며 자동 모드로 사용할 수 있습니다.'), findsNWidgets(4));
    final reasoning = tester.widget<Slider>(
      find.byKey(const Key('llm-reasoning-slider-purpose-questionGeneration')),
    );
    expect(reasoning.value, 0);
    expect(reasoning.onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('모델 필터는 현재 선택과 미등록 모델을 유지하고 재진입 후 설정을 복구한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    final api = _FakeLlmProfileApi(openAi: true, openAiModel: 'gpt-6-luna');
    await tester.pumpWidget(buildApp(llmProfileApi: api));
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final modelFinder = find.byKey(
      const Key('llm-model-purpose-questionGeneration'),
    );
    List<String?> visible() => tester
        .widget<DropdownButton<String>>(
          find.descendant(
            of: modelFinder,
            matching: find.byType(DropdownButton<String>),
          ),
        )
        .items!
        .map((item) => item.value)
        .toList();
    expect(visible(), ['gpt-6-luna', 'gpt-7-future']);
    final filterButton = find.byKey(
      const Key('llm-model-filter-purpose-questionGeneration'),
    );
    expect(
      find.descendant(
        of: filterButton,
        matching: find.byIcon(Icons.filter_alt_rounded),
      ),
      findsOneWidget,
    );
    Future<void> openFilters() async {
      await tester.ensureVisible(filterButton);
      await tester.pumpAndSettle();
      await tester.tap(filterButton);
      await tester.pumpAndSettle();
    }

    expect(find.text('구형 모델 숨기기'), findsNothing);
    expect(find.text('날짜별 버전 숨기기'), findsNothing);
    await openFilters();
    final oldSwitch = find.byKey(
      const Key('llm-hide-old-purpose-questionGeneration'),
    );
    expect(tester.widget<CheckedPopupMenuItem>(oldSwitch).checked, isTrue);
    await tester.tap(oldSwitch);
    await tester.pumpAndSettle();
    expect(visible(), contains('gpt-5-mini'));
    expect(visible(), isNot(contains('gpt-6-luna-test-snapshot')));
    expect(modelFilterStore.preferences.forProvider('openai').hideOld, isFalse);
    expect(api.savedSettings, isNull);
    await openFilters();
    final snapshotSwitch = find.byKey(
      const Key('llm-hide-snapshots-purpose-questionGeneration'),
    );
    await tester.tap(snapshotSwitch);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: filterButton,
        matching: find.byIcon(Icons.filter_alt_outlined),
      ),
      findsOneWidget,
    );
    expect(visible(), contains('gpt-6-luna-test-snapshot'));
    await tester.ensureVisible(modelFinder);
    await tester.tap(modelFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('gpt-5-mini').last);
    await tester.pumpAndSettle();
    await openFilters();
    await tester.tap(oldSwitch);
    await tester.pumpAndSettle();
    expect(visible(), contains('gpt-5-mini'));
    expect(visible(), isNot(contains('gpt-4o-mini')));
    expect(find.textContaining('현재 선택한 모델은 구형 모델입니다.'), findsWidgets);
    // Both the model choice and display preference now persist automatically.
    await tester.tap(find.byTooltip('뒤로가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    await openFilters();
    expect(tester.widget<CheckedPopupMenuItem>(oldSwitch).checked, isTrue);
    expect(
      tester.widget<CheckedPopupMenuItem>(snapshotSwitch).checked,
      isFalse,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(visible(), [
      'gpt-5-mini',
      'gpt-6-luna',
      'gpt-6-luna-test-snapshot',
      'gpt-7-future',
    ]);
    expect(
      modelFilterStore.preferences.forProvider('ollama').hideSnapshots,
      isTrue,
    );
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpAndSettle();
    await openFilters();
    expect(tester.widget<CheckedPopupMenuItem>(oldSwitch).checked, isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('필터 저장 실패 시 이전 값으로 복구하고 오류를 표시한다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'test-token',
    );
    modelFilterStore.failWrites = true;
    await tester.pumpWidget(
      buildApp(llmProfileApi: _FakeLlmProfileApi(openAi: true)),
    );
    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('llm-profiles-settings-tile')));
    await tester.pumpAndSettle();
    final filterButton = find.byKey(
      const Key('llm-model-filter-purpose-questionGeneration'),
    );
    await tester.ensureVisible(filterButton);
    await tester.pumpAndSettle();
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    final oldSwitch = find.byKey(
      const Key('llm-hide-old-purpose-questionGeneration'),
    );
    await tester.tap(oldSwitch);
    await tester.pumpAndSettle();
    expect(find.text('모델 필터 설정을 저장하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('acknowledge-app-error')));
    await tester.pumpAndSettle();
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckedPopupMenuItem>(oldSwitch).checked, isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
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

  testWidgets(
    '문제 관리와 폴더 헤더의 문제 추가 아이콘은 없고 문제 영역 버튼은 유지한다',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await DriftFolderRepository(database).createFolder(name: '전자기학');
      await tester.pumpWidget(buildApp());

      await tester.tap(find.text('문제 관리'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('문제 추가'), findsNothing);
      expect(tester.widget<AppBar>(find.byType(AppBar)).actions, isNull);

      await tester.tap(find.text('전자기학'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('문제 추가'), findsNothing);
      expect(tester.widget<AppBar>(find.byType(AppBar)).actions, isNull);
      expect(find.byKey(const Key('add-question-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

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
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-question-button')));
    await tester.pumpAndSettle();
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

    await tester.ensureVisible(find.byKey(const Key('ai-count-mode-manual')));
    await tester.pumpAndSettle();
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

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('${platform.name}에서 PDF와 문제를 검색한 하위 폴더로 이동한다', (tester) async {
      await tester.binding.setSurfaceSize(
        Size(platform == TargetPlatform.windows ? 800 : 390, 1000),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final folders = DriftFolderRepository(database);
      final originId = await folders.createFolder(name: '원래 폴더');
      final archiveId = await folders.createFolder(name: '보관함');
      final targetId = await folders.createFolder(
        name: '복습',
        parentId: archiveId,
      );
      final sources = DriftSourceRepository(database);
      await sources.saveImport(
        folderId: originId,
        result: DocumentImportResult(
          source: ImportedSource(
            id: 'moving-pdf',
            fileName: '이동 테스트.pdf',
            contentHash: List.filled(64, 'a').join(),
            pageCount: 1,
            extractionMethod: 'textLayer',
            importedAt: DateTime.utc(2026, 9, 19),
          ),
          concepts: const [
            ImportedConcept(title: '개념', content: '학습 내용', pageNumbers: [1]),
          ],
        ),
      );
      final questions = DriftQuestionRepository(database);
      final questionId = await questions.createQuestion(
        QuestionDraft(
          folderId: originId,
          type: QuestionType.shortAnswer,
          prompt: '이동할 문제',
          acceptableAnswers: const ['정답'],
        ),
      );
      final pendingBefore = await database.syncDao.getPendingCount();
      await tester.pumpWidget(buildApp());
      await tester.tap(find.text('문제 관리'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('원래 폴더'));
      await tester.pumpAndSettle();

      Future<void> openMove(String menuKey) async {
        final menu = find.byKey(Key(menuKey));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('이동'));
        await tester.pumpAndSettle();
      }

      Future<void> chooseTarget() async {
        expect(find.byKey(const Key('folder-picker-root-item')), findsNothing);
        await tester.enterText(
          find.byKey(const Key('folder-picker-search-field')),
          '보관함',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('folder-picker-item-$targetId')));
        await tester.pumpAndSettle();
      }

      await openMove('pdf-source-menu-moving-pdf');
      expect(find.text('자료 이동'), findsOneWidget);
      expect(
        find.byType(platform == TargetPlatform.windows ? Dialog : BottomSheet),
        findsOneWidget,
      );
      // Closing the picker must not move anything or enqueue a sync change.
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(find.text('이동 테스트.pdf'), findsOneWidget);
      expect(await database.syncDao.getPendingCount(), pendingBefore);

      await openMove('pdf-source-menu-moving-pdf');
      await chooseTarget();
      expect(find.text('이동 테스트.pdf'), findsNothing);
      expect(
        find.text('이 폴더에 자료가 없어요. 새 자료를 만들거나 PDF를 가져와 주세요.'),
        findsOneWidget,
      );
      expect(find.text('이동할 문제'), findsOneWidget);
      expect(
        (await sources.getSourceWithConcepts('moving-pdf')).source.folderId,
        targetId,
      );
      expect((await questions.getQuestion(questionId))!.folderId, originId);

      await openMove('question-menu-$questionId');
      expect(find.text('문제 이동'), findsOneWidget);
      await chooseTarget();
      expect(find.text('이동할 문제'), findsNothing);
      expect(find.text('이 폴더에 저장된 문제가 없어요.'), findsOneWidget);
      expect((await questions.getQuestion(questionId))!.folderId, targetId);

      await tester.tap(find.byTooltip('뒤로가기'));
      await tester.pumpAndSettle();
      expect(find.text('하위 폴더 0개, 문제 0개, 자료 0개'), findsOneWidget);
      await tester.tap(find.text('보관함'));
      await tester.pumpAndSettle();
      expect(find.text('하위 폴더 0개, 문제 1개, 자료 1개'), findsOneWidget);
      await tester.tap(find.text('복습'));
      await tester.pumpAndSettle();
      expect(find.text('이동 테스트.pdf'), findsOneWidget);
      expect(find.text('이동할 문제'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('다른 폴더가 없으면 이동 대신 폴더 생성 안내를 표시한다', (tester) async {
    final folderId = await DriftFolderRepository(database)
        .createFolder(name: '유일한 폴더');
    final questionId = await DriftQuestionRepository(database).createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        prompt: '문제',
        acceptableAnswers: const ['정답'],
      ),
    );
    final pendingBefore = await database.syncDao.getPendingCount();
    await tester.pumpWidget(buildApp());
    await tester.tap(find.text('문제 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('유일한 폴더'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(Key('question-menu-$questionId')));
    await tester.tap(find.byKey(Key('question-menu-$questionId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이동'));
    await tester.pumpAndSettle();
    expect(find.text('이동할 다른 폴더를 먼저 만들어 주세요.'), findsOneWidget);
    expect(find.byKey(const Key('folder-picker-search-field')), findsNothing);
    expect(await database.syncDao.getPendingCount(), pendingBefore);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('자료를 문제보다 먼저 표시하고 이름 변경 메뉴를 사용한다', (tester) async {
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
    expect(find.text('하위 폴더 0개, 문제 0개, 자료 1개'), findsOneWidget);
    await tester.tap(find.text('전자기학'));
    await tester.pumpAndSettle();

    expect(find.text('자료'), findsOneWidget);
    expect(find.text('1주차.pdf'), findsOneWidget);
    expect(find.byTooltip('자료 메뉴'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('자료')).dy,
      lessThan(tester.getTopLeft(find.text('문제')).dy),
    );

    await tester.tap(find.byTooltip('자료 메뉴'));
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
    expect(find.text('검토 필요'), findsNWidgets(2));
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
    final reviewedBadgeText = find.descendant(
      of: find.byKey(ValueKey('concept-status-$firstConceptId')),
      matching: find.text('검토 완료'),
    );
    await tester.tap(find.byKey(ValueKey('concept-approval-$firstConceptId')));
    await tester.pumpAndSettle();
    expect(reviewedBadgeText, findsOneWidget);
    final approvedBadge = tester.widget<Chip>(
      find
          .descendant(
            of: find.byKey(ValueKey('concept-status-$firstConceptId')),
            matching: find.byType(Chip),
          )
          .first,
    );
    final badgeTheme = Theme.of(tester.element(reviewedBadgeText));
    expect(approvedBadge.backgroundColor, badgeTheme.cardTheme.color);
    expect(
      approvedBadge.labelStyle!.color,
      badgeTheme.brightness == Brightness.dark
          ? const Color(0xFFC5E1A5)
          : const Color(0xFF4E6B38),
    );

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
    expect(reviewedBadgeText, findsOneWidget);
    expect(find.text('적용'), findsOneWidget);

    await tester.tap(find.byKey(const Key('apply-concept-revisions-button')));
    await tester.pumpAndSettle();

    expect(reviewedBadgeText, findsNothing);
    expect(find.text('검토 필요'), findsNWidgets(2));
    expect(find.text('1개 변경을 적용했어요. 추가·수정 개념은 검토 필요 상태예요.'), findsOneWidget);
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
    await tester.ensureVisible(
      find.byKey(const Key('generate-ai-questions-button')),
    );
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(
      find.byKey(const Key('generate-ai-questions-button')),
    );
    await tester.pumpAndSettle();
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

class _FakeLlmProfileApi implements LlmProfileApi {
  _FakeLlmProfileApi({
    this.openAi = false,
    this.openAiModel = 'gpt-5-mini',
    this.initialSettings,
  });

  final LlmProfileSettings? initialSettings;

  final bool openAi;
  final String openAiModel;
  bool failWrites = false;
  Completer<void>? saveGate;
  int saveCalls = 0;
  Map<LlmApiKeyProvider, String>? savedApiKeys;
  LlmProfileSettings? savedSettings;

  LlmProfileSettings get _settings => LlmProfileSettings(
    profiles: [
      LlmProfile(
        id: 'default',
        name: '기본 프로필',
        provider: openAi ? LlmProviderKind.openAi : LlmProviderKind.ollama,
        model: openAi ? openAiModel : 'qwen3-vl:8b-instruct',
        updatedAt: DateTime.utc(2026),
      ),
    ],
    assignments: {for (final purpose in LlmPurpose.values) purpose: 'default'},
    apiKeyConfigured: {
      LlmApiKeyProvider.openAi: true,
      LlmApiKeyProvider.gemini: false,
      LlmApiKeyProvider.claude: false,
    },
  );

  @override
  Future<LlmProfileSettings> getSettings(
    SyncConfiguration configuration,
  ) async => savedSettings ?? initialSettings ?? _settings;

  @override
  Future<LlmModelCatalog> getModels({
    required SyncConfiguration configuration,
    required LlmProviderKind provider,
  }) async => LlmModelCatalog(
    provider: provider,
    models: provider == LlmProviderKind.ollama
        ? const ['qwen3-vl:8b-instruct']
        : const [
            'gpt-5-mini',
            'gpt-6-luna',
            'gpt-6-luna-test-snapshot',
            'o3-pro',
            'gpt-4o-mini',
            'gpt-7-future',
          ],
    refreshedAt: DateTime.utc(2026),
    contextWindows: provider == LlmProviderKind.ollama
        ? const {'qwen3-vl:8b-instruct': 40960}
        : const {},
    modelCapabilities: provider == LlmProviderKind.openAi
        ? const {
            'gpt-5-mini': LlmModelCapabilities(
              isKnown: true,
              reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
              defaultReasoningEffort: 'medium',
            ),
            'gpt-4o-mini': LlmModelCapabilities(
              isKnown: true,
              reasoningEfforts: [],
            ),
            'gpt-6-luna': LlmModelCapabilities(
              isKnown: true,
              supportsReasoning: true,
              reasoningEfforts: [
                'none',
                'low',
                'medium',
                'high',
                'xhigh',
                'max',
              ],
              defaultReasoningEffort: 'medium',
            ),
            'gpt-6-luna-test-snapshot': LlmModelCapabilities(
              isKnown: true,
              reasoningEfforts: [],
            ),
            'o3-pro': LlmModelCapabilities(
              isKnown: true,
              supportsReasoning: true,
              reasoningEfforts: [],
            ),
            'gpt-7-future': LlmModelCapabilities(
              isKnown: false,
              reasoningEfforts: [],
            ),
          }
        : const {},
    modelMetadata: provider == LlmProviderKind.openAi
        ? const {
            'gpt-5-mini': LlmModelMetadata(lifecycle: LlmModelLifecycle.legacy),
            'gpt-4o-mini': LlmModelMetadata(
              lifecycle: LlmModelLifecycle.legacy,
            ),
            'o3-pro': LlmModelMetadata(lifecycle: LlmModelLifecycle.legacy),
            'gpt-6-luna': LlmModelMetadata(
              lifecycle: LlmModelLifecycle.current,
            ),
            'gpt-6-luna-test-snapshot': LlmModelMetadata(
              lifecycle: LlmModelLifecycle.current,
              isSnapshot: true,
            ),
          }
        : const {},
  );

  @override
  Future<LlmProfileSettings> updateSettings({
    required SyncConfiguration configuration,
    required LlmProfileSettings settings,
    Map<LlmApiKeyProvider, String> apiKeys = const {},
  }) async {
    saveCalls++;
    if (failWrites) throw const NetworkFailure('테스트 서버 저장 실패');
    await saveGate?.future;
    savedApiKeys = Map.of(apiKeys);
    final updated = LlmProfileSettings(
      profiles: [
        for (final profile in settings.profiles)
          LlmProfile(
            id: profile.id,
            name: profile.name,
            provider: profile.provider,
            model: profile.model,
            contextWindowTokens: profile.contextWindowTokens,
            reasoningEffort: profile.reasoningEffort,
            maximumQuestionsPerRequest: profile.maximumQuestionsPerRequest,
            updatedAt: DateTime.utc(2026).add(Duration(seconds: saveCalls)),
          ),
      ],
      assignments: settings.assignments,
      apiKeyConfigured: {
        ...settings.apiKeyConfigured,
        for (final provider in apiKeys.keys) provider: true,
      },
    );
    savedSettings = updated;
    return updated;
  }
}

class _RefreshingLlmProfileApi extends _FakeLlmProfileApi {
  _RefreshingLlmProfileApi({super.openAi});

  Completer<void>? modelGate;
  int _revision = 0;

  @override
  Future<LlmModelCatalog> getModels({
    required SyncConfiguration configuration,
    required LlmProviderKind provider,
  }) async {
    await modelGate?.future;
    final catalog = await super.getModels(
      configuration: configuration,
      provider: provider,
    );
    return LlmModelCatalog(
      provider: catalog.provider,
      models: catalog.models,
      contextWindows: catalog.contextWindows,
      modelCapabilities: catalog.modelCapabilities,
      modelMetadata: catalog.modelMetadata,
      refreshedAt: catalog.refreshedAt.add(Duration(seconds: ++_revision)),
    );
  }
}

class _MemoryLlmModelFilterStore implements LlmModelFilterStore {
  LlmModelFilterPreferences preferences = const LlmModelFilterPreferences();
  bool failWrites = false;
  @override
  Future<LlmModelFilterPreferences> read() async => preferences;
  @override
  Future<void> write(LlmModelFilterPreferences value) async {
    if (failWrites) throw StateError('Test write failure');
    preferences = value;
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
    bool allowAdditions = false,
    bool allowDeletions = false,
  }) async {
    capturedConcepts = List.of(concepts);
    capturedInstruction = instruction;
    capturedTargetConceptIds = Set.of(targetConceptIds);
    return [revision];
  }
}
