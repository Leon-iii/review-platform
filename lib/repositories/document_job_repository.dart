import 'dart:convert';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';

class DocumentJobRepository {
  DocumentJobRepository(this.database);
  final AppDatabase database;
  final _changes = StreamController<void>.broadcast(sync: true);
  void dispose() => unawaited(_changes.close());
  // All job writes use this repository. Listen before reading, and serialize
  // refreshes so a stale query cannot replace a newer progress snapshot.
  Stream<T> _watch<T>(Future<T> Function() query) =>
      Stream<T>.multi((controller) {
        var cancelled = false;
        Future<void> pending = Future.value();
        void refresh() {
          pending = pending.then((_) async {
            if (cancelled) return;
            try {
              final value = await query();
              if (!cancelled) controller.add(value);
            } catch (error, stackTrace) {
              if (!cancelled) controller.addError(error, stackTrace);
            }
          });
        }

        final subscription = _changes.stream.listen((_) => refresh());
        controller.onCancel = () {
          cancelled = true;
          unawaited(subscription.cancel());
        };
        refresh();
      });
  Stream<List<TrackedPdfImportJob>> watchFolder(String folderId) =>
      _watch(() async {
        final rows =
            await (database.select(database.documentJobs)..where(
                  (row) =>
                      row.folderId.equals(folderId) & row.applied.equals(false),
                ))
                .get();
        return rows.map(_tracked).toList();
      });
  Stream<TrackedPdfImportJob?> watchJob(String id) => _watch(() async {
    final row = await get(id);
    return row == null ? null : _tracked(row);
  });
  static TrackedPdfImportJob _tracked(DocumentJobRow row) =>
      TrackedPdfImportJob(job: job(row), applied: row.applied);
  Future<List<DocumentJobRow>> pending() => (database.select(
    database.documentJobs,
  )..where((row) => row.applied.equals(false))).get();
  Future<DocumentJobRow?> get(String id) => (database.select(
    database.documentJobs,
  )..where((row) => row.id.equals(id))).getSingleOrNull();
  Future<void> add({
    required String folderId,
    required String serverUrl,
    required PdfImportJob job,
  }) async {
    await database
        .into(database.documentJobs)
        .insert(
          DocumentJobsCompanion.insert(
            id: job.id,
            folderId: folderId,
            serverUrl: serverUrl,
            statusJson: jsonEncode(job.data),
          ),
        );
    _notify();
  }

  Future<void> update(PdfImportJob job) async {
    await (database.update(database.documentJobs)
          ..where((row) => row.id.equals(job.id)))
        .write(DocumentJobsCompanion(statusJson: Value(jsonEncode(job.data))));
    _notify();
  }

  Future<String?> applyResult(
    String id,
    Future<void> Function(String folderId) save,
  ) async {
    final folderId = await database.transaction(() async {
      final row = await get(id);
      if (row == null || row.applied) return null;
      // Use the current destination, never a folder captured before polling.
      await save(row.folderId);
      await (database.update(database.documentJobs)
            ..where((row) => row.id.equals(id)))
          .write(const DocumentJobsCompanion(applied: Value(true)));
      return row.folderId;
    });
    _notify();
    return folderId;
  }

  Future<String> move(
    String id,
    String folderId, {
    required Future<void> Function() moveAppliedSource,
  }) async {
    final previousFolderId = await database.transaction(() async {
      if (await database.folderDao.getActiveFolder(folderId) == null) {
        throw const ValidationFailure('자료를 이동할 폴더를 찾을 수 없어요.');
      }
      final row = await get(id);
      if (row == null) throw const ValidationFailure('PDF 작업을 찾을 수 없어요.');
      if (row.folderId == folderId) return row.folderId;
      // Extraction can finish while the folder picker is open. In that case,
      // move the material too, using its normal synchronization pipeline.
      if (row.applied) await moveAppliedSource();
      await (database.update(database.documentJobs)
            ..where((row) => row.id.equals(id)))
          .write(DocumentJobsCompanion(folderId: Value(folderId)));
      return row.folderId;
    });
    _notify();
    return previousFolderId;
  }

  Future<void> remove(String id) async {
    await (database.delete(
      database.documentJobs,
    )..where((row) => row.id.equals(id) & row.applied.equals(false))).go();
    _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static PdfImportJob job(DocumentJobRow row) => PdfImportJob(
    Map<String, Object?>.from(jsonDecode(row.statusJson) as Map),
  );
}
