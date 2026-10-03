import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/domain/models/document_ocr_review.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

import 'fake_documents.dart';

class FakePdfJobsApi extends FakeConceptRevisionApi
    implements RemoteDocumentJobApi, RemoteDocumentReviewApi {
  final Map<String, PdfImportJob> jobs = {};
  final List<String> actions = [];
  final List<String> deletedJobs = [];
  Object? deleteError;
  Completer<DocumentImportResult>? resultGate;
  bool offline = false;
  bool loseReceipt = false;
  int maximumBytes = 200 * 1024 * 1024;
  int reads = 0;
  int results = 0;
  final List<String> statusReads = [];
  Completer<PdfImportJob?>? getGate;
  bool? reviewBeforeConcepts;
  final Map<int, List<OcrReviewBlock>> reviewBlocks = {};
  int reviewRevision = 0;
  int reviewSaves = 0;
  bool reviewOffline = false;
  final List<int> previewReads = [];
  Object? previewError;
  Uint8List? previewBytes;
  String originalReviewText = '원래 추출 텍스트';
  final List<OcrReviewBlock> originalReviewBlocks = const [
    OcrReviewBlock(text: '역사적 연도와 인물에 관한 연표 내용입니다.'),
    OcrReviewBlock(
      text: '박스 속 상호연결 원칙의 상세한 설명입니다.',
      visualRegion: true,
      kind: OcrContentKind.diagram,
    ),
  ];
  @override
  Future<int> maximumUploadBytes(SyncConfiguration configuration) async =>
      maximumBytes;
  @override
  Future<PdfImportJob> uploadJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document, {
    bool reviewBeforeConcepts = false,
  }) async {
    this.reviewBeforeConcepts = reviewBeforeConcepts;
    await for (final chunk in document.openRead()) {
      reads += chunk.length;
    }
    final job = pdfJob(id, status: 'queued');
    jobs[id] = job;
    if (loseReceipt) throw const NetworkFailure('응답 유실');
    return job;
  }

  @override
  Future<OcrReviewPage> reviewPage(
    SyncConfiguration configuration,
    String id,
    int page,
  ) async {
    if (reviewOffline) throw const NetworkFailure('OCR 검토 연결 실패');
    return OcrReviewPage(
      pageNumber: page,
      totalPages: 2,
      originalText: originalReviewText,
      blocks: reviewBlocks[page] ?? originalReviewBlocks,
      originalBlocks: originalReviewBlocks,
      revision: reviewRevision,
      edited: reviewBlocks.containsKey(page),
      readOnly: jobs[id]?.status == 'completed',
    );
  }

  @override
  Future<OcrReviewPage> saveReviewPage(
    SyncConfiguration configuration,
    String id,
    int page,
    int revision,
    List<OcrReviewBlock> blocks,
  ) async {
    if (reviewOffline) throw const NetworkFailure('OCR 검토 연결 실패');
    if (revision != reviewRevision) {
      throw const ValidationFailure('다른 화면에서 검토 내용이 변경되었습니다.');
    }
    reviewRevision++;
    reviewSaves++;
    reviewBlocks[page] = blocks;
    return reviewPage(configuration, id, page);
  }

  @override
  Future<Uint8List> reviewImage(
    SyncConfiguration configuration,
    String id,
    int page,
  ) async {
    previewReads.add(page);
    if (previewError != null) throw previewError!;
    if (previewBytes != null) return previewBytes!;
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII=',
    );
  }

  @override
  Future<PdfImportJob> confirmReview(
    SyncConfiguration configuration,
    String id,
    int revision,
  ) async {
    if (reviewOffline) throw const NetworkFailure('OCR 검토 연결 실패');
    if (revision != reviewRevision) {
      throw const ValidationFailure('다른 화면에서 검토 내용이 변경되었습니다.');
    }
    actions.add('confirm-review');
    return jobs[id] = pdfJob(id, status: 'queued');
  }

  @override
  Future<PdfImportJob?> getJob(
    SyncConfiguration configuration,
    String id,
  ) async {
    statusReads.add(id);
    if (offline) throw const NetworkFailure('연결 실패');
    if (getGate != null) return getGate!.future;
    return jobs[id];
  }

  @override
  Future<void> deleteJob(SyncConfiguration configuration, String id) async {
    if (deleteError != null) throw deleteError!;
    if (offline) throw const NetworkFailure('연결 실패');
    deletedJobs.add(id);
    jobs.remove(id);
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
    if (resultGate != null) return resultGate!.future;
    return pdfResult(id);
  }
}

PdfImportJob pdfJob(
  String id, {
  String status = 'running',
  int completedPages = 12,
  String? error,
}) => PdfImportJob({
  'id': id,
  'fileName': '긴 강의.pdf',
  'status': status,
  'error': ?error,
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
