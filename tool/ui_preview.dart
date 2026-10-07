// Isolated UI verification: memory-only data/configuration, no real API calls.
// Run: flutter run -d windows -t tool/ui_preview.dart
import 'package:drift/native.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/app/app.dart';
import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/ai/llm_profile_api.dart';
import 'package:review_platform/core/ai/llm_model_filter_store.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/server/local_server_config.dart';
import 'package:review_platform/core/server/local_server_providers.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/domain/models/llm_model_filter.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/repositories/source_repository.dart';

import '../test/support/fake_ai.dart';
import '../test/support/fake_pdf_jobs.dart';
import '../test/support/fake_pdf_extraction.dart';
import '../test/support/fake_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(_PreviewBootstrap());
}

class _PreviewBootstrap extends StatelessWidget {
  _PreviewBootstrap();
  final Future<UiPreviewFixture> fixture = createUiPreviewFixture();
  @override
  Widget build(BuildContext context) => FutureBuilder<UiPreviewFixture>(
    future: fixture,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return UncontrolledProviderScope(
          container: snapshot.data!.container,
          child: const ReviewApp(),
        );
      }
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? SelectableText('검증 데이터 준비 실패: ${snapshot.error}')
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

/// Shared synthetic data for native visual checks and responsive route tests.
Future<UiPreviewFixture> createUiPreviewFixture({
  QuestionRepository Function(AppDatabase)? questionRepository,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  final folder = await DriftFolderRepository(db)
      .createFolder(name: 'UI 검증 · 컴퓨터 네트워크');
  await DriftFolderRepository(db).createFolder(name: '하위 폴더', parentId: folder);
  final sources = DriftSourceRepository(db);
  final source = await sources.createSource(
    folderId: folder,
    name: '웹 캐시와 인터넷 프로토콜 학습자료',
  );
  final concept = await sources.addConcept(
    sourceId: source.source.id,
    title: '웹 캐시의 동작과 캐시 히트·미스',
    content: '웹 캐시는 클라이언트 가까이에서 응답을 제공하는 중개자이다. 요청한 객체가 있으면 캐시 히트이고, 없으면 캐시 미스이다.\n캐시 미스 시 원본 서버에서 객체를 받아 저장한 후 클라이언트에게 반환한다.',
    importance: ConceptImportance.high,
  );
  await sources.addConcept(
    sourceId: source.source.id,
    title: '긴 개념 제목 · 네트워크에서 요청과 응답을 주고받을 때의 클라이언트와 서버 역할',
    content: '한 시스템은 다른 시스템과의 관계에 따라 서버이면서 클라이언트일 수 있다.',
    reviewed: false,
  );
  final questionIds = <String>[];
  for (final type in QuestionType.values) {
    questionIds.add(
      await DriftQuestionRepository(db).createQuestion(
        QuestionDraft(
          folderId: folder,
          type: type,
          prompt: type == QuestionType.trueFalse
              ? '캐시에 객체가 있으면 캐시 히트이다.'
              : '캐시에 객체가 존재해 원본 서버 호출 없이 반환하는 동작을 무엇이라 하는가?',
          explanation: '캐시 히트는 저장된 객체를 바로 반환하는 경우이다. 캐시 미스와 구별해라.',
          acceptableAnswers:
              type == QuestionType.shortAnswer || type == QuestionType.essay
              ? const ['캐시 히트', 'cache hit']
              : const [],
          choices:
              type == QuestionType.multipleChoice ||
                  type == QuestionType.trueFalse
              ? [
                  QuestionChoiceDraft(
                    text: type == QuestionType.trueFalse ? 'O' : '캐시 히트',
                    isCorrect: true,
                  ),
                  QuestionChoiceDraft(
                    text: type == QuestionType.trueFalse ? 'X' : '캐시 미스',
                    isCorrect: false,
                  ),
                ]
              : const [],
        ),
        primaryConceptId: concept.id,
      ),
    );
  }
  final secrets = _PreviewSecrets();
  final pdfApi = FakePdfExtractionApi();
  // A valid synthetic PNG: the legacy fake's malformed CRC is accepted by
  // widget tests but rejected by the native Windows image decoder.
  pdfApi.previewBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY/j///9/AAn7A/0FQ0XKAAAAAElFTkSuQmCC',
  );
  final pdf = await sources.saveImport(
    folderId: folder,
    result: pdfResult('preview-pdf'),
  );
  pdfApi.jobs[pdf.source.id] = pdfJob(pdf.source.id, status: 'completed');
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      if (questionRepository != null)
        questionRepositoryProvider.overrideWithValue(questionRepository(db)),
      syncCredentialsStoreProvider.overrideWithValue(
        MemorySyncCredentialsStore(
          configuration: const SyncConfiguration(
            serverUrl: 'http://ui-preview.invalid',
            accessToken: 'synthetic-preview-token',
          ),
        ),
      ),
      remoteSyncApiProvider.overrideWithValue(FakeRemoteSyncApi()),
      remoteAiApiProvider.overrideWithValue(FakeRemoteAiApi()),
      remoteDocumentApiProvider.overrideWithValue(pdfApi),
      llmProfileApiProvider.overrideWithValue(_PreviewProfiles()),
      llmModelFilterStoreProvider.overrideWithValue(_PreviewFilters()),
      localServerConfigStoreProvider.overrideWithValue(_PreviewConfig()),
      localServerSecretStoreProvider.overrideWithValue(secrets),
      localServerServiceProvider.overrideWithValue(
        LocalServerService(secretStore: secrets, isWindows: false),
      ),
    ],
  );
  return UiPreviewFixture(
    db,
    container,
    folder,
    source.source.id,
    pdf.source.id,
    questionIds,
  );
}

