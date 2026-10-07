import 'dart:convert';
import 'dart:typed_data';

import 'package:review_platform/domain/models/document_extraction.dart';

import 'package:http/http.dart' as http;
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/domain/models/pdf_import_job.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class RemoteDocumentApi {
  Future<void> deletePdf({
    required SyncConfiguration configuration,
    required String sourceId,
  });

  Future<List<ConceptRevision>> reviseConcepts({
    required SyncConfiguration configuration,
    required StudySource source,
    required List<StudyConcept> concepts,
    required String instruction,
    required Set<String> targetConceptIds,
    bool allowAdditions = false,
    bool allowDeletions = false,
  });
}

abstract interface class RemoteDocumentJobApi {
  Future<int> maximumUploadBytes(SyncConfiguration configuration);
  Future<PdfImportJob> uploadJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  );
  Future<PdfImportJob?> getJob(SyncConfiguration configuration, String id);
  Future<void> deleteJob(SyncConfiguration configuration, String id);
  Future<PdfImportJob> changeJob(
    SyncConfiguration configuration,
    String id,
    String action,
  );
  Future<DocumentImportResult> jobResult(
    SyncConfiguration configuration,
    String id,
  );
}

abstract interface class RemoteDocumentExtractionApi {
  Future<PdfImportJob> prepareJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  );
  Future<PdfExtractionOverview> extractionOverview(
    SyncConfiguration configuration,
    String id,
  );
  Future<PdfExtractionPreflight> preflight(
    SyncConfiguration configuration,
    String id,
    Map<String, Object?> selection,
  );
  Future<PdfImportJob> startExtraction(
    SyncConfiguration configuration,
    String id,
    Map<String, Object?> selection,
  );
  Future<Uint8List> extractionImage(
    SyncConfiguration configuration,
    String id,
    int page,
  );
}

class _PdfUploadRequest extends http.BaseRequest {
  _PdfUploadRequest(Uri url, this.document) : super('POST', url) {
    contentLength = document.length;
    headers['content-type'] = 'application/pdf';
  }
  final PickedPdfDocument document;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(document.openRead());
  }
}

