import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/llm_profile.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class LlmProfileApi {
  Future<LlmProfileSettings> getSettings(SyncConfiguration configuration);

  Future<LlmProfileSettings> updateSettings({
    required SyncConfiguration configuration,
    required LlmProfileSettings settings,
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
  Future<LlmProfileSettings> updateSettings({
    required SyncConfiguration configuration,
    required LlmProfileSettings settings,
  }) async {
    final response = await _send(
      () => _client
          .put(
            _endpoint(configuration.serverUrl),
            headers: _headers(configuration),
            body: jsonEncode(settings.toJson()),
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
        NetworkFailure('LLM 프로필 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }
  }

  LlmProfileSettings _parse(http.Response response) {
    Map<String, Object?>? body;
    try {
      body = Map<String, Object?>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const NetworkFailure('LLM 프로필 응답 형식이 올바르지 않아요.');
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
            : 'LLM 프로필 요청에 실패했어요. (${response.statusCode})',
      );
    }

    try {
      final profiles = body!['profiles']! as List;
      final rawAssignments = Map<String, Object?>.from(
        body['assignments']! as Map,
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
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('LLM 프로필 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  LlmProfile _profile(Map<String, Object?> json) => LlmProfile(
    id: json['id']! as String,
    name: json['name']! as String,
    provider: LlmProviderKind.fromId(json['provider']! as String),
    model: json['model']! as String,
    baseUrl: json['baseUrl']! as String,
    updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
  );

  Uri _endpoint(String serverUrl) {
    final normalized = serverUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$normalized/api/llm/settings');
  }

  Map<String, String> _headers(SyncConfiguration configuration) => {
    'content-type': 'application/json; charset=utf-8',
    'x-sync-token': configuration.accessToken,
  };
}
