import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class SyncCredentialsStore {
  Future<SyncConfiguration?> readConfiguration();

  Future<SyncSettings> readSettings();

  Future<void> save({required String serverUrl, String? accessToken});

  Future<void> clear();
}

class SecureSyncCredentialsStore implements SyncCredentialsStore {
  SecureSyncCredentialsStore(this._storage);

  static const _serverUrlKey = 'sync_server_url';
  static const _accessTokenKey = 'sync_access_token';

  final FlutterSecureStorage _storage;

  @override
  Future<SyncConfiguration?> readConfiguration() async {
    final values = await _storage.readAll();
    final serverUrl = values[_serverUrlKey];
    final accessToken = values[_accessTokenKey];
    if (serverUrl == null ||
        serverUrl.isEmpty ||
        accessToken == null ||
        accessToken.isEmpty) {
      return null;
    }
    return SyncConfiguration(serverUrl: serverUrl, accessToken: accessToken);
  }

  @override
  Future<SyncSettings> readSettings() async {
    final values = await _storage.readAll();
    return SyncSettings(
      serverUrl: values[_serverUrlKey] ?? '',
      hasAccessToken: (values[_accessTokenKey] ?? '').isNotEmpty,
    );
  }

  @override
  Future<void> save({required String serverUrl, String? accessToken}) async {
    await _storage.write(key: _serverUrlKey, value: serverUrl);
    if (accessToken != null && accessToken.isNotEmpty) {
      await _storage.write(key: _accessTokenKey, value: accessToken);
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _serverUrlKey);
    await _storage.delete(key: _accessTokenKey);
  }
}
