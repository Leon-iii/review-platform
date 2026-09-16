import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class RemoteSyncApi {
  Future<PushSyncResponse> push({
    required SyncConfiguration configuration,
    required List<PushSyncChange> changes,
  });

  Future<PullSyncResponse> pull({
    required SyncConfiguration configuration,
    required int sinceRevision,
    int limit = 500,
  });
}

class HttpRemoteSyncApi implements RemoteSyncApi {
  HttpRemoteSyncApi(this._client);

  final http.Client _client;

  @override
  Future<PushSyncResponse> push({
    required SyncConfiguration configuration,
    required List<PushSyncChange> changes,
  }) async {
    final response = await _send(
      () => _client
          .post(
            _endpoint(configuration.serverUrl, '/api/sync/push'),
            headers: _headers(configuration.accessToken),
            body: jsonEncode({
              'changes': [for (final change in changes) change.toJson()],
            }),
          )
          .timeout(const Duration(seconds: 20)),
    );
    final body = _decode(response);
    return PushSyncResponse(
      acknowledgedOperationIds: [
        for (final id in body['acknowledgedOperationIds']! as List)
          id as String,
      ],
      serverRevision: (body['serverRevision']! as num).toInt(),
    );
  }

  @override
  Future<PullSyncResponse> pull({
    required SyncConfiguration configuration,
    required int sinceRevision,
    int limit = 500,
  }) async {
    final endpoint = _endpoint(configuration.serverUrl, '/api/sync/pull')
        .replace(
          queryParameters: {
            'sinceRevision': '$sinceRevision',
            'limit': '$limit',
          },
        );
    final response = await _send(
      () => _client
          .get(endpoint, headers: _headers(configuration.accessToken))
          .timeout(const Duration(seconds: 20)),
    );
    final body = _decode(response);
    return PullSyncResponse(
      changes: [
        for (final change in body['changes']! as List)
          PullSyncChange.fromJson(Map<String, Object?>.from(change as Map)),
      ],
      serverRevision: (body['serverRevision']! as num).toInt(),
      hasMore: body['hasMore']! as bool,
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('개인 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }
  }

  Map<String, Object?> _decode(http.Response response) {
    if (response.statusCode == 401) {
      throw const NetworkFailure('서버 접근 토큰이 올바르지 않아요.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NetworkFailure('서버 요청에 실패했어요. (${response.statusCode})');
    }
    try {
      return Map<String, Object?>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('서버 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  Uri _endpoint(String serverUrl, String path) {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return Uri.parse('$normalized$path');
  }

  Map<String, String> _headers(String token) => {
    'content-type': 'application/json; charset=utf-8',
    'x-sync-token': token,
  };
}
