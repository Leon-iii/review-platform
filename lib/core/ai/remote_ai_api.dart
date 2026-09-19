import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class RemoteAiApi {
  Future<AiQuestionGenerationResult> generateQuestions({
    required SyncConfiguration configuration,
    required AiQuestionGenerationRequest request,
  });
}

class HttpRemoteAiApi implements RemoteAiApi {
  HttpRemoteAiApi(this._client);

  final http.Client _client;

  @override
  Future<AiQuestionGenerationResult> generateQuestions({
    required SyncConfiguration configuration,
    required AiQuestionGenerationRequest request,
  }) async {
    http.Response response;
    try {
      response = await _client
          .post(
            _endpoint(configuration.serverUrl),
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'x-sync-token': configuration.accessToken,
            },
            body: jsonEncode(request.toJson()),
          )
          .timeout(const Duration(seconds: 100));
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('AI 문제 생성 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }

    final decoded = _decode(response);
    try {
      final metadata = Map<String, Object?>.from(decoded['metadata']! as Map);
      final questions = decoded['questions']! as List;
      return AiQuestionGenerationResult(
        metadata: AiGenerationMetadata(
          generationId: metadata['generationId']! as String,
          provider: metadata['provider']! as String,
          model: metadata['model']! as String,
          promptVersion: metadata['promptVersion']! as String,
          requestedAt: DateTime.parse(metadata['requestedAt']! as String)
              .toUtc(),
          inputHash: metadata['inputHash']! as String,
          sourceLabel: metadata['sourceLabel'] as String?,
        ),
        questions: [
          for (final raw in questions)
            _question(Map<String, Object?>.from(raw as Map)),
        ],
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('AI 문제 생성 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  AiGeneratedQuestion _question(Map<String, Object?> json) {
    if (json['status'] != 'draft') {
      throw const FormatException('Generated question is not a draft.');
    }
    final type = QuestionType.fromStorage(json['type']! as String);
    if (type == QuestionType.essay) {
      throw const FormatException('Essay generation is not supported.');
    }
    return AiGeneratedQuestion(
      type: type,
      prompt: json['prompt']! as String,
      choices: [
        for (final raw in json['choices']! as List)
          AiGeneratedChoice(
            text: (raw as Map)['text']! as String,
            isCorrect: raw['isCorrect']! as bool,
          ),
      ],
      acceptableAnswers: [
        for (final answer in json['acceptableAnswers']! as List)
          answer as String,
      ],
      explanation: json['explanation'] as String?,
      difficulty: (json['difficulty'] as num?)?.toInt(),
      sourceIds: [
        for (final sourceId in json['sourceIds']! as List) sourceId as String,
      ],
    );
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?>? body;
    try {
      body = Map<String, Object?>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const NetworkFailure('AI 문제 생성 응답 형식이 올바르지 않아요.');
      }
    }

    if (response.statusCode == 401) {
      throw const NetworkFailure('서버 접근 토큰이 올바르지 않아요.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverMessage = body?['error'];
      throw NetworkFailure(
        serverMessage is String && serverMessage.isNotEmpty
            ? serverMessage
            : 'AI 문제 생성에 실패했어요. (${response.statusCode})',
      );
    }
    return body!;
  }

  Uri _endpoint(String serverUrl) {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return Uri.parse('$normalized/api/ai/questions/generate');
  }
}
