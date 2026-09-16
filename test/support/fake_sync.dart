import 'dart:async';

import 'package:review_platform/core/sync/remote_sync_api.dart';
import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

class MemorySyncCredentialsStore implements SyncCredentialsStore {
  MemorySyncCredentialsStore({this.configuration});

  SyncConfiguration? configuration;

  @override
  Future<void> clear() async {
    configuration = null;
  }

  @override
  Future<SyncConfiguration?> readConfiguration() async => configuration;

  @override
  Future<SyncSettings> readSettings() async {
    return SyncSettings(
      serverUrl: configuration?.serverUrl ?? '',
      hasAccessToken: (configuration?.accessToken ?? '').isNotEmpty,
    );
  }

  @override
  Future<void> save({required String serverUrl, String? accessToken}) async {
    configuration = SyncConfiguration(
      serverUrl: serverUrl,
      accessToken: accessToken ?? configuration?.accessToken ?? '',
    );
  }
}

class FakeRemoteSyncApi implements RemoteSyncApi {
  final List<List<PushSyncChange>> pushedBatches = [];
  final List<PullSyncResponse> pullResponses = [];
  Completer<void>? pushGate;
  int pullCallCount = 0;

  @override
  Future<PullSyncResponse> pull({
    required SyncConfiguration configuration,
    required int sinceRevision,
    int limit = 500,
  }) async {
    pullCallCount += 1;
    if (pullResponses.isEmpty) {
      return PullSyncResponse(
        changes: const [],
        serverRevision: sinceRevision,
        hasMore: false,
      );
    }
    return pullResponses.removeAt(0);
  }

  @override
  Future<PushSyncResponse> push({
    required SyncConfiguration configuration,
    required List<PushSyncChange> changes,
  }) async {
    pushedBatches.add(List.unmodifiable(changes));
    await pushGate?.future;
    return PushSyncResponse(
      acknowledgedOperationIds: [
        for (final change in changes) change.operationId,
      ],
      serverRevision: 0,
    );
  }
}
