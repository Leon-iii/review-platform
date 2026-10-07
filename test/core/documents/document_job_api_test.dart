import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/sync_contract.dart';
import 'package:review_platform/domain/models/document_ocr_review.dart';

import '../../support/fake_pdf_jobs.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://server:5080/',
    accessToken: 'token',
  );
  test('깨진 개요·사전 점검 응답은 화면 예외 대신 공통 오류로 전달한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient((_) async => http.Response('{}', 200)),
    );
    await expectLater(
      api.extractionOverview(configuration, 'job'),
      throwsA(isA<NetworkFailure>()),
    );
    await expectLater(
      api.preflight(configuration, 'job', {'mode': 'direct'}),
      throwsA(isA<NetworkFailure>()),
    );
  });
  test('업로드는 추출 방식 선택 대기로 등록하고 이후 명시적 시작만 전송한다', () async {
    var starts = 0;
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        if (request.url.path.endsWith('/limits')) {
          return http.Response('{"supportsExtractionSelection":true}', 200);
        }
        if (request.url.path.endsWith('/extraction/start')) {
          starts++;
          final selection = jsonDecode(request.body) as Map;
          expect(selection['mode'], 'direct');
          expect(selection['splitAfterPages'], [2]);
          return http.Response(
            jsonEncode(pdfJob('job', status: 'queued').data),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        expect(request.url.queryParameters['prepareOnly'], 'true');
        expect(request.headers['x-sync-token'], 'token');
        return http.Response(
          jsonEncode(pdfJob('job', status: 'awaiting_selection').data),
          202,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final uploaded = await api.prepareJob(
      configuration,
      'job',
      PickedPdfDocument.stream(
        fileName: '강의.pdf',
        length: 5,
        openRead: () => Stream.value([37, 80, 68, 70, 45]),
      ),
    );
    expect(uploaded.isAwaitingSelection, true);
    expect(starts, 0);
    await api.startExtraction(configuration, 'job', {
      'mode': 'direct',
      'splitAfterPages': [2],
      'revision': 1,
    });
    expect(starts, 1);
  });
  test('구 서버에는 업로드하지 않아 자동 OCR 시작을 방지한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path.endsWith('/limits'), true);
        return http.Response('{"maximumFileSize":209715200}', 200);
      }),
    );
    await expectLater(
      api.prepareJob(
        configuration,
        'job',
        PickedPdfDocument.stream(
          fileName: '강의.pdf',
          length: 5,
          openRead: () => Stream.value([37, 80, 68, 70, 45]),
        ),
      ),
      throwsA(isA<ValidationFailure>()),
    );
  });
  test('작업 삭제는 토큰을 전달하고 204·이미 삭제된 404를 처리한다', () async {
    for (final status in [204, 404]) {
      final api = HttpRemoteDocumentApi(
        MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/documents/jobs/old-job');
          expect(request.headers['x-sync-token'], 'token');
          return http.Response('', status);
        }),
      );
      await api.deleteJob(configuration, 'old-job');
    }
  });
  test('작업 삭제의 서버 거부·인증 실패는 성공으로 처리하지 않는다', () async {
    for (final status in [400, 401, 500, 200]) {
      final api = HttpRemoteDocumentApi(
        MockClient(
          (_) async => http.Response('{"error":"삭제할 수 없습니다."}', status),
        ),
      );
      await expectLater(
        api.deleteJob(configuration, 'old-job'),
        throwsA(isA<NetworkFailure>()),
      );
    }
  });
  test('PDF를 raw stream으로 보내며 파일명과 토큰을 정확히 전달한다', () async {
    var reads = 0;
    final picked = PickedPdfDocument.stream(
      fileName: '강의 & 1.PDF',
      length: 5,
      openRead: () {
        reads++;
        return Stream.fromIterable([
          [37, 80],
          [68, 70, 45],
        ]);
      },
    );
    final client = MockClient.streaming((request, stream) async {
      expect(request.url.path, '/api/documents/jobs/job');
      expect(request.url.queryParameters['fileName'], '강의 & 1.PDF');
      expect(request.headers['x-sync-token'], 'token');
      expect(request.headers['content-type'], 'application/pdf');
      expect(request.contentLength, 5);
      expect(await stream.toBytes(), [37, 80, 68, 70, 45]);
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(jsonEncode(pdfJob('job', status: 'queued').data)),
        ),
        202,
      );
    });
    expect(reads, 0);
    final job = await HttpRemoteDocumentApi(client)
        .uploadJob(configuration, 'job', picked);
    expect(job.status, 'queued');
    expect(reads, 1);
  });
  test('서버 용량 설정과 없는 작업을 구분한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient(
        (request) async => request.url.path.endsWith('limits')
            ? http.Response('{"maximumFileSize":209715200}', 200)
            : http.Response('{}', 404),
      ),
    );
    expect(await api.maximumUploadBytes(configuration), 200 * 1024 * 1024);
    expect(await api.getJob(configuration, 'missing'), isNull);
  });
  test('인증 실패와 깨진 작업 응답을 안전한 오류로 표시한다', () async {
    for (final response in [
      http.Response('{}', 401),
      http.Response('{}', 200),
    ]) {
      final api = HttpRemoteDocumentApi(MockClient((_) async => response));
      await expectLater(
        api.getJob(configuration, 'job'),
        throwsA(isA<NetworkFailure>()),
      );
    }
  });

  test('OCR 검토 옵션은 기본 자동이고 선택한 경우에만 업로드 쿼리에 전달한다', () async {
    final flags = <String?>[];
    final api = HttpRemoteDocumentApi(
      MockClient.streaming((request, stream) async {
        flags.add(request.url.queryParameters['reviewBeforeConcepts']);
        await stream.toBytes();
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(jsonEncode(pdfJob('job', status: 'queued').data)),
          ),
          202,
        );
      }),
    );
    final document = PickedPdfDocument.stream(
      fileName: '자료.pdf',
      length: 5,
      openRead: () => Stream.value([37, 80, 68, 70, 45]),
    );
    await api.uploadJob(configuration, 'job', document);
    await api.uploadJob(
      configuration,
      'job',
      document,
      reviewBeforeConcepts: true,
    );
    expect(flags, ['false', 'true']);
  });

  Map<String, Object?> reviewJson() => {
    'pageNumber': 1,
    'totalPages': 2,
    'originalText': '원문',
    'revision': 3,
    'edited': true,
    'blocks': [const OcrReviewBlock(text: '수정 내용', independent: true).toJson()],
    'originalBlocks': [const OcrReviewBlock(text: '원문').toJson()],
  };
  test('OCR 검토 API는 페이지·버전·영역 플래그와 토큰을 보내고 원문을 보존한다', () async {
    final requests = <http.Request>[];
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        requests.add(request);
        expect(request.headers['x-sync-token'], 'token');
        return request.url.path.endsWith('confirm')
            ? http.Response.bytes(
                utf8.encode(jsonEncode(pdfJob('job', status: 'queued').data)),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              )
            : http.Response(
                jsonEncode(reviewJson()),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
      }),
    );
    final page = await api.reviewPage(configuration, 'job', 1);
    expect(page.blocks.first.independent, isTrue);
    expect(page.originalBlocks.first.text, '원문');
    await api.saveReviewPage(configuration, 'job', 1, 3, [
      const OcrReviewBlock(text: '수정 내용', independent: true),
      const OcrReviewBlock(text: '제외 내용', excluded: true),
    ]);
    expect(requests[1].method, 'PUT');
    final body = jsonDecode(requests[1].body) as Map;
    expect(body['revision'], 3);
    expect((body['blocks'] as List)[0]['independent'], isTrue);
    expect((body['blocks'] as List)[1]['excluded'], isTrue);
    final confirmed = await api.confirmReview(configuration, 'job', 3);
    expect(requests[2].url.path, '/api/documents/jobs/job/review/confirm');
    expect(jsonDecode(requests[2].body), {'revision': 3});
    expect(confirmed.isActive, isTrue);
  });
  test('완료 자료의 읽기 전용 플래그와 이전 응답의 기본값을 해석한다', () async {
    for (final readOnly in [null, true]) {
      final body = reviewJson();
      if (readOnly != null) body['readOnly'] = readOnly;
      final api = HttpRemoteDocumentApi(
        MockClient(
          (_) async => http.Response.bytes(
            utf8.encode(jsonEncode(body)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      expect(
        (await api.reviewPage(configuration, 'job', 1)).readOnly,
        readOnly ?? false,
      );
    }
  });

  test('검토 대기 상태를 읽고 이미지 인증 및 오류 응답을 구분한다', () async {
    final api = HttpRemoteDocumentApi(
      MockClient((request) async {
        expect(request.headers['x-sync-token'], 'token');
        if (request.url.path.endsWith('image')) {
          return http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(pdfJob('job', status: 'awaiting_review').data),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    expect((await api.getJob(configuration, 'job'))!.isAwaitingReview, isTrue);
    expect(await api.reviewImage(configuration, 'job', 1), [1, 2, 3]);
    final failed = HttpRemoteDocumentApi(
      MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode({'error': '검토 버전이 변경되었습니다.'})),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await expectLater(
      failed.confirmReview(configuration, 'job', 0),
      throwsA(
        isA<NetworkFailure>().having(
          (error) => error.message,
          'message',
          '검토 버전이 변경되었습니다.',
        ),
      ),
    );
    final broken = HttpRemoteDocumentApi(
      MockClient((_) async => http.Response('{}', 200)),
    );
    await expectLater(
      broken.reviewPage(configuration, 'job', 1),
      throwsA(isA<NetworkFailure>()),
    );
    await expectLater(
      broken.reviewImage(configuration, 'job', 1),
      throwsA(isA<NetworkFailure>()),
    );
  });
}
