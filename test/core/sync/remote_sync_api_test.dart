import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/remote_sync_api.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://127.0.0.1:5080/',
    accessToken: 'private-token',
  );

  test('push 요청에 토큰과 UTF-8 JSON payload를 전송한다', () async {
    late http.Request captured;
    final api = HttpRemoteSyncApi(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'acknowledgedOperationIds': ['operation-1'],
            'serverRevision': 3,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final response = await api.push(
      configuration: configuration,
      changes: [
        PushSyncChange(
          operationId: 'operation-1',
          entityType: 'folder',
          entityId: 'folder-1',
          operation: 'upsert',
          payload: const {'name': '전자기학'},
          updatedAt: DateTime.utc(2026, 9, 17),
        ),
      ],
    );

    expect(captured.url.path, '/api/sync/push');
    expect(captured.headers['x-sync-token'], 'private-token');
    expect(jsonDecode(captured.body)['changes'][0]['payload']['name'], '전자기학');
    expect(response.acknowledgedOperationIds, ['operation-1']);
    expect(response.serverRevision, 3);
  });

  test('pull 응답의 revision과 변경사항을 파싱한다', () async {
    final api = HttpRemoteSyncApi(
      MockClient((request) async {
        expect(request.url.queryParameters['sinceRevision'], '4');
        return http.Response(
          jsonEncode({
            'changes': [
              {
                'entityType': 'folder',
                'entityId': 'folder-1',
                'operation': 'upsert',
                'payload': {'name': '물리'},
                'updatedAt': '2026-09-17T00:00:00.000Z',
                'deletedAt': null,
                'revision': 5,
              },
            ],
            'serverRevision': 5,
            'hasMore': false,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final response = await api.pull(
      configuration: configuration,
      sinceRevision: 4,
    );

    expect(response.serverRevision, 5);
    expect(response.changes.single.entityId, 'folder-1');
    expect(response.changes.single.revision, 5);
  });

  test('인증 실패를 사용자용 NetworkFailure로 변환한다', () async {
    final api = HttpRemoteSyncApi(
      MockClient((request) async => http.Response('{}', 401)),
    );

    await expectLater(
      api.pull(configuration: configuration, sinceRevision: 0),
      throwsA(
        isA<NetworkFailure>().having(
          (failure) => failure.message,
          'message',
          contains('토큰'),
        ),
      ),
    );
  });
}
