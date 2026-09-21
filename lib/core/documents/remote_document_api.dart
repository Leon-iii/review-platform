import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

abstract interface class RemoteDocumentApi {
  Future<DocumentImportResult> importPdf({
    required SyncConfiguration configuration,
    required String fileName,
    required Uint8List bytes,
  });
}

class HttpRemoteDocumentApi implements RemoteDocumentApi {
  HttpRemoteDocumentApi(this._client);

  final http.Client _client;

  @override
  Future<DocumentImportResult> importPdf({
    required SyncConfiguration configuration,
    required String fileName,
    required Uint8List bytes,
  }) async {
    http.StreamedResponse streamedResponse;
    try {
      final request = http.MultipartRequest(
        'POST',
        _endpoint(configuration.serverUrl),
      )..headers['x-sync-token'] = configuration.accessToken;
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: fileName),
      );
      streamedResponse = await _client
          .send(request)
          .timeout(const Duration(minutes: 10));
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        NetworkFailure('PDF 처리 서버에 연결할 수 없어요.', cause: error),
        stackTrace,
      );
    }

    final response = await http.Response.fromStream(streamedResponse);
    final body = _decode(response);
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

  ImportedConcept _concept(Map<String, Object?> json) {
    if (json['status'] != 'draft') {
      throw const FormatException('Imported concept is not a draft.');
    }
    return ImportedConcept(
      title: json['title']! as String,
      summary: json['summary']! as String,
      details: json['details']! as String,
      pageNumbers: [
        for (final page in json['pageNumbers']! as List) (page as num).toInt(),
      ],
    );
  }

  Map<String, Object?> _decode(http.Response response) {
    Map<String, Object?>? body;
    try {
      body = Map<String, Object?>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const NetworkFailure('PDF 처리 응답 형식이 올바르지 않아요.');
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

  Uri _endpoint(String serverUrl) {
    final normalized = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return Uri.parse('$normalized/api/documents/import');
  }
}