class UiPreviewFixture {
  UiPreviewFixture(
    this.database,
    this.container,
    this.folderId,
    this.sourceId,
    this.pdfId,
    this.questionIds,
  );
  final AppDatabase database;
  final ProviderContainer container;
  final String folderId;
  final String sourceId;
  final String pdfId;
  final List<String> questionIds;
  Future<void> dispose() async {
    container.dispose();
    await database.close();
  }
}

class _PreviewFilters implements LlmModelFilterStore {
  LlmModelFilterPreferences value = const LlmModelFilterPreferences();
  @override
  Future<LlmModelFilterPreferences> read() async => value;
  @override
  Future<void> write(LlmModelFilterPreferences preferences) async {
    value = preferences;
  }
}

class _PreviewConfig implements LocalServerConfigStore {
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

class _PreviewSecrets implements LocalServerSecretStore {
  @override
  Future<String?> read(LocalLlmProvider provider) async => null;
  @override
  Future<void> write(LocalLlmProvider provider, String value) async {}
}

class _PreviewProfiles implements LlmProfileApi {
  LlmProfileSettings value = LlmProfileSettings(
    profiles: [
      for (final p in LlmPurpose.values)
        LlmProfile(
          id: p.id,
          name: p.displayName,
          provider: LlmProviderKind.openAi,
          model: 'preview-model',
          updatedAt: DateTime.utc(2026),
        ),
    ],
    assignments: {for (final p in LlmPurpose.values) p: p.id},
    apiKeyConfigured: const {},
  );
  @override
  Future<LlmProfileSettings> getSettings(
    SyncConfiguration configuration,
  ) async => value;
  @override
  Future<LlmProfileSettings> updateSettings({
    required SyncConfiguration configuration,
    required LlmProfileSettings settings,
    Map<LlmApiKeyProvider, String> apiKeys = const {},
  }) async => value = settings;
  @override
  Future<LlmModelCatalog> getModels({
    required SyncConfiguration configuration,
    required LlmProviderKind provider,
  }) async => LlmModelCatalog(
    provider: provider,
    models: const ['preview-model'],
    refreshedAt: DateTime.utc(2026),
    modelCapabilities: const {
      'preview-model': LlmModelCapabilities(
        isKnown: true,
        reasoningEfforts: ['low', 'medium', 'high'],
        supportsReasoning: true,
      ),
    },
  );
}
