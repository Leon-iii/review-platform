import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://127.0.0.1:5080/',
    accessToken: 'private-token',
  );

  test('PDF multipart 요청을 보내고 Source와 Draft Concept을 파싱한다', () async {
    late http.Request captured;
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'source': {
              'id': 'source-1',
              'fileName': '전자기학.pdf',
              'contentHash': List.filled(64, 'a').join(),
              'pageCount': 12,
              'extractionMethod': 'textLayer',
              'importedAt': '2026-09-19T00:00:00Z',
            },
            'concepts': [
              {
                'title': '가우스 법칙',
                'summary': '전기선속과 전하의 관계',
                'details': '폐곡면을 기준으로 설명한다.',
                'pageNumbers': [3, 4],
                'status': 'draft',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await api.importPdf(
      configuration: configuration,
      fileName: '전자기학.pdf',
      bytes: Uint8List.fromList(utf8.encode('%PDF-test')),
    );

    expect(captured.url.path, '/api/documents/import');
    expect(captured.headers['x-sync-token'], 'private-token');
    expect(captured.headers['content-type'], startsWith('multipart/form-data'));
    expect(captured.body, contains('전자기학.pdf'));
    expect(result.source.pageCount, 12);
    expect(result.concepts.single.pageNumbers, [3, 4]);
  });

  test('PDF 처리 오류의 안전한 서버 메시지를 전달한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient(
        (request) async => http.Response(
          jsonEncode({'error': 'PDF에서 텍스트 레이어를 찾지 못했습니다.'}),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      api.importPdf(
        configuration: configuration,
        fileName: '스캔.pdf',
        bytes: Uint8List.fromList(utf8.encode('%PDF-test')),
      ),
      throwsA(
        isA<NetworkFailure>().having(
          (error) => error.message,
          'message',
          contains('텍스트 레이어'),
        ),
      ),
    );
  });
}
