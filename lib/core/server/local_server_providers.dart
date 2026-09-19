import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:review_platform/core/server/local_server_service.dart';
import 'package:review_platform/core/server/local_server_settings_store.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'local_server_providers.g.dart';

@riverpod
bool isWindowsPlatform(Ref ref) => Platform.isWindows;

@Riverpod(keepAlive: true)
LocalServerConfigStore localServerConfigStore(Ref ref) {
  return JsonLocalServerConfigStore();
}

@Riverpod(keepAlive: true)
LocalServerSecretStore localServerSecretStore(Ref ref) {
  return SecureLocalServerSecretStore(const FlutterSecureStorage());
}

@Riverpod(keepAlive: true)
LocalServerService localServerService(Ref ref) {
  final service = LocalServerService(
    secretStore: ref.watch(localServerSecretStoreProvider),
    accessTokenReader: () async {
      final configuration = await ref
          .read(syncCredentialsStoreProvider)
          .readConfiguration();
      return configuration?.accessToken;
    },
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
}
