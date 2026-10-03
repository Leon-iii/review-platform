import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/services/automatic_sync_controller.dart';
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
  AutomaticSyncController? controller;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    syncRepository = DriftSyncRepository(database);
    credentialsStore = MemorySyncCredentialsStore();
    remoteApi = FakeRemoteSyncApi();
    coordinator = SyncCoordinator(credentialsStore, remoteApi, syncRepository);
  });

  tearDown(() async {
    await controller?.dispose();
    await database.close();
  });

  AutomaticSyncController createController({
    Duration debounceDuration = const Duration(hours: 1),
    Future<bool> Function(SyncConfiguration)? canSynchronize,
    Duration readinessRetryInterval = const Duration(seconds: 3),
  }) {
    return controller = AutomaticSyncController(
      credentialsStore,
      coordinator,
      syncRepository.watchStatus(),
      debounceDuration: debounceDuration,
      periodicInterval: const Duration(hours: 1),
      canSynchronize: canSynchronize,
      readinessRetryInterval: readinessRetryInterval,
    );
  }

  void configure() {
    credentialsStore.configuration = const SyncConfiguration(
      serverUrl: 'http://127.0.0.1:5080',
      accessToken: 'token',
    );
  }

  test('앱 시작 시 대기 중인 변경을 동기화한다', () async {
    configure();
    await DriftFolderRepository(database).createFolder(name: '시작 동기화');

    await createController().start();

    expect(remoteApi.pushedBatches, hasLength(1));
    expect(await syncRepository.getPending(), isEmpty);
  });

  test('동기화 설정이 없으면 자동 요청을 건너뛴다', () async {
    await DriftFolderRepository(database).createFolder(name: '로컬 전용');

    await createController().start();

    expect(remoteApi.pushedBatches, isEmpty);
    expect(await syncRepository.getPending(), hasLength(1));
  });

  test('포그라운드 복귀 시 즉시 동기화한다', () async {
    configure();
    final automaticSync = createController();
    await automaticSync.start();
    await DriftFolderRepository(database).createFolder(name: '복귀 동기화');

    await automaticSync.onForeground();

    expect(remoteApi.pushedBatches, hasLength(1));
    expect(await syncRepository.getPending(), isEmpty);
  });

  test('서버가 준비될 때까지 자동 동기화 요청과 오류 기록을 보류한다', () async {
    configure();
    final ready = Completer<bool>();
    final entered = Completer<void>();
    final automatic = createController(
      canSynchronize: (_) {
        entered.complete();
        return ready.future;
      },
    );
    final starting = automatic.start();
    await entered.future;
    expect(remoteApi.pullCallCount, 0);
    expect((await syncRepository.getStatus()).lastError, isNull);
    ready.complete(true);
    await starting;
    expect(remoteApi.pullCallCount, 1);
    expect((await syncRepository.getStatus()).lastSyncedAt, isNotNull);
  });

  test('대기 0건이어도 꺼진 서버를 다시 확인하고 복구 성공 후 이전 오류를 해제한다', () async {
    configure();
    await syncRepository.recordFailure('이전 연결 실패');
    var ready = false;
    final automatic = createController(
      canSynchronize: (_) async => ready,
      readinessRetryInterval: const Duration(milliseconds: 20),
    );
    await automatic.start();
    expect(remoteApi.pullCallCount, 0);
    expect((await syncRepository.getStatus()).lastError, '이전 연결 실패');
    final recovered = syncRepository.watchStatus().firstWhere(
      (value) => value.lastSyncedAt != null && value.lastError == null,
    );
    ready = true;
    await recovered.timeout(const Duration(seconds: 2));
    expect(remoteApi.pullCallCount, 1);
    expect(await syncRepository.getPending(), isEmpty);
  });

  test('준비 대기 중 앱이 종료되면 뒤늦게 서버가 켜져도 요청하지 않는다', () async {
    configure();
    final ready = Completer<bool>();
    final entered = Completer<void>();
    final automatic = createController(
      canSynchronize: (_) {
        entered.complete();
        return ready.future;
      },
    );
    final starting = automatic.start();
    await entered.future;
    final disposing = automatic.dispose();
    ready.complete(true);
    await Future.wait([starting, disposing]);
    controller = null;
    expect(remoteApi.pullCallCount, 0);
  });

  testWidgets('로컬 변경은 debounce 후 자동 동기화한다', (tester) async {
    await tester.runAsync(() async {
      configure();
      await createController(debounceDuration: const Duration(milliseconds: 20))
          .start();

      await DriftFolderRepository(database).createFolder(name: '변경 동기화');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(remoteApi.pushedBatches, hasLength(1));
      expect(await syncRepository.getPending(), isEmpty);
      await controller?.dispose();
      controller = null;
    });
  });
}
