import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/study_source.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://127.0.0.1:5080/',
    accessToken: 'private-token',
  );

  test('PDF multipart 요청을 보내고 Source와 보류된 Concept을 파싱한다', () async {
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
                'content': '전기선속과 전하의 관계를 폐곡면을 기준으로 설명한다.',
                'pageNumbers': [3, 4],
                'status': 'held',
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
    expect(result.concepts.single.content, contains('폐곡면'));
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

  test('서버의 PDF 원본 삭제 API를 호출한다', () async {
    late http.Request captured;
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      }),
    );

    await api.deletePdf(configuration: configuration, sourceId: 'source-1');

    expect(captured.method, 'DELETE');
    expect(captured.url.path, '/api/documents/source-1');
    expect(captured.headers['x-sync-token'], 'private-token');
  });

  test('모든 개념을 포함한 수정 요청을 보내고 수정안을 파싱한다', () async {
    late http.Request captured;
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'revisions': [
              {
                'id': 'concept-1',
                'title': '수정된 가우스 법칙',
                'content': '폐곡면을 기준으로 전기선속과 전하의 관계를 설명한다.',
                'pageNumbers': [3, 4],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final now = DateTime.utc(2026, 10, 1);
    final source = StudySource(
      id: 'source-1',
      folderId: 'folder-1',
      fileName: '전자기학.pdf',
      contentHash: List.filled(64, 'a').join(),
      pageCount: 12,
      extractionMethod: 'textLayer',
      importedAt: now,
    );
    final concepts = [
      StudyConcept(
        id: 'concept-1',
        sourceId: source.id,
        title: '가우스 법칙',
        content: '전기선속과 전하의 관계',
        pageNumbers: const [3, 4],
        status: ConceptStatus.held,
        createdAt: now,
        updatedAt: now,
      ),
      StudyConcept(
        id: 'concept-2',
        sourceId: source.id,
        title: '쿨롱 법칙',
        content: '두 전하 사이의 힘',
        pageNumbers: const [5],
        status: ConceptStatus.approved,
        createdAt: now,
        updatedAt: now,
      ),
    ];

    final revisions = await api.reviseConcepts(
      configuration: configuration,
      source: source,
      concepts: concepts,
      instruction: '설명을 더 자연스럽게 고쳐 줘.',
      scope: ConceptRevisionScope.unapproved,
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/documents/concepts/revise');
    expect(captured.headers['x-sync-token'], 'private-token');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['scope'], 'unapproved');
    expect(body['instruction'], '설명을 더 자연스럽게 고쳐 줘.');
    expect(body['concepts'], hasLength(2));
    expect((body['concepts'] as List).last['status'], 'approved');
    expect(revisions.single.title, '수정된 가우스 법칙');
    expect(revisions.single.pageNumbers, [3, 4]);
  });
}
