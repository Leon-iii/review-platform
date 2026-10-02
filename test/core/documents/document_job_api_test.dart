import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

import '../../support/fake_pdf_jobs.dart';

void main() {
  const configuration = SyncConfiguration(
    serverUrl: 'http://server:5080/',
    accessToken: 'token',
  );
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
}
