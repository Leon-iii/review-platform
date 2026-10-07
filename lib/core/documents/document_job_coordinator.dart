import 'dart:async';
import 'dart:typed_data';

import 'package:review_platform/domain/models/document_extraction.dart';

import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:uuid/uuid.dart';

class DocumentJobCoordinator {
  DocumentJobCoordinator(
    this.api,
    this.jobs,
    this.sources,
    this.credentials,
    this.onSaved, {
    this.onError,
    this.canPoll,
  });
  final RemoteDocumentJobApi api;
  final DocumentJobRepository jobs;
  final SourceRepository sources;
  final SyncCredentialsStore credentials;
  final void Function(String folderId) onSaved;
  final void Function(PdfImportJob job)? onError;
  final Future<bool> Function(SyncConfiguration configuration)? canPoll;
  final Map<String, String> _reportedErrors = {};
  Timer? _timer;
  Future<void>? _polling;
  bool _disposed = false;
  final Set<String> _uploading = {};
  final Set<String> _changing = {};
  final Set<String> _deleted = {};
  final Map<String, Future<String?>> _applying = {};
  final Map<String, int> _mutationVersions = {};

  void _reportError(PdfImportJob job) {
    if (_deleted.contains(job.id)) return;
    final message = job.error;
    if (message == null || message.isEmpty) {
      _reportedErrors.remove(job.id);
      return;
    }
    final signature = '${job.status}:$message';
    if (_reportedErrors[job.id] == signature) return;
    _reportedErrors[job.id] = signature;
    if (!_disposed) onError?.call(job);
  }

  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(poll()),
    );
    unawaited(poll());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  Future<String> upload(String folderId, PickedPdfDocument document) async {
    final configuration = await credentials.readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
    }
    document.validate();
    final maximum = await api.maximumUploadBytes(configuration);
    if (document.length > maximum) {
      throw ValidationFailure(
        'PDF 파일은 서버 설정에 따라 ${maximum ~/ (1024 * 1024)}MB 이하만 가져올 수 있어요.',
      );
    }
    final id = const Uuid().v4();
    _uploading.add(id);
    final initial = PdfImportJob({
      'id': id,
      'fileName': document.fileName,
      'status': 'uploading',
      'extractionMode': 'unselected',
    });
    try {
      await jobs.add(
        folderId: folderId,
        serverUrl: configuration.serverUrl,
        job: initial,
      );
      try {
        final job = await api.uploadJob(configuration, id, document);
        if (!_disposed) await jobs.update(job);
      } catch (error) {
        if (!_disposed) {
          final failed = PdfImportJob({
            ...initial.data,
            'error': error is AppFailure
                ? error.message
                : 'PDF 업로드를 확인하지 못했어요.',
          });
          await jobs.update(failed);
          _reportError(failed);
        }
        // Receipt may have been lost after the server accepted the upload.
        // The durable client-generated ID lets polling recover that case.
      }
    } finally {
      _uploading.remove(id);
    }
    if (!_disposed) unawaited(poll());
    return id;
  }

  Future<void> poll() {
    if (_disposed) return _polling ?? Future.value();
    return _polling ??= _pollOnce().whenComplete(() => _polling = null);
  }

  Future<void> _pollOnce() async {
    try {
      final rows = await jobs.pending();
      if (rows.isEmpty || _disposed) return;
      final configuration = await credentials.readConfiguration();
      if (configuration == null || _disposed) return;
      Future<bool>? serverReady;
      for (final row in rows) {
        if (_disposed) break;
        final previous = DocumentJobRepository.job(row);
        if (_uploading.contains(row.id) ||
            _deleted.contains(row.id) ||
            _changing.contains(row.id) ||
            _normalize(row.serverUrl) != _normalize(configuration.serverUrl)) {
          continue;
        }
        if (!(previous.isActive ||
            previous.isAwaitingSelection ||
            previous.status == 'uploading' ||
            previous.status == 'completed')) {
          // Real, persisted server failures still alert.
          _reportError(previous);
          continue;
        }
        serverReady ??= canPoll?.call(configuration) ?? Future.value(true);
        if (!await serverReady || _disposed) continue;
        // Startup/foreground recovery must not replay an old connection error
        // before a fresh status request has had the chance to clear it.
        if (_changing.contains(row.id) || _deleted.contains(row.id)) {
          continue;
        }
        final mutationVersion = _mutationVersions[row.id] ?? 0;
        var latest = previous;
        try {
          final job = await api.getJob(configuration, row.id);
          if (_disposed) break;
          if (_changing.contains(row.id) ||
              mutationVersion != (_mutationVersions[row.id] ?? 0)) {
            continue;
          }
          if (job == null) {
            // A setup screen has no running model call to fail.
            if (latest.isAwaitingSelection) continue;
            final failed = PdfImportJob({
              ...previous.data,
              'status': 'uploadFailed',
              'error': '서버에서 업로드를 찾지 못했어요. PDF 파일을 다시 선택해 주세요.',
            });
            await jobs.update(failed);
            _reportError(failed);
            continue;
          }
          await jobs.update(job);
          latest = job;
          if (job.status == 'completed') {
            final result = await api.jobResult(configuration, row.id);
            if (_disposed) break;
            if (_changing.contains(row.id) ||
                mutationVersion != (_mutationVersions[row.id] ?? 0)) {
              continue;
            }
            if (result.source.id != row.id) {
              throw const NetworkFailure('PDF 작업 ID와 결과가 일치하지 않아요.');
            }
            final applying = jobs.applyResult(row.id, (folderId) async {
              await sources.saveImport(folderId: folderId, result: result);
            });
            _applying[row.id] = applying;
            try {
              final savedFolderId = await applying;
              if (!_disposed && savedFolderId != null) onSaved(savedFolderId);
            } finally {
              _applying.remove(row.id);
            }
          }
          _reportError(job);
        } catch (error) {
          if (latest.isAwaitingSelection) continue;
          if (!_disposed &&
              !_changing.contains(row.id) &&
              mutationVersion == (_mutationVersions[row.id] ?? 0)) {
            final failed = PdfImportJob({
              ...latest.data,
              'error': error is AppFailure
                  ? error.message
                  : '작업 상태 확인에 실패했어요. 연결되면 다시 확인합니다.',
            });
            await jobs.update(failed);
            _reportError(failed);
          }
        }
      }
    } catch (_) {
      // Local store/credentials may be closing. The next foreground poll retries.
    }
  }

  Future<void> move(String id, String folderId) async {
    if (!_changing.add(id)) {
      throw const ValidationFailure('작업 요청을 처리 중이에요. 잠시 후 다시 시도해 주세요.');
    }
    _mutationVersions[id] = (_mutationVersions[id] ?? 0) + 1;
    try {
      await _applying[id];
      final previousFolderId = await jobs.move(
        id,
        folderId,
        moveAppliedSource: () => sources.moveSource(id: id, folderId: folderId),
      );
      if (!_disposed && previousFolderId != folderId) {
        onSaved(previousFolderId);
        onSaved(folderId);
      }
    } finally {
      _changing.remove(id);
    }
  }

  Future<void> delete(String id) async {
    if (_uploading.contains(id) || !_changing.add(id)) {
      throw const ValidationFailure('작업 요청을 처리 중이에요. 잠시 후 다시 시도해 주세요.');
    }
    _mutationVersions[id] = (_mutationVersions[id] ?? 0) + 1;
    try {
      // Invalidate late status/result responses. Only wait for this job's
      // in-flight local import, not unrelated jobs or slow network polling.
      await _applying[id];
      final row = await jobs.get(id);
      if (row == null) return;
      if (row.applied) {
        throw const ValidationFailure('분석이 완료된 자료는 폴더의 자료 삭제 메뉴를 사용해 주세요.');
      }
      final configuration = await credentials.readConfiguration();
      if (configuration == null ||
          _normalize(row.serverUrl) != _normalize(configuration.serverUrl)) {
        throw const ValidationFailure('작업을 등록한 서버에 연결해 주세요.');
      }
      await api.deleteJob(configuration, id);
      await jobs.remove(id);
      _deleted.add(id);
      _reportedErrors.remove(id);
    } finally {
      _changing.remove(id);
    }
  }

  Future<void> change(String id, String action) async {
    if (!_changing.add(id)) return;
    _mutationVersions[id] = (_mutationVersions[id] ?? 0) + 1;
    try {
      final row = await jobs.get(id);
      final configuration = await credentials.readConfiguration();
      if (row == null ||
          configuration == null ||
          _normalize(row.serverUrl) != _normalize(configuration.serverUrl)) {
        throw const ValidationFailure('작업을 등록한 서버에 연결해 주세요.');
      }
      final job = await api.changeJob(configuration, id, action);
      if (!_disposed) {
        await jobs.update(job);
        _reportError(job);
      }
    } finally {
      _changing.remove(id);
    }
  }

  String _normalize(String url) => url.replaceFirst(RegExp(r'/+$'), '');

  Future<SyncConfiguration> _extractionConfiguration(
    String id, {
    bool allowUntracked = false,
  }) async {
    final row = await jobs.get(id);
    final config = await credentials.readConfiguration();
    if (config == null ||
        (row == null && !allowUntracked) ||
        (row != null &&
            _normalize(row.serverUrl) != _normalize(config.serverUrl))) {
      throw const ValidationFailure('작업을 등록한 서버에 연결해 주세요.');
    }
    if (api is! RemoteDocumentExtractionApi) {
      throw const ValidationFailure('서버를 업데이트하면 PDF 직접 추출을 사용할 수 있어요.');
    }
    return config;
  }

  Future<PdfExtractionOverview> extractionOverview(String id) async =>
      (api as RemoteDocumentExtractionApi).extractionOverview(
        await _extractionConfiguration(id),
        id,
      );

  Future<PdfExtractionPreflight> preflight(
    String id,
    Map<String, Object?> selection,
  ) async => (api as RemoteDocumentExtractionApi).preflight(
    await _extractionConfiguration(id),
    id,
    selection,
  );

  Future<Uint8List> extractionImage(String id, int page) async {
    final config = await _extractionConfiguration(id, allowUntracked: true);
    return (api as RemoteDocumentExtractionApi).extractionImage(
      config,
      id,
      page,
    );
  }

  Future<void> startExtraction(
    String id,
    Map<String, Object?> selection,
  ) async {
    if (!_changing.add(id)) throw const ValidationFailure('작업 요청을 처리 중이에요.');
    _mutationVersions[id] = (_mutationVersions[id] ?? 0) + 1;
    try {
      final config = await _extractionConfiguration(id);
      final job = await (api as RemoteDocumentExtractionApi).startExtraction(
        config,
        id,
        selection,
      );
      if (!_disposed) {
        await jobs.update(job);
        _reportError(job);
      }
    } finally {
      _changing.remove(id);
    }
    if (!_disposed) unawaited(poll());
  }
}
