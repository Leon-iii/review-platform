import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/documents/source_snapshot_service.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

import '../../support/fake_source_snapshots.dart';
import '../../support/fake_sync.dart';

void main() {
  StudySource source({String id = 'source', String hash = 'hash'}) =>
      StudySource(
        id: id,
        folderId: 'folder',
        fileName: '강의.pdf',
        contentHash: hash,
        pageCount: 60,
        extractionMethod: 'directPdf',
        importedAt: DateTime.utc(2026),
      );
  late FakeSourceSnapshotsApi api;
  late MemorySyncCredentialsStore credentials;
  setUp(() {
    api = FakeSourceSnapshotsApi();
    credentials = MemorySyncCredentialsStore(
      configuration: const SyncConfiguration(
        serverUrl: 'http://server:5080',
        accessToken: 'token',
      ),
    );
  });

  test('동일 페이지 중복 요청을 합치고 실패는 캐시하지 않는다', () async {
    final service = SourceSnapshotService(api, credentials);
    api.gate = Completer<void>();
    final first = service.page(source(), 47);
    final second = service.page(source(), 47);
    await Future<void>.delayed(Duration.zero);
    expect(api.calls, [('source', 47)]);
    api.gate!.complete();
    expect(await first, same(await second));
    await service.page(source(), 47);
    expect(api.calls.length, 1);
    await service.page(source(), 47, refresh: true);
    expect(api.calls.length, 2);
    api.error = const NetworkFailure('서버 연결 실패');
    await expectLater(
      service.page(source(), 50),
      throwsA(isA<NetworkFailure>()),
    );
    api.error = null;
    await service.page(source(), 50);
    expect(api.calls.length, 4);
    service.dispose();
  });

  test('캐시 용량과 항목 수를 제한하고 최근 사용 페이지를 유지한다', () async {
    api.bytes = Uint8List(4);
    final service = SourceSnapshotService(
      api,
      credentials,
      maximumCacheBytes: 8,
      maximumCacheEntries: 2,
    );
    await service.page(source(), 1);
    await service.page(source(), 2);
    await service.page(source(), 1);
    await service.page(source(), 3);
    await service.page(source(), 1);
    expect(api.calls.length, 3);
    await service.page(source(), 2);
    expect(api.calls.length, 4);
  });

  test('서버·토큰·자료·원본 해시별로 캐시를 분리한다', () async {
    final service = SourceSnapshotService(api, credentials);
    await service.page(source(), 1);
    await service.page(source(hash: 'other'), 1);
    await service.page(source(id: 'other'), 1);
    await credentials.save(
      serverUrl: 'http://server:5080',
      accessToken: 'new-token',
    );
    await service.page(source(), 1);
    await credentials.save(
      serverUrl: 'http://other:5080',
      accessToken: 'new-token',
    );
    await service.page(source(), 1);
    expect(api.calls.length, 5);
  });

  test('잘못된 페이지와 원본 업로드 서버 불일치는 조회 전에 차단한다', () async {
    final service = SourceSnapshotService(
      api,
      credentials,
      registeredServer: (_) async => 'http://origin:5080',
    );
    await expectLater(
      service.page(source(), 1),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      service.page(source(), 0),
      throwsA(isA<ValidationFailure>()),
    );
    await expectLater(
      service.page(source(), 61),
      throwsA(isA<ValidationFailure>()),
    );
    expect(api.calls, isEmpty);
    await credentials.clear();
    await expectLater(
      service.page(source(), 1),
      throwsA(isA<ValidationFailure>()),
    );
  });
}
