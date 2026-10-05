import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://localhost:5080',
    accessToken: 'token',
  );
  final concept = StudyConcept(
    id: 'one',
    sourceId: 'source',
    title: '캐시',
    content: '캐시 히트와 캐시 미스',
    pageNumbers: const [1],
    status: ConceptStatus.approved,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );
  AiQuestionGenerationRequest input() => AiQuestionGenerationRequest(
    sourceText: '전송하면 안 되는 기존 합친 텍스트',
    concepts: [concept],
    questionTypes: {QuestionType.shortAnswer},
  );
  final progressEvent = {
    'type': 'progress',
    'progress': {
      'completedConcepts': 1,
      'totalConcepts': 2,
      'generatedQuestions': 1,
      'failedConcepts': 1,
      'conceptTitle': '캐시',
    },
  };
  final result = {
    'metadata': {
      'generationId': 'job',
      'provider': 'openai',
      'model': 'mock',
      'promptVersion': 'v11',
      'requestedAt': '2026-10-05T00:00:00Z',
      'inputHash': 'hash',
      'sourceLabel': '자료',
    },
    'questions': [
      {
        'type': 'shortAnswer',
        'status': 'draft',
        'prompt': '캐시 히트란?',
        'choices': [],
        'acceptableAnswers': ['캐시에서 반환'],
        'difficulty': 1,
        'sourceIds': ['자료'],
        'primaryConceptId': 'one',
      },
    ],
    'failures': [
      {'conceptId': 'two', 'title': '다른 개념', 'error': '모의 요청 실패'},
    ],
  };

  test('구조화된 개념만 전송하고 UTF-8 분할 스트림의 진행률과 부분 결과를 읽는다', () async {
    final progress = <AiGenerationProgress>[];
    final bytes = utf8.encode(
      '${jsonEncode(progressEvent)}\n${jsonEncode({'type': 'complete', 'result': result})}\n',
    );
    final api = HttpRemoteAiApi(
      MockClient.streaming((request, body) async {
        expect(request.url.path, '/api/ai/questions/generate/stream');
        expect(request.headers['x-sync-token'], 'token');
        final sent =
            jsonDecode(await body.transform(utf8.decoder).join()) as Map;
        expect(sent.containsKey('sourceText'), false);
        expect((sent['concepts'] as List).single['id'], 'one');
        // Split through Korean multi-byte sequences as well as JSON/event boundaries.
        return http.StreamedResponse(
          Stream.fromIterable([
            for (var index = 0; index < bytes.length; index += 7)
              bytes.sublist(index, (index + 7).clamp(0, bytes.length)),
          ]),
          200,
        );
      }),
    );
    final response = await api.generateQuestions(
      configuration: configuration,
      request: input(),
      onProgress: progress.add,
    );
    expect(progress.single.completedConcepts, 1);
    expect(progress.single.totalConcepts, 2);
    expect(progress.single.conceptTitle, '캐시');
    expect(response.questions.single.primaryConceptId, 'one');
    expect(response.questions.single.difficulty, 1);
    expect(response.failures.single.conceptId, 'two');
  });

  for (final scenario in ['error', 'disconnect', 'unauthorized', 'malformed']) {
    test('진행 스트림 $scenario 실패를 사용자 오류로 전달한다', () async {
      final api = HttpRemoteAiApi(
        MockClient(
          (request) async => http.Response(
            switch (scenario) {
              'error' =>
                '${jsonEncode({'type': 'error', 'error': '모든 개념 실패'})}\n',
              'malformed' => '{not-json}\n',
              'unauthorized' => jsonEncode({'error': 'invalid token'}),
              _ => '${jsonEncode(progressEvent)}\n',
            },
            scenario == 'unauthorized' ? 401 : 200,
            headers: {'content-type': 'application/x-ndjson; charset=utf-8'},
          ),
        ),
      );
      await expectLater(
        api.generateQuestions(
          configuration: configuration,
          request: input(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<NetworkFailure>().having(
            (failure) => failure.message,
            'message',
            contains(switch (scenario) {
              'error' => '모든 개념 실패',
              'disconnect' => '완료 전에 끊어졌어요',
              'unauthorized' => '접근 토큰',
              _ => '진행 정보를 받지 못했어요',
            }),
          ),
        ),
      );
    });
  }

  test('진행 콜백이 없어도 개념 작업에는 전체 시간 제한 대신 스트림을 사용한다', () async {
    final api = HttpRemoteAiApi(
      MockClient((request) async {
        expect(request.url.path, '/api/ai/questions/generate/stream');
        return http.Response(
          '${jsonEncode({'type': 'complete', 'result': result})}\n',
          200,
          headers: {'content-type': 'application/x-ndjson; charset=utf-8'},
        );
      }),
    );
    final response = await api.generateQuestions(
      configuration: configuration,
      request: input(),
    );
    expect(response.questions, hasLength(1));
    expect(response.failures, hasLength(1));
  });
}
