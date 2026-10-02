import 'dart:async';

import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

import 'fake_documents.dart';

class FakePdfJobsApi extends FakeConceptRevisionApi
    implements RemoteDocumentJobApi {
  final Map<String, PdfImportJob> jobs = {};
  final List<String> actions = [];
  bool offline = false;
  bool loseReceipt = false;
  int maximumBytes = 200 * 1024 * 1024;
  int reads = 0;
  int results = 0;
  Completer<PdfImportJob?>? getGate;
  @override
  Future<int> maximumUploadBytes(SyncConfiguration configuration) async =>
      maximumBytes;
  @override
  Future<PdfImportJob> uploadJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  ) async {
    await for (final chunk in document.openRead()) {
      reads += chunk.length;
    }
    final job = pdfJob(id, status: 'queued');
    jobs[id] = job;
    if (loseReceipt) throw const NetworkFailure('응답 유실');
    return job;
  }

  @override
  Future<PdfImportJob?> getJob(
    SyncConfiguration configuration,
    String id,
  ) async {
    if (offline) throw const NetworkFailure('연결 실패');
    if (getGate != null) return getGate!.future;
    return jobs[id];
  }

  @override
  Future<PdfImportJob> changeJob(
    SyncConfiguration configuration,
    String id,
    String action,
  ) async {
    actions.add(action);
    return jobs[id] = pdfJob(
      id,
      status: action == 'cancel' ? 'cancelled' : 'queued',
    );
  }

  @override
  Future<DocumentImportResult> jobResult(
    SyncConfiguration configuration,
    String id,
  ) async {
    results++;
    return pdfResult(id);
  }
}

PdfImportJob pdfJob(
  String id, {
  String status = 'running',
  int completedPages = 12,
}) => PdfImportJob({
  'id': id,
  'fileName': '긴 강의.pdf',
  'status': status,
  'stage': 'pages',
  'completedPages': completedPages,
  'totalPages': 80,
  'completedChunks': 0,
  'totalChunks': 0,
  'visionModel': 'pinned-vision',
  'conceptModel': 'pinned-concepts',
});
DocumentImportResult pdfResult(String id) => DocumentImportResult(
  source: ImportedSource(
    id: id,
    fileName: '긴 강의.pdf',
    contentHash: 'hash',
    pageCount: 80,
    extractionMethod: 'visionOcr',
    importedAt: DateTime.utc(2026),
  ),
  concepts: const [
    ImportedConcept(title: '학습 개념', content: '검토할 개념 내용', pageNumbers: [1]),
  ],
);
