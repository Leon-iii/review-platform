import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:review_platform/core/server/local_server_config.dart';

abstract interface class LocalServerConfigStore {
  Future<LocalServerConfig> read();

  Future<void> write(LocalServerConfig config);
}

class JsonLocalServerConfigStore implements LocalServerConfigStore {
  JsonLocalServerConfigStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const _fileName = 'local_server_settings.json';

  final Future<Directory> Function() _directoryProvider;

  @override
  Future<LocalServerConfig> read() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return const LocalServerConfig.defaults();
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, Object?>) {
        return const LocalServerConfig.defaults();
      }
      return LocalServerConfig.fromJson(value);
    } on FormatException {
      return const LocalServerConfig.defaults();
    } on FileSystemException {
      return const LocalServerConfig.defaults();
    }
  }

  @override
  Future<void> write(LocalServerConfig config) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(config.toJson()), flush: true);
  }

  Future<File> _settingsFile() async {
    final directory = await _directoryProvider();
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }
}

abstract interface class LocalServerSecretStore {
  Future<String?> read(LocalLlmProvider provider);

  Future<void> write(LocalLlmProvider provider, String value);
}

class SecureLocalServerSecretStore implements LocalServerSecretStore {
  SecureLocalServerSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(LocalLlmProvider provider) {
    if (!provider.requiresApiKey) return Future.value();
    return _storage.read(key: provider.secretStorageKey);
  }

  @override
  Future<void> write(LocalLlmProvider provider, String value) async {
    if (!provider.requiresApiKey) return;
    await _storage.write(key: provider.secretStorageKey, value: value);
  }
}
