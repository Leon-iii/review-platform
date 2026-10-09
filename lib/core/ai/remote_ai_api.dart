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
    void Function(AiGenerationProgress)? onProgress,
  });
}

class HttpRemoteAiApi implements RemoteAiApi {
  HttpRemoteAiApi(this._client);

  final http.Client _client;

  @override
  Future<AiQuestionGenerationResult> generateQuestions({
    required SyncConfiguration configuration,
    required AiQuestionGenerationRequest request,
    void Function(AiGenerationProgress)? onProgress,
  }) async {
    if (request.concepts.isNotEmpty) {
      return _generateStream(configuration, request, onProgress);
    }
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

    return _result(_decode(response));
  }

  Future<AiQuestionGenerationResult> _generateStream(
    SyncConfiguration configuration,
    AiQuestionGenerationRequest request,
    void Function(AiGenerationProgress)? onProgress,
  ) async {
    try {
      final outgoing =
          http.Request(
              'POST',
              Uri.parse('${_endpoint(configuration.serverUrl)}/stream'),
            )
            ..headers.addAll({
              'content-type': 'application/json; charset=utf-8',
              'x-sync-token': configuration.accessToken,
            })
            ..body = jsonEncode(request.toJson());
      final response = await _client
          .send(outgoing)
          .timeout(const Duration(seconds: 100));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _decode(await http.Response.fromStream(response));
      }
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              // Per-event inactivity, not the overall job duration. Ollama's
              // server-side per-request timeout is ten minutes.
              .timeout(const Duration(minutes: 12))) {
        if (line.trim().isEmpty) continue;
        final event = Map<String, Object?>.from(jsonDecode(line) as Map);
        if (event['type'] == 'error') {
          throw NetworkFailure(event['error'] as String? ?? 'AI 문제 생성에 실패했어요.');
        }
        if (event['type'] == 'complete') {
          return _result(Map<String, Object?>.from(event['result'] as Map));
        }
        if (event['type'] == 'progress') {
          final progress = event['progress'] as Map;
          onProgress?.call(
            AiGenerationProgress(
              completedConcepts: (progress['completedConcepts'] as num).toInt(),
              totalConcepts: (progress['totalConcepts'] as num).toInt(),
              generatedQuestions: (progress['generatedQuestions'] as num)
                  .toInt(),
              conceptTitle: progress['conceptTitle'] as String?,
              failedConcepts: (progress['failedConcepts'] as num).toInt(),
            ),
          );
        }
      }
      throw const NetworkFailure('문제 생성 서버와의 연결이 완료 전에 끊어졌어요.');
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('AI 문제 생성 진행 정보를 받지 못했어요.', cause: error),
        stackTrace,
      );
    }
  }

  AiQuestionGenerationResult _result(Map<String, Object?> decoded) {
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
        failures: [
          for (final raw in decoded['failures'] as List? ?? const [])
            AiConceptGenerationFailure(
              conceptId: (raw as Map)['conceptId'] as String,
              title: raw['title'] as String,
              error: raw['error'] as String,
            ),
        ],
        warnings: List.unmodifiable(
          (decoded['warnings'] as List? ?? const []).cast<String>(),
        ),
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
    return AiGeneratedQuestion(
      type: type,
      correctOrder: List.unmodifiable(
        (json['correctOrder'] as List? ?? const []).cast<int>(),
      ),
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
      primaryConceptId: json['primaryConceptId'] as String?,
      difficulty: (json['difficulty']! as num).toInt(),
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
