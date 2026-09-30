import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/ai/llm_profile_api.dart';
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
    expect(
      settings.assignments[LlmPurpose.questionGeneration],
      'question-profile',
    );
    expect(
      settings.assignments[LlmPurpose.conceptExtraction],
      'concept-profile',
    );
    expect(settings.assignments[LlmPurpose.documentVision], 'question-profile');
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
          updatedAt: DateTime.utc(2026),
        ),
        LlmProfile(
          id: 'concept-profile',
          name: '개념 추출',
          provider: LlmProviderKind.openAi,
          model: 'gpt-test',
          updatedAt: DateTime.utc(2026),
        ),
      ],
      assignments: const {
        LlmPurpose.questionGeneration: 'question-profile',
        LlmPurpose.conceptExtraction: 'concept-profile',
        LlmPurpose.documentVision: 'question-profile',
      },
    );

    await api.updateSettings(configuration: configuration, settings: settings);

    final assignments = Map<String, Object?>.from(
      requestBody['assignments']! as Map,
    );
    expect(assignments['questionGeneration'], 'question-profile');
    expect(assignments['conceptExtraction'], 'concept-profile');
    expect(assignments['documentVision'], 'question-profile');
    final profiles = requestBody['profiles']! as List;
    expect((profiles.first as Map).containsKey('baseUrl'), isFalse);
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
        'updatedAt': '2026-09-19T00:00:00Z',
      },
      {
        'id': 'concept-profile',
        'name': '개념 추출',
        'provider': 'openai',
        'model': 'gpt-test',
        'updatedAt': '2026-09-19T00:00:00Z',
      },
    ],
    'assignments': {
      'questionGeneration': 'question-profile',
      'conceptExtraction': 'concept-profile',
      'documentVision': 'question-profile',
    },
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
