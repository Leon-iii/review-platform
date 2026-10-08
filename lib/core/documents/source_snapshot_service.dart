import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

typedef _PageKey = (String, String, String, String, int);

final sourceSnapshotServiceProvider = Provider<SourceSnapshotService>((ref) {
  final jobs = ref.watch(documentJobRepositoryProvider);
  final service = SourceSnapshotService(
    ref.watch(remoteDocumentApiProvider),
    ref.watch(syncCredentialsStoreProvider),
    registeredServer: (id) async => (await jobs.get(id))?.serverUrl,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Server-scoped, bounded LRU of encoded images. Failures are never cached.
/// No permanent files, PDF copies, OCR or model requests are made here.
class SourceSnapshotService {
  SourceSnapshotService(
    this.api,
    this.credentials, {
    this.registeredServer,
    this.maximumCacheBytes = 24 * 1024 * 1024,
    this.maximumCacheEntries = 12,
  });
  final RemoteDocumentApi api;
  final SyncCredentialsStore credentials;
  final Future<String?> Function(String)? registeredServer;
  final int maximumCacheBytes;
  final int maximumCacheEntries;
  final _cache = <_PageKey, Uint8List>{};
  final _pending = <_PageKey, Future<Uint8List>>{};
  int _cacheBytes = 0;
  bool _disposed = false;

  String _url(String value) => value.replaceFirst(RegExp(r'/+$'), '');

  Future<Uint8List> page(
    StudySource source,
    int page, {
    bool refresh = false,
  }) async {
    if (_disposed) throw const NetworkFailure('원본 보기 화면을 다시 열어 주세요.');
    if (source.isManual || page < 1 || page > source.pageCount) {
      throw const ValidationFailure('이 개념의 PDF 출처 페이지를 확인할 수 없어요.');
    }
    final configuration = await credentials.readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('설정 > 동기화에서 원본 PDF 서버에 연결해 주세요.');
    }
    final origin = await registeredServer?.call(source.id);
    if (origin != null && _url(origin) != _url(configuration.serverUrl)) {
      throw const ValidationFailure('자료를 업로드한 서버에 연결해 주세요.');
    }
    if (api is! RemoteSourceSnapshotApi) {
      throw const ValidationFailure('서버와 앱을 업데이트하면 PDF 원본을 볼 수 있어요.');
    }
    // Credentials also scope the memory cache; changing servers or access tokens
    // cannot return images retrieved under a previous connection.
    final key = (
      _url(configuration.serverUrl),
      configuration.accessToken,
      source.id,
      source.contentHash,
      page,
    );
    final cached = _cache.remove(key);
    if (cached != null && !refresh) {
      _cache[key] = cached;
      return cached;
    }
    if (cached != null) _cacheBytes -= cached.length;
    if (_pending[key] case final pending?) return pending;
    final request = _fetch(configuration, source.id, page, key);
    _pending[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_pending[key], request)) _pending.remove(key);
    }
  }

  Future<Uint8List> _fetch(
    SyncConfiguration configuration,
    String sourceId,
    int page,
    _PageKey key,
  ) async {
    final bytes = await (api as RemoteSourceSnapshotApi).sourceImage(
      configuration,
      sourceId,
      page,
    );
    if (!_disposed && bytes.length <= maximumCacheBytes) {
      _cache[key] = bytes;
      _cacheBytes += bytes.length;
      while (_cacheBytes > maximumCacheBytes ||
          _cache.length > maximumCacheEntries) {
        _cacheBytes -= _cache.remove(_cache.keys.first)!.length;
      }
    }
    return bytes;
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _pending.clear();
    _cacheBytes = 0;
  }
}
