import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/services/sync_coordinator.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';

import '../support/fake_sync.dart';

void main() {
  late AppDatabase database;
  late DriftSyncRepository syncRepository;
  late MemorySyncCredentialsStore credentialsStore;
  late FakeRemoteSyncApi remoteApi;
  late SyncCoordinator coordinator;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    syncRepository = DriftSyncRepository(database);
    credentialsStore = MemorySyncCredentialsStore(
      configuration: const SyncConfiguration(
        serverUrl: 'http://127.0.0.1:5080',
        accessToken: 'token',
      ),
    );
    remoteApi = FakeRemoteSyncApi();
    coordinator = SyncCoordinator(credentialsStore, remoteApi, syncRepository);
  });

  tearDown(() => database.close());

  test('Outbox payload를 push하고 승인된 항목을 제거한다', () async {
    await DriftFolderRepository(database).createFolder(name: '전자기학');
    remoteApi.pullResponses.add(
      const PullSyncResponse(changes: [], serverRevision: 8, hasMore: false),
    );

    final result = await coordinator.synchronize();

    expect(result.pushedCount, 1);
    expect(remoteApi.pushedBatches, hasLength(1));
    expect(remoteApi.pushedBatches.single.single.payload?['name'], '전자기학');
    expect(await syncRepository.getPending(), isEmpty);
    final status = await syncRepository.getStatus();
    expect(status.lastPulledRevision, 8);
    expect(status.lastSyncedAt, isNotNull);
  });

  test('pull한 원격 Folder를 Outbox 재생성 없이 로컬에 병합한다', () async {
    remoteApi.pullResponses.add(
      PullSyncResponse(
        changes: [
          PullSyncChange(
            entityType: 'folder',
            entityId: 'remote-folder',
            operation: 'upsert',
            payload: const {
              'id': 'remote-folder',
              'parentId': null,
              'name': '원격 폴더',
              'createdAt': '2026-09-17T00:00:00.000Z',
              'updatedAt': '2026-09-17T00:00:00.000Z',
              'deletedAt': null,
            },
            updatedAt: DateTime.utc(2026, 9, 17),
            revision: 1,
          ),
        ],
        serverRevision: 1,
        hasMore: false,
      ),
    );

    final result = await coordinator.synchronize();

    final tree = await DriftFolderRepository(database).watchFolderTree().first;
    expect(result.pulledCount, 1);
    expect(tree.single.folder.name, '원격 폴더');
    expect(await syncRepository.getPending(), isEmpty);
  });

  test('동시에 요청된 동기화는 하나의 실행을 공유한다', () async {
    await DriftFolderRepository(database).createFolder(name: '병렬 요청');
    final gate = Completer<void>();
    remoteApi.pushGate = gate;

    final first = coordinator.synchronize();
    while (remoteApi.pushedBatches.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = coordinator.synchronize();

    expect(identical(first, second), isTrue);
    gate.complete();
    await Future.wait([first, second]);
    expect(remoteApi.pushedBatches, hasLength(1));
  });
}
