import 'dart:async';

import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_credentials_store.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/repositories/document_job_repository.dart';
import 'package:review_platform/repositories/source_repository.dart';
import 'package:uuid/uuid.dart';

class DocumentJobCoordinator {
  DocumentJobCoordinator(
    this.api,
    this.jobs,
    this.sources,
    this.credentials,
    this.onSaved,
  );
  final RemoteDocumentJobApi api;
  final DocumentJobRepository jobs;
  final SourceRepository sources;
  final SyncCredentialsStore credentials;
  final void Function(String folderId) onSaved;
  Timer? _timer;
  Future<void>? _polling;
  bool _disposed = false;
  final Set<String> _uploading = {};
  final Set<String> _changing = {};
  final Map<String, int> _mutationVersions = {};

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
          await jobs.update(
            PdfImportJob({
              ...initial.data,
              'error': error is AppFailure
                  ? error.message
                  : 'PDF 업로드를 확인하지 못했어요.',
            }),
          );
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
      for (final row in rows) {
        if (_disposed) break;
        final previous = DocumentJobRepository.job(row);
        if (_uploading.contains(row.id) ||
            _changing.contains(row.id) ||
            _normalize(row.serverUrl) != _normalize(configuration.serverUrl) ||
            !(previous.isActive ||
                previous.status == 'uploading' ||
                previous.status == 'completed')) {
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
            await jobs.update(
              PdfImportJob({
                ...previous.data,
                'status': 'uploadFailed',
                'error': '서버에서 업로드를 찾지 못했어요. PDF 파일을 다시 선택해 주세요.',
              }),
            );
            continue;
          }
          await jobs.update(job);
          latest = job;
          if (job.status == 'completed') {
            final result = await api.jobResult(configuration, row.id);
            if (_disposed) break;
            if (result.source.id != row.id) {
              throw const NetworkFailure('PDF 작업 ID와 결과가 일치하지 않아요.');
            }
            await jobs.applyResult(row.id, () async {
              await sources.saveImport(folderId: row.folderId, result: result);
            });
            if (!_disposed) onSaved(row.folderId);
          }
        } catch (error) {
          if (!_disposed &&
              !_changing.contains(row.id) &&
              mutationVersion == (_mutationVersions[row.id] ?? 0)) {
            await jobs.update(
              PdfImportJob({
                ...latest.data,
                'error': error is AppFailure
                    ? error.message
                    : '작업 상태 확인에 실패했어요. 연결되면 다시 확인합니다.',
              }),
            );
          }
        }
      }
    } catch (_) {
      // Local store/credentials may be closing. The next foreground poll retries.
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
      if (!_disposed) await jobs.update(job);
    } finally {
      _changing.remove(id);
    }
  }

  String _normalize(String url) => url.replaceFirst(RegExp(r'/+$'), '');
}
