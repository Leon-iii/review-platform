import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:review_platform/core/sync/remote_sync_api.dart';
import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/domain/services/automatic_sync_controller.dart';
import 'package:review_platform/domain/services/sync_coordinator.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_providers.g.dart';

@Riverpod(keepAlive: true)
SyncCredentialsStore syncCredentialsStore(Ref ref) {
  return SecureSyncCredentialsStore(const FlutterSecureStorage());
}

@Riverpod(keepAlive: true)
http.Client syncHttpClient(Ref ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
}

@Riverpod(keepAlive: true)
RemoteSyncApi remoteSyncApi(Ref ref) {
  return HttpRemoteSyncApi(ref.watch(syncHttpClientProvider));
}

@Riverpod(keepAlive: true)
SyncCoordinator syncCoordinator(Ref ref) {
  return SyncCoordinator(
    ref.watch(syncCredentialsStoreProvider),
    ref.watch(remoteSyncApiProvider),
    ref.watch(syncRepositoryProvider),
  );
}

@Riverpod(keepAlive: true)
AutomaticSyncController automaticSyncController(Ref ref) {
  final controller = AutomaticSyncController(
    ref.watch(syncCredentialsStoreProvider),
    ref.watch(syncCoordinatorProvider),
    ref.watch(syncRepositoryProvider).watchStatus(),
  );
  ref.onDispose(controller.dispose);
  return controller;
}
