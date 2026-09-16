import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/remote_sync_api.dart';
import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/sync_repository.dart';

class SyncCoordinator {
  SyncCoordinator(
    this._credentialsStore,
    this._remoteApi,
    this._syncRepository,
  );

  final SyncCredentialsStore _credentialsStore;
  final RemoteSyncApi _remoteApi;
  final SyncRepository _syncRepository;
  Future<SyncRunResult>? _activeSync;

  Future<SyncRunResult> synchronize() {
    final activeSync = _activeSync;
    if (activeSync != null) return activeSync;

    late final Future<SyncRunResult> guardedSync;
    guardedSync = _synchronize().whenComplete(() {
      if (identical(_activeSync, guardedSync)) {
        _activeSync = null;
      }
    });
    _activeSync = guardedSync;
    return guardedSync;
  }

  Future<SyncRunResult> _synchronize() async {
    List<PushSyncChange> activeBatch = const [];
    var pushedCount = 0;
    try {
      final configuration = await _credentialsStore.readConfiguration();
      if (configuration == null) {
        throw const SyncFailure('먼저 서버 주소와 접근 토큰을 저장해 주세요.');
      }
      while (true) {
        activeBatch = await _syncRepository.buildPushBatch();
        if (activeBatch.isEmpty) break;
        final response = await _remoteApi.push(
          configuration: configuration,
          changes: activeBatch,
        );
        final expected = activeBatch
            .map((change) => change.operationId)
            .toSet();
        final acknowledged = response.acknowledgedOperationIds.toSet();
        if (!acknowledged.containsAll(expected)) {
          throw const SyncFailure('서버가 일부 변경사항을 확인하지 못했어요.');
        }
        await _syncRepository.removeAcknowledged(expected);
        pushedCount += expected.length;
      }

      final status = await _syncRepository.getStatus();
      var nextRevision = status.lastPulledRevision;
      var finalServerRevision = nextRevision;
      final pulledChanges = <PullSyncChange>[];
      while (true) {
        final response = await _remoteApi.pull(
          configuration: configuration,
          sinceRevision: nextRevision,
        );
        pulledChanges.addAll(response.changes);
        finalServerRevision = response.serverRevision;
        if (!response.hasMore) break;
        if (response.changes.isEmpty) {
          throw const SyncFailure('서버의 페이지 정보가 올바르지 않아요.');
        }
        nextRevision = response.changes.last.revision;
      }

      await _syncRepository.applyPulledChanges(pulledChanges);
      await _syncRepository.recordSuccess(
        revision: finalServerRevision,
        at: DateTime.now().toUtc(),
      );
      return SyncRunResult(
        pushedCount: pushedCount,
        pulledCount: pulledChanges.length,
        serverRevision: finalServerRevision,
      );
    } catch (error) {
      final message = error is AppFailure ? error.message : '동기화에 실패했어요.';
      for (final change in activeBatch) {
        await _syncRepository.markFailed(
          id: change.operationId,
          error: message,
        );
      }
      await _syncRepository.recordFailure(message);
      if (error is AppFailure) rethrow;
      throw SyncFailure(message, cause: error);
    }
  }
}
