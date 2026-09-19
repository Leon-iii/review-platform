import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://127.0.0.1:5080/',
    accessToken: 'private-token',
  );

  test('생성 요청과 토큰을 전송하고 Draft 문제를 파싱한다', () async {
    late http.Request captured;
    final api = HttpRemoteAiApi(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'metadata': {
              'generationId': 'generation-1',
              'provider': 'openai',
              'model': 'test-model',
              'promptVersion': 'question-generation-v1',
              'requestedAt': '2026-09-17T00:00:00Z',
              'inputHash': List.filled(64, 'a').join(),
              'sourceLabel': '전자기학',
            },
            'questions': [
              {
                'type': 'shortAnswer',
                'status': 'draft',
                'prompt': '가우스 법칙이란?',
                'choices': [],
                'acceptableAnswers': ['폐곡면의 선속과 내부 전하의 관계'],
                'explanation': '정의 확인 문제',
                'difficulty': 2,
                'sourceIds': [],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await api.generateQuestions(
      configuration: configuration,
      request: const AiQuestionGenerationRequest(
        sourceText: '가우스 법칙에 관한 충분히 긴 학습 내용',
        questionCount: 1,
        questionTypes: {QuestionType.shortAnswer},
        sourceLabel: '전자기학',
      ),
    );

    expect(captured.url.path, '/api/ai/questions/generate');
    expect(captured.headers['x-sync-token'], 'private-token');
    expect(jsonDecode(captured.body)['questionTypes'], ['shortAnswer']);
    expect(result.metadata.provider, 'openai');
    expect(result.questions.single.type, QuestionType.shortAnswer);
    expect(result.questions.single.acceptableAnswers, hasLength(1));
  });

  test('서버의 안전한 오류 메시지를 사용자에게 전달한다', () async {
    final api = HttpRemoteAiApi(
      MockClient(
        (request) async => http.Response(
          jsonEncode({'error': 'OPENAI_API_KEY가 설정되지 않았습니다.'}),
          503,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      api.generateQuestions(
        configuration: configuration,
        request: const AiQuestionGenerationRequest(
          sourceText: '충분히 긴 학습 내용입니다.',
          questionCount: 1,
          questionTypes: {QuestionType.shortAnswer},
        ),
      ),
      throwsA(
        isA<NetworkFailure>().having(
          (failure) => failure.message,
          'message',
          contains('OPENAI_API_KEY'),
        ),
      ),
    );
  });

  test('O/X 생성 요청과 응답을 직렬화한다', () async {
    late http.Request captured;
    final api = HttpRemoteAiApi(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'metadata': {
              'generationId': 'generation-2',
              'provider': 'ollama',
              'model': 'test-model',
              'promptVersion': 'question-generation-v2-grounded',
              'requestedAt': '2026-09-18T00:00:00Z',
              'inputHash': List.filled(64, 'b').join(),
              'sourceLabel': null,
            },
            'questions': [
              {
                'type': 'trueFalse',
                'status': 'draft',
                'prompt': '지구는 태양 주위를 돈다.',
                'choices': [
                  {'text': 'O', 'isCorrect': true},
                  {'text': 'X', 'isCorrect': false},
                ],
                'acceptableAnswers': [],
                'explanation': null,
                'difficulty': 1,
                'sourceIds': ['provided-source'],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await api.generateQuestions(
      configuration: configuration,
      request: const AiQuestionGenerationRequest(
        sourceText: '지구는 태양 주위를 공전한다는 충분히 긴 학습 내용',
        questionCount: 1,
        questionTypes: {QuestionType.trueFalse},
      ),
    );

    expect(jsonDecode(captured.body)['questionTypes'], ['trueFalse']);
    expect(result.questions.single.type, QuestionType.trueFalse);
    expect(result.questions.single.choices.map((choice) => choice.text), [
      'O',
      'X',
    ]);
  });

  test('자동 생성 모드와 개념별 생성량을 전송한다', () async {
    late http.Request captured;
    final api = HttpRemoteAiApi(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'metadata': {
              'generationId': 'generation-3',
              'provider': 'ollama',
              'model': 'test-model',
              'promptVersion': 'question-generation-v3-auto-density',
              'requestedAt': '2026-09-18T00:00:00Z',
              'inputHash': List.filled(64, 'c').join(),
              'sourceLabel': null,
            },
            'questions': [
              {
                'type': 'shortAnswer',
                'status': 'draft',
                'prompt': '핵심 개념은?',
                'choices': [],
                'acceptableAnswers': ['정답'],
                'explanation': null,
                'difficulty': 1,
                'sourceIds': ['provided-source'],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await api.generateQuestions(
      configuration: configuration,
      request: const AiQuestionGenerationRequest(
        sourceText: '자동 문제 생성을 위한 충분히 긴 학습 내용입니다.',
        questionTypes: {QuestionType.shortAnswer},
        generationMode: AiQuestionGenerationMode.automatic,
        automaticDensity: AiQuestionDensity.high,
        questionCount: null,
      ),
    );

    final body = jsonDecode(captured.body) as Map<String, Object?>;
    expect(body['generationMode'], 'automatic');
    expect(body['automaticDensity'], 'high');
    expect(body['questionCount'], isNull);
  });
}
