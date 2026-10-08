import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/study_source.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://127.0.0.1:5080/',
    accessToken: 'private-token',
  );

  test('자료 이미지 전용 경로로 인증 요청하고 이미지가 아닌 응답을 차단한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        expect(
          request.url.path,
          '/api/documents/sources/source/pages/47/image',
        );
        expect(request.headers['x-sync-token'], 'private-token');
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      }),
    );
    expect(await api.sourceImage(configuration, 'source', 47), [1, 2, 3]);
    final invalid = HttpRemoteDocumentApi(
      MockClient(
        (_) async => http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      invalid.sourceImage(configuration, 'source', 47),
      throwsA(isA<NetworkFailure>()),
    );
    final missing = HttpRemoteDocumentApi(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'error': '원본 PDF가 없습니다.'}),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await expectLater(
      missing.sourceImage(configuration, 'source', 47),
      throwsA(predicate((error) => error.toString().contains('원본 PDF가 없습니다.'))),
    );
  });

  test('추가·삭제 권한을 보내고 세 변경 목록과 연결 그룹을 해석한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['allowAdditions'], isTrue);
        expect(body['allowDeletions'], isTrue);
        expect(body['targetConceptIds'], isEmpty);
        return http.Response(
          jsonEncode({
            'status': 'ready',
            'comment': '교체 요청을 반영했습니다.',
            'clarificationQuestion': '',
            'revisions': [],
            'additions': [
              {
                'title': '새 개념',
                'content': '새 내용',
                'pageNumbers': [],
                'importance': 'veryHigh',
                'groupId': 'replace',
                'reason': '추가',
              },
            ],
            'deletions': [
              {'id': 'old', 'reason': '교체 요청', 'groupId': 'replace'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final changes = await api.reviseConcepts(
      configuration: configuration,
      source: StudySource(
        id: 'source',
        folderId: 'folder',
        fileName: '자료',
        contentHash: '',
        pageCount: 0,
        extractionMethod: 'manual',
        importedAt: DateTime.utc(2026),
      ),
      concepts: const [],
      instruction: '교체',
      targetConceptIds: const {},
      allowAdditions: true,
      allowDeletions: true,
    );
    expect(changes.changes.map((item) => item.kind), [
      ConceptChangeKind.add,
      ConceptChangeKind.delete,
    ]);
    expect(changes.changes.every((item) => item.groupId == 'replace'), isTrue);
    expect(changes.changes.first.importance, ConceptImportance.veryHigh);
    expect(changes.changes.first.pageNumbers, isEmpty);
    expect(changes.changes.last.id, 'old');
    expect(changes.changes.last.reason, '교체 요청');
  });

  test('확인 질문 응답을 해석하고 원본 해시·질문 답변 이력을 다음 요청에 보낸다', () async {
    final source = StudySource(
      id: 'source',
      folderId: 'folder',
      fileName: '자료.pdf',
      contentHash: 'original-hash',
      pageCount: 12,
      extractionMethod: 'directPdf',
      importedAt: DateTime.utc(2026),
    );
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['contentHash'], source.contentHash);
        expect(body['instruction'], '관계를 보완해 줘.');
        expect(body['clarifications'], [
          {'question': '어느 관계인가요?', 'answer': '두 계층 사이의 관계'},
        ]);
        return http.Response(
          jsonEncode({
            'status': 'needsClarification',
            'comment': '원본에서 두 해석이 가능해 확인이 필요합니다.',
            'clarificationQuestion': '어느 계층을 기준으로 설명할까요?',
            'revisions': [],
            'additions': [],
            'deletions': [],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final response = await api.reviseConcepts(
      configuration: configuration,
      source: source,
      concepts: const [],
      instruction: '관계를 보완해 줘.',
      targetConceptIds: const {},
      allowAdditions: true,
      clarifications: const [
        ConceptRevisionClarification(
          question: '어느 관계인가요?',
          answer: '두 계층 사이의 관계',
        ),
      ],
    );
    expect(response.status, ConceptRevisionStatus.needsClarification);
    expect(response.comment, contains('확인이 필요'));
    expect(response.clarificationQuestion, contains('어느 계층'));
    expect(response.changes, isEmpty);
  });

  final invalidFeedback = <Map<String, Object?>>[
    {'status': 'unknown'},
    {'comment': ''},
    {'comment': List.filled(4001, '가').join()},
    {'status': 'ready'},
    {'status': 'needsClarification'},
    {'clarificationQuestion': '질문이지만 noChanges 상태'},
    {'revisions': null},
    {
      'status': 'needsClarification',
      'clarificationQuestion': '질문',
      'revisions': [
        {
          'id': 'id',
          'title': '제목',
          'content': '내용',
          'pageNumbers': [],
          'importance': 'medium',
          'reason': '이유',
        },
      ],
    },
    {
      'status': 'ready',
      'revisions': [
        {
          'id': 'id',
          'title': '제목',
          'content': '내용',
          'pageNumbers': [],
          'importance': 'medium',
          'reason': '',
        },
      ],
    },
  ];
  for (final (index, invalid) in invalidFeedback.indexed) {
    test('일관되지 않거나 불완전한 개념 수정 피드백을 차단한다 ($index)', () async {
      final api = HttpRemoteDocumentApi(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'noChanges',
              'comment': '변경 없음',
              'clarificationQuestion': '',
              'revisions': [],
              'additions': [],
              'deletions': [],
              ...invalid,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await expectLater(
        api.reviseConcepts(
          configuration: configuration,
          source: StudySource(
            id: 'source',
            folderId: 'folder',
            fileName: '노트',
            contentHash: '',
            pageCount: 0,
            extractionMethod: 'manual',
            importedAt: DateTime.utc(2026),
          ),
          concepts: const [],
          instruction: '추가',
          targetConceptIds: const {},
          allowAdditions: true,
        ),
        throwsA(
          isA<NetworkFailure>().having(
            (e) => e.message,
            'message',
            '개념 수정 응답 형식이 올바르지 않아요.',
          ),
        ),
      );
    });
  }

  for (final importance in ConceptImportance.values) {
    test('수동 자료 AI 수정의 중요도 ${importance.label} 송수신과 빈 출처를 보존한다', () async {
      late Map<String, dynamic> payload;
      final api = HttpRemoteDocumentApi(
        MockClient((request) async {
          expect(request.url.path, '/api/documents/concepts/revise');
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'revisions': [
                {
                  'id': 'manual-concept',
                  'title': '노트 개념',
                  'content': '직접 쓴 내용 수정',
                  'pageNumbers': [],
                  'importance': importance.name,
                  'reason': '설명을 보완했습니다.',
                },
              ],
              'status': 'ready',
              'comment': '요청을 반영했습니다.',
              'clarificationQuestion': '',
              'additions': [],
              'deletions': [],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final now = DateTime.utc(2026);
      final source = StudySource(
        id: 'manual-source',
        folderId: 'folder-1',
        fileName: '노트',
        contentHash: '',
        pageCount: 0,
        extractionMethod: 'manual',
        importedAt: now,
      );
      final result = await api.reviseConcepts(
        configuration: configuration,
        source: source,
        concepts: [
          StudyConcept(
            id: 'manual-concept',
            sourceId: source.id,
            title: '노트 개념',
            content: '직접 쓴 내용',
            pageNumbers: const [],
            status: ConceptStatus.approved,
            importance: importance,
            createdAt: now,
            updatedAt: now,
          ),
        ],
        instruction: '설명을 보완해 줘.',
        targetConceptIds: const {'manual-concept'},
      );
      expect(payload['pageCount'], 0);
      expect((payload['concepts'] as List).single['pageNumbers'], isEmpty);
      expect(
        (payload['concepts'] as List).single['importance'],
        importance.name,
      );
      expect(result.changes.single.pageNumbers, isEmpty);
      expect(result.changes.single.importance, importance);
      expect(result.changes.single.content, '직접 쓴 내용 수정');
    });

    test('PDF 작업 결과의 중요도 ${importance.label}와 Source를 파싱한다', () async {
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
                  'importance': importance.name,
                  'status': 'held',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final result = await api.jobResult(configuration, 'source-1');
      expect(captured.url.path, '/api/documents/jobs/source-1/result');
      expect(captured.headers['x-sync-token'], 'private-token');
      expect(result.source.pageCount, 12);
      expect(result.concepts.single.content, contains('폐곡면'));
      expect(result.concepts.single.pageNumbers, [3, 4]);
      expect(result.concepts.single.importance, importance);
    });
  }

  test('PDF 처리 오류의 안전한 서버 메시지를 전달한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient(
        (request) async => http.Response(
          jsonEncode({'error': 'PDF 개념 추출이 실패했습니다.'}),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      api.jobResult(configuration, 'source-1'),
      throwsA(
        isA<NetworkFailure>().having(
          (error) => error.message,
          'message',
          contains('개념 추출'),
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
                'importance': 'high',
                'reason': '설명을 보완했습니다.',
              },
            ],
            'status': 'ready',
            'comment': '요청을 반영했습니다.',
            'clarificationQuestion': '',
            'additions': [],
            'deletions': [],
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
      targetConceptIds: const {'concept-1'},
    );

    expect(captured.method, 'POST');
    expect(captured.url.path, '/api/documents/concepts/revise');
    expect(captured.headers['x-sync-token'], 'private-token');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body.containsKey('scope'), isFalse);
    expect(body['targetConceptIds'], ['concept-1']);
    expect(body['instruction'], '설명을 더 자연스럽게 고쳐 줘.');
    expect(body['concepts'], hasLength(2));
    expect((body['concepts'] as List).last['status'], 'approved');
    expect(revisions.changes.single.title, '수정된 가우스 법칙');
    expect(revisions.changes.single.pageNumbers, [3, 4]);
    expect(revisions.changes.single.importance, ConceptImportance.high);
  });
}
