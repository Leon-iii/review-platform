import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/domain/models/document_extraction.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

import 'fake_pdf_jobs.dart';

class FakePdfExtractionApi extends FakePdfJobsApi
    implements RemoteDocumentExtractionApi {
  Uint8List? previewBytes;
  String provider = 'openai';
  int revision = 0, starts = 0, checks = 0;
  String status = 'warning';
  int? outputBudget = 128000;
  Map<String, Object?>? outputEstimate;
  Map<String, Object?>? lastSelection;
  Completer<PdfImportJob>? startGate;
  Completer<void>? checkGate;
  Object? checkError;
  final List<int> previewPages = [];
  PdfExtractionPreflight? lastCheck;
  @override
  Future<PdfImportJob> prepareJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  ) async => jobs[id] = PdfImportJob({
    ...pdfJob(id).data,
    'fileName': document.fileName,
    'status': 'awaiting_selection',
    'extractionMode': 'unselected',
  });
  @override
  Future<PdfExtractionOverview> extractionOverview(
    SyncConfiguration configuration,
    String id,
  ) async => PdfExtractionOverview({
    'fileName': '여러 슬라이드에 걸쳐진 아주 긴 강의자료 이름 테스트.pdf',
    'fileSize': 3000000,
    'pageCount': 3,
    'revision': revision,
    'conceptProvider': provider,
    'conceptModel': 'gpt-6-luna',
    'splitAfterPages': lastSelection?['splitAfterPages'] ?? <int>[],
    'mode': lastSelection?['mode'] ?? 'unselected',
    'preflight': lastCheck?.data,
  });
  @override
  Future<PdfExtractionPreflight> preflight(
    SyncConfiguration configuration,
    String id,
    Map<String, Object?> selection,
  ) async {
    checks++;
    if (checkGate != null) await checkGate!.future;
    if (checkError != null) throw checkError!;
    revision++;
    lastSelection = selection;
    return lastCheck = PdfExtractionPreflight({
      'revision': revision,
      'status': status,
      'parts': [
        {
          'range': {'firstPage': 1, 'lastPage': 3},
          'inputTokens': status == 'blocked' ? 600000 : 1000,
          'outputBudget': outputBudget,
          'estimatedOutputTokens': outputEstimate?['tokens'],
          'outputSafetyThresholdTokens': 64000,
          'outputEstimate':
              outputEstimate ??
              {
                'tokens': null,
                'lowerTokens': null,
                'upperTokens': null,
                'sampleCount': 0,
                'confidence': 'insufficient',
              },
          'status': status,
          'messages': [
            status == 'blocked'
                ? '개념 경계를 보고 직접 분할해 주세요.'
                : 'TPM은 서버 설정 기준이며 실제 사용량은 확인되지 않았습니다.',
          ],
        },
      ],
    });
  }

  @override
  Future<PdfImportJob> startExtraction(
    SyncConfiguration configuration,
    String id,
    Map<String, Object?> selection,
  ) async {
    starts++;
    lastSelection = selection;
    if (startGate != null) return startGate!.future;
    return jobs[id] = PdfImportJob({
      ...jobs[id]!.data,
      'status': 'queued',
      'extractionMode': selection['mode'],
    });
  }

  @override
  Future<Uint8List> extractionImage(
    SyncConfiguration configuration,
    String id,
    int page,
  ) async {
    previewPages.add(page);
    return previewBytes ??
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII=',
        );
  }
}
