import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class LlmProfileApi {
  Future<LlmProfileSettings> getSettings(SyncConfiguration configuration);

  Future<LlmModelCatalog> getModels({
    required SyncConfiguration configuration,
    required LlmProviderKind provider,
  });

  Future<LlmProfileSettings> updateSettings({
    required SyncConfiguration configuration,
    required LlmProfileSettings settings,
    Map<LlmApiKeyProvider, String> apiKeys = const {},
  });
}

class HttpLlmProfileApi implements LlmProfileApi {
  HttpLlmProfileApi(this._client);

  final http.Client _client;

  @override
  Future<LlmProfileSettings> getSettings(
    SyncConfiguration configuration,
  ) async {
    final response = await _send(
      () => _client
          .get(
            _endpoint(configuration.serverUrl),
            headers: _headers(configuration),
          )
          .timeout(const Duration(seconds: 20)),
    );
    return _parse(response);
  }

  @override
  Future<LlmModelCatalog> getModels({
    required SyncConfiguration configuration,
    required LlmProviderKind provider,
  }) async {
    final response = await _send(
      () => _client
          .get(
            _modelsEndpoint(configuration.serverUrl, provider),
            headers: _headers(configuration),
          )
          .timeout(const Duration(seconds: 20)),
    );
    final body = _parseBody(response, requestName: '모델 목록');
    try {
      return LlmModelCatalog(
        provider: LlmProviderKind.fromId(body['provider']! as String),
        models: [for (final model in body['models']! as List) model as String],
        refreshedAt: DateTime.parse(body['refreshedAt']! as String).toUtc(),
        contextWindows: {
          for (final entry in Map<String, Object?>.from(
            (body['contextWindows'] as Map?) ?? const {},
          ).entries)
            entry.key: entry.value! as int,
        },
        modelCapabilities: {
          for (final entry in Map<String, Object?>.from(
            (body['modelCapabilities'] as Map?) ?? const {},
          ).entries)
            entry.key: _capabilities(
              Map<String, Object?>.from(entry.value! as Map),
            ),
        },
        modelMetadata: {
          for (final entry in Map<String, Object?>.from(
            (body['modelMetadata'] as Map?) ?? const {},
          ).entries)
            entry.key: _metadata(
              Map<String, Object?>.from(entry.value! as Map),
            ),
        },
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('모델 목록 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<LlmProfileSettings> updateSettings({
    required SyncConfiguration configuration,
    required LlmProfileSettings settings,
    Map<LlmApiKeyProvider, String> apiKeys = const {},
  }) async {
    final response = await _send(
      () => _client
          .put(
            _endpoint(configuration.serverUrl),
            headers: _headers(configuration),
            body: jsonEncode(settings.toJson(apiKeys: apiKeys)),
          )
          .timeout(const Duration(seconds: 20)),
    );
    return _parse(response);
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('용도별 AI 설정 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }
  }

  LlmProfileSettings _parse(http.Response response) {
    final body = _parseBody(response, requestName: '용도별 AI 설정');

    try {
      final profiles = body['profiles']! as List;
      final rawAssignments = Map<String, Object?>.from(
        body['assignments']! as Map,
      );
      final rawApiKeyConfigured = Map<String, Object?>.from(
        body['apiKeyConfigured']! as Map,
      );
      return LlmProfileSettings(
        profiles: [
          for (final raw in profiles)
            _profile(Map<String, Object?>.from(raw as Map)),
        ],
        assignments: {
          for (final purpose in LlmPurpose.values)
            purpose: rawAssignments[purpose.id]! as String,
        },
        apiKeyConfigured: {
          for (final provider in LlmApiKeyProvider.values)
            provider: rawApiKeyConfigured[provider.id] == true,
        },
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('용도별 AI 설정 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  LlmProfile _profile(Map<String, Object?> json) => LlmProfile(
    id: json['id']! as String,
    name: json['name']! as String,
    provider: LlmProviderKind.fromId(json['provider']! as String),
    model: json['model']! as String,
    updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
    contextWindowTokens: json['contextWindowTokens'] as int?,
    reasoningEffort: json['reasoningEffort'] as String?,
    maximumQuestionsPerRequest:
        json['maximumQuestionsPerRequest'] as int? ?? 120,
  );

  LlmModelCapabilities _capabilities(Map<String, Object?> json) =>
      LlmModelCapabilities(
        isKnown: json['isKnown'] == true,
        reasoningEfforts: [
          for (final effort in (json['reasoningEfforts'] as List?) ?? const [])
            effort as String,
        ],
        defaultReasoningEffort: json['defaultReasoningEffort'] as String?,
        supportsReasoning: json['supportsReasoning'] == true,
      );

  LlmModelMetadata _metadata(Map<String, Object?> json) => LlmModelMetadata(
    lifecycle: LlmModelLifecycle.fromId(json['lifecycle'] as String?),
    isSnapshot: json['isSnapshot'] == true,
  );

  Map<String, Object?> _parseBody(
    http.Response response, {
    required String requestName,
  }) {
    Map<String, Object?>? body;
    try {
      body = Map<String, Object?>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw NetworkFailure('$requestName 응답 형식이 올바르지 않아요.');
      }
    }
    if (response.statusCode == 401) {
      throw const NetworkFailure('서버 접근 토큰이 올바르지 않아요.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body?['error'];
      throw NetworkFailure(
        error is String && error.isNotEmpty
            ? error
            : '$requestName 요청에 실패했어요. (${response.statusCode})',
      );
    }
    return body!;
  }

  Uri _endpoint(String serverUrl) {
    final normalized = serverUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$normalized/api/llm/settings');
  }

  Uri _modelsEndpoint(String serverUrl, LlmProviderKind provider) {
    final normalized = serverUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$normalized/api/llm/models')
        .replace(queryParameters: {'provider': provider.id});
  }

  Map<String, String> _headers(SyncConfiguration configuration) => {
    'content-type': 'application/json; charset=utf-8',
    'x-sync-token': configuration.accessToken,
  };
}
