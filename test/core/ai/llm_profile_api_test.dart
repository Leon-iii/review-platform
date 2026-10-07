import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/ai/llm_profile_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://192.168.0.10:5080',
    accessToken: 'test-token',
  );

  test('서버의 용도별 LLM 프로필 설정을 해석한다', () async {
    final api = HttpLlmProfileApi(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/llm/settings');
        expect(request.headers['x-sync-token'], 'test-token');
        return _response();
      }),
    );

    final settings = await api.getSettings(configuration);

    expect(settings.profiles, hasLength(2));
    expect(settings.profiles.first.provider, LlmProviderKind.ollama);
    expect(settings.profiles.first.contextWindowTokens, 32768);
    expect(settings.profiles.last.contextWindowTokens, isNull);
    expect(settings.profiles.first.reasoningEffort, isNull);
    expect(settings.profiles.last.reasoningEffort, 'high');
    expect(settings.profiles.first.maximumQuestionsPerRequest, 45);
    expect(settings.profiles.last.maximumQuestionsPerRequest, 120);
    expect(
      settings.forPurposes().profiles.first.maximumQuestionsPerRequest,
      45,
    );
    expect(
      settings.assignments[LlmPurpose.questionGeneration],
      'question-profile',
    );
    expect(
      settings.assignments[LlmPurpose.conceptExtraction],
      'concept-profile',
    );
    expect(
      settings.assignments[LlmPurpose.conceptRevision],
      'question-profile',
    );
    expect(settings.apiKeyConfigured[LlmApiKeyProvider.openAi], isTrue);
    expect(settings.apiKeyConfigured[LlmApiKeyProvider.gemini], isFalse);
    expect(settings.apiKeyConfigured[LlmApiKeyProvider.claude], isFalse);
  });

  test('변경한 프로필과 용도 할당을 PUT으로 저장한다', () async {
    late Map<String, Object?> requestBody;
    final api = HttpLlmProfileApi(
      MockClient((request) async {
        expect(request.method, 'PUT');
        requestBody = Map<String, Object?>.from(
          jsonDecode(request.body) as Map,
        );
        return _response();
      }),
    );
    final settings = LlmProfileSettings(
      profiles: [
        LlmProfile(
          id: 'question-profile',
          name: '문제 생성',
          provider: LlmProviderKind.ollama,
          model: 'qwen3:4b',
          contextWindowTokens: 16384,
          maximumQuestionsPerRequest: 101,
          updatedAt: DateTime.utc(2026),
        ),
        LlmProfile(
          id: 'concept-profile',
          name: '개념 추출',
          provider: LlmProviderKind.openAi,
          model: 'gpt-test',
          reasoningEffort: 'high',
          updatedAt: DateTime.utc(2026),
        ),
      ],
      assignments: const {
        LlmPurpose.questionGeneration: 'question-profile',
        LlmPurpose.conceptExtraction: 'concept-profile',
        LlmPurpose.conceptRevision: 'question-profile',
      },
      apiKeyConfigured: const {
        LlmApiKeyProvider.openAi: true,
        LlmApiKeyProvider.gemini: false,
        LlmApiKeyProvider.claude: false,
      },
    );

    await api.updateSettings(
      configuration: configuration,
      settings: settings,
      apiKeys: const {
        LlmApiKeyProvider.gemini: 'gemini-secret',
        LlmApiKeyProvider.claude: 'claude-secret',
      },
    );

    final assignments = Map<String, Object?>.from(
      requestBody['assignments']! as Map,
    );
    expect(assignments['questionGeneration'], 'question-profile');
    expect(assignments['conceptExtraction'], 'concept-profile');
    expect(assignments['conceptRevision'], 'question-profile');
    expect(assignments.containsKey('documentVision'), isFalse);
    final apiKeys = Map<String, Object?>.from(requestBody['apiKeys']! as Map);
    expect(apiKeys['gemini'], 'gemini-secret');
    expect(apiKeys['claude'], 'claude-secret');
    expect(apiKeys.containsKey('openai'), isFalse);
    final profiles = requestBody['profiles']! as List;
    expect((profiles.first as Map).containsKey('baseUrl'), isFalse);
    expect((profiles.first as Map)['contextWindowTokens'], 16384);
    expect((profiles.last as Map)['contextWindowTokens'], isNull);
    expect((profiles.last as Map)['reasoningEffort'], 'high');
    expect((profiles.first as Map)['reasoningEffort'], isNull);
    expect((profiles.first as Map)['maximumQuestionsPerRequest'], 101);
    expect((profiles.last as Map)['maximumQuestionsPerRequest'], 120);
  });

  test('Provider별 모델 목록을 서버에서 불러온다', () async {
    final api = HttpLlmProfileApi(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/llm/models');
        expect(request.url.queryParameters['provider'], 'ollama');
        return http.Response(
          jsonEncode({
            'provider': 'ollama',
            'models': ['qwen3:8b', 'qwen3-vl:8b-instruct'],
            'refreshedAt': '2026-09-30T00:00:00Z',
            'contextWindows': {'qwen3:8b': 40960},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final catalog = await api.getModels(
      configuration: configuration,
      provider: LlmProviderKind.ollama,
    );

    expect(catalog.provider, LlmProviderKind.ollama);
    expect(catalog.models, ['qwen3:8b', 'qwen3-vl:8b-instruct']);
    expect(catalog.contextWindows['qwen3:8b'], 40960);
  });

  test('모델 목록 오류의 서버 안내 문구를 그대로 전달한다', () async {
    final api = HttpLlmProfileApi(
      MockClient(
        (request) async => http.Response(
          jsonEncode({'error': 'OpenAI API Key가 서버에 저장되지 않았습니다.'}),
          503,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      api.getModels(
        configuration: configuration,
        provider: LlmProviderKind.openAi,
      ),
      throwsA(
        isA<NetworkFailure>().having(
          (error) => error.message,
          'message',
          contains('OpenAI API Key'),
        ),
      ),
    );
  });

  test('OpenAI 지원 정보 등록 여부와 추론 선택지를 해석한다', () async {
    final api = HttpLlmProfileApi(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'provider': 'openai',
            'models': ['gpt-5-mini', 'gpt-7-future'],
            'refreshedAt': '2026-10-01T00:00:00Z',
            'modelMetadata': {
              'gpt-5-mini': {'lifecycle': 'legacy', 'isSnapshot': false},
              'gpt-7-future': {'lifecycle': 'unknown', 'isSnapshot': false},
            },
            'modelCapabilities': {
              'gpt-5-mini': {
                'isKnown': true,
                'reasoningEfforts': ['minimal', 'low', 'medium', 'high'],
                'defaultReasoningEffort': 'medium',
                'supportsReasoning': true,
              },
              'gpt-7-future': {'isKnown': false, 'reasoningEfforts': []},
            },
          }),
          200,
        ),
      ),
    );
    final catalog = await api.getModels(
      configuration: configuration,
      provider: LlmProviderKind.openAi,
    );
    expect(catalog.isUnregistered('gpt-5-mini'), isFalse);
    expect(catalog.isUnregistered('gpt-7-future'), isTrue);
    expect(catalog.isUnregistered('removed-model'), isFalse);
    expect(
      catalog.modelMetadata['gpt-5-mini']!.lifecycle,
      LlmModelLifecycle.legacy,
    );
    expect(
      catalog.modelMetadata['gpt-7-future']!.lifecycle,
      LlmModelLifecycle.unknown,
    );
    expect(catalog.modelCapabilities['gpt-5-mini']!.supportsReasoning, isTrue);
    expect(
      catalog.modelCapabilities['gpt-7-future']!.supportsReasoning,
      isFalse,
    );
    expect(catalog.modelCapabilities['gpt-5-mini']!.reasoningEfforts, [
      'minimal',
      'low',
      'medium',
      'high',
    ]);
  });
}

http.Response _response() => http.Response(
  jsonEncode({
    'profiles': [
      {
        'id': 'question-profile',
        'name': '문제 생성',
        'provider': 'ollama',
        'model': 'qwen3:4b',
        'contextWindowTokens': 32768,
        'maximumQuestionsPerRequest': 45,
        'updatedAt': '2026-09-19T00:00:00Z',
      },
      {
        'id': 'concept-profile',
        'name': '개념 추출',
        'provider': 'openai',
        'model': 'gpt-test',
        'reasoningEffort': 'high',
        'updatedAt': '2026-09-19T00:00:00Z',
      },
    ],
    'assignments': {
      'questionGeneration': 'question-profile',
      'conceptExtraction': 'concept-profile',
      'conceptRevision': 'question-profile',
      'documentVision': 'question-profile',
    },
    'apiKeyConfigured': {'openai': true, 'gemini': false, 'claude': false},
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