class HttpRemoteDocumentApi
    implements
        RemoteDocumentApi,
        RemoteDocumentJobApi,
        RemoteDocumentExtractionApi {
  HttpRemoteDocumentApi(this._client);

  final http.Client _client;

  DocumentImportResult _importResult(Map<String, Object?> body) {
    try {
      final source = Map<String, Object?>.from(body['source']! as Map);
      final concepts = body['concepts']! as List;
      return DocumentImportResult(
        source: ImportedSource(
          id: source['id']! as String,
          fileName: source['fileName']! as String,
          contentHash: source['contentHash']! as String,
          pageCount: (source['pageCount']! as num).toInt(),
          extractionMethod: source['extractionMethod']! as String,
          importedAt: DateTime.parse(source['importedAt']! as String).toUtc(),
        ),
        concepts: [
          for (final raw in concepts)
            _concept(Map<String, Object?>.from(raw as Map)),
        ],
      );
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('PDF 처리 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<int> maximumUploadBytes(SyncConfiguration configuration) async {
    final body = _decode(await _jobRequest(configuration, 'GET', 'limits'));
    if (body['supportsDirectPdfOnly'] != true) {
      throw const ValidationFailure(
        '서버를 업데이트하고 다시 시작해 주세요. PDF 직접 추출 전용 서버가 필요해요.',
      );
    }
    return (body['maximumFileSize']! as num).toInt();
  }

  @override
  Future<PdfImportJob> uploadJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  ) async {
    final request = _PdfUploadRequest(
      _jobUri(
        configuration,
        'jobs/$id',
      ).replace(queryParameters: {'fileName': document.fileName}),
      document,
    )..headers['x-sync-token'] = configuration.accessToken;
    try {
      final streamed = await _client
          .send(request)
          .timeout(const Duration(minutes: 5));
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 30));
      return _job(_decode(response));
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure(
          'PDF 업로드를 확인하지 못했어요. 서버 연결 후 작업 상태를 다시 확인합니다.',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  @override
  Future<PdfImportJob> prepareJob(
    SyncConfiguration configuration,
    String id,
    PickedPdfDocument document,
  ) async {
    await maximumUploadBytes(configuration);
    return uploadJob(configuration, id, document);
  }

  @override
  Future<PdfExtractionOverview> extractionOverview(
    SyncConfiguration configuration,
    String id,
  ) async => _extractionResponse(
    _decode(await _jobRequest(configuration, 'GET', 'jobs/$id/extraction')),
    PdfExtractionOverview.new,
  );

  @override
  Future<PdfExtractionPreflight> preflight(
    SyncConfiguration configuration,
    String id,
    Map<String, Object?> selection,
  ) async => _extractionResponse(
    _decode(
      await _jobRequest(
        configuration,
        'POST',
        'jobs/$id/extraction/preflight',
        body: selection,
        timeout: const Duration(minutes: 20),
      ),
    ),
    PdfExtractionPreflight.new,
  );

  T _extractionResponse<T>(
    Map<String, Object?> data,
    T Function(Map<String, Object?>) parse,
  ) {
    try {
      return parse(data);
    } catch (error) {
      throw NetworkFailure('PDF 추출 설정 응답 형식이 올바르지 않아요.', cause: error);
    }
  }

  @override
  Future<PdfImportJob> startExtraction(
    SyncConfiguration configuration,
    String id,
    Map<String, Object?> selection,
  ) async => _job(
    _decode(
      await _jobRequest(
        configuration,
        'POST',
        'jobs/$id/extraction/start',
        body: selection,
      ),
    ),
  );

  @override
  Future<Uint8List> extractionImage(
    SyncConfiguration configuration,
    String id,
    int page,
  ) async {
    final response = await _jobRequest(
      configuration,
      'GET',
      'jobs/$id/extraction/pages/$page/image',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _decode(response);
    }
    if (!(response.headers['content-type'] ?? '').startsWith('image/') ||
        response.bodyBytes.length > 12 * 1024 * 1024) {
      throw const NetworkFailure('PDF 원본 이미지 응답이 올바르지 않아요.');
    }
    return response.bodyBytes;
  }

  @override
  Future<PdfImportJob?> getJob(
    SyncConfiguration configuration,
    String id,
  ) async {
    final response = await _jobRequest(configuration, 'GET', 'jobs/$id');
    if (response.statusCode == 404) return null;
    return _job(_decode(response));
  }

  @override
  Future<void> deleteJob(SyncConfiguration configuration, String id) async {
    final response = await _jobRequest(configuration, 'DELETE', 'jobs/$id');
    if (response.statusCode == 204 || response.statusCode == 404) return;
    _decode(response);
    throw const NetworkFailure('PDF 작업 삭제 응답 형식이 올바르지 않아요.');
  }

  @override
  Future<PdfImportJob> changeJob(
    SyncConfiguration configuration,
    String id,
    String action,
  ) async {
    if (action != 'cancel' && action != 'retry') {
      throw const ValidationFailure('올바르지 않은 작업 요청이에요.');
    }
    return _job(
      _decode(await _jobRequest(configuration, 'POST', 'jobs/$id/$action')),
    );
  }

  @override
  Future<DocumentImportResult> jobResult(
    SyncConfiguration configuration,
    String id,
  ) async => _importResult(
    _decode(await _jobRequest(configuration, 'GET', 'jobs/$id/result')),
  );

  PdfImportJob _job(Map<String, Object?> data) {
    if (data['id'] is! String ||
        data['fileName'] is! String ||
        !{
          'queued',
          'running',
          'failed',
          'cancelled',
          'completed',
          'awaiting_review',
          'awaiting_selection',
        }.contains(data['status'])) {
      throw const NetworkFailure('PDF 작업 응답 형식이 올바르지 않아요.');
    }
    return PdfImportJob(data);
  }

  Uri _jobUri(SyncConfiguration configuration, String path) => Uri.parse(
    '${configuration.serverUrl.replaceFirst(RegExp(r'/+$'), '')}/api/documents/$path',
  );

  Future<http.Response> _jobRequest(
    SyncConfiguration configuration,
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final request = http.Request(method, _jobUri(configuration, path))
        ..headers['x-sync-token'] = configuration.accessToken;
      if (body != null) {
        request.headers['content-type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(body);
      }
      return await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('PDF 처리 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }
  }

  @override
  Future<void> deletePdf({
    required SyncConfiguration configuration,
    required String sourceId,
  }) async {
    http.Response response;
    try {
      response = await _client
          .delete(
            _sourceEndpoint(configuration.serverUrl, sourceId),
            headers: {'x-sync-token': configuration.accessToken},
          )
          .timeout(const Duration(seconds: 30));
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('PDF 처리 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }
    if (response.statusCode == 401) {
      throw const NetworkFailure('서버 접근 토큰이 올바르지 않아요.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? message;
      try {
        final body = Map<String, Object?>.from(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map,
        );
        message = body['error'] as String?;
      } catch (_) {
        // Use the safe fallback below.
      }
      throw NetworkFailure(
        message?.isNotEmpty == true
            ? message!
            : 'PDF 삭제에 실패했어요. (${response.statusCode})',
      );
    }
  }

  @override
  Future<List<ConceptRevision>> reviseConcepts({
    required SyncConfiguration configuration,
    required StudySource source,
    required List<StudyConcept> concepts,
    required String instruction,
    required Set<String> targetConceptIds,
    bool allowAdditions = false,
    bool allowDeletions = false,
  }) async {
    http.Response response;
    try {
      response = await _client
          .post(
            _revisionEndpoint(configuration.serverUrl),
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'x-sync-token': configuration.accessToken,
            },
            body: jsonEncode({
              'sourceId': source.id,
              'fileName': source.fileName,
              'pageCount': source.pageCount,
              'instruction': instruction,
              'targetConceptIds': targetConceptIds.toList(growable: false),
              'allowAdditions': allowAdditions,
              'allowDeletions': allowDeletions,
              'concepts': [
                for (final concept in concepts)
                  {
                    'id': concept.id,
                    'title': concept.title,
                    'content': concept.content,
                    'pageNumbers': concept.pageNumbers,
                    'status': concept.status.name,
                    'importance': concept.importance.name,
                  },
              ],
            }),
          )
          .timeout(const Duration(minutes: 12));
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('개념 수정 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }

    final body = _decode(
      response,
      invalidSuccessMessage: '개념 수정 응답 형식이 올바르지 않아요.',
    );
    try {
      return [
        for (final raw in body['revisions']! as List)
          _revision(Map<String, Object?>.from(raw as Map)),
        for (final (index, raw) in ((body['additions'] as List?) ?? []).indexed)
          _revision({
            ...Map<String, Object?>.from(raw as Map),
            'id': 'addition-$index',
          }, kind: ConceptChangeKind.add),
        for (final raw in (body['deletions'] as List?) ?? [])
          _revision({
            ...Map<String, Object?>.from(raw as Map),
            'title': '',
            'content': '',
            'pageNumbers': <int>[],
            'importance': 'medium',
          }, kind: ConceptChangeKind.delete),
      ];
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('개념 수정 응답 형식이 올바르지 않아요.', cause: error),
        stackTrace,
      );
    }
  }

  ImportedConcept _concept(Map<String, Object?> json) {
    if (json['status'] != 'held') {
      throw const FormatException('Imported concept is not held.');
    }
    return ImportedConcept(
      title: json['title']! as String,
      content: json['content']! as String,
      pageNumbers: [
        for (final page in json['pageNumbers']! as List) (page as num).toInt(),
      ],
      importance: ConceptImportance.fromStorage(json['importance'] as String?),
    );
  }

  ConceptRevision _revision(
    Map<String, Object?> json, {
    ConceptChangeKind kind = ConceptChangeKind.update,
  }) => ConceptRevision(
    id: json['id']! as String,
    title: json['title']! as String,
    content: json['content']! as String,
    pageNumbers: [
      for (final page in json['pageNumbers']! as List) (page as num).toInt(),
    ],
    importance: ConceptImportance.fromStorage(json['importance'] as String?),
    kind: kind,
    groupId: json['groupId'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
  );

  Map<String, Object?> _decode(
    http.Response response, {
    String invalidSuccessMessage = 'PDF 처리 응답 형식이 올바르지 않아요.',
  }) {
    Map<String, Object?>? body;
    try {
      body = Map<String, Object?>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw NetworkFailure(invalidSuccessMessage);
      }
    }
    if (response.statusCode == 401) {
      throw const NetworkFailure('서버 접근 토큰이 올바르지 않아요.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body?['error'];
      throw NetworkFailure(
        error is String && error.isNotEmpty
            ? error
            : 'PDF 처리에 실패했어요. (${response.statusCode})',
      );
    }
    return body!;
  }

  Uri _sourceEndpoint(String serverUrl, String sourceId) {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return Uri.parse(
      '$normalized/api/documents/${Uri.encodeComponent(sourceId)}',
    );
  }

  Uri _revisionEndpoint(String serverUrl) {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return Uri.parse('$normalized/api/documents/concepts/revise');
  }
}
