import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/errors/app_failure.dart';

void main() {
  test('대문자 확장자와 한국어 파일명도 PDF로 읽는다', () async {
    final bytes = Uint8List.fromList([37, 80, 68, 70, 45]);
    final result = await readDroppedPdf([
      DropItemFile.fromData(bytes, path: '강의.PDF'),
    ]);
    expect(result.fileName, '강의.PDF');
    expect(result.bytes, bytes);
  });

  test('빈 드롭, 여러 파일, PDF 아닌 파일 및 폴더는 거부한다', () async {
    final bytes = Uint8List.fromList([1]);
    final pdf = DropItemFile.fromData(bytes, path: '강의.pdf');
    for (final files in <List<DropItem>>[
      [],
      [pdf, pdf],
      [DropItemFile.fromData(bytes, path: '강의.txt')],
      [DropItemDirectory.fromData(bytes, [], path: 'folder.pdf')],
    ]) {
      await expectLater(
        readDroppedPdf(files),
        throwsA(isA<ValidationFailure>()),
      );
    }
  });

  test('빈 PDF 및 25MB 초과 파일은 읽기 전에 거부한다', () async {
    for (final length in [0, PickedPdfDocument.maximumFileSize + 1]) {
      final file = _SizedPdf(length, Uint8List.fromList([1]));
      await expectLater(
        readDroppedPdf([file]),
        throwsA(isA<ValidationFailure>()),
      );
      expect(file.readCount, 0);
    }
  });

  test('25MB 경계는 허용하고 길이 확인 이후 증가한 파일도 제한한다', () async {
    final bytes = Uint8List(PickedPdfDocument.maximumFileSize);
    final result = await readDroppedPdf([_SizedPdf(bytes.length, bytes)]);
    expect(result.bytes.length, PickedPdfDocument.maximumFileSize);
    final grows = _SizedPdf(
      1,
      Uint8List(PickedPdfDocument.maximumFileSize + 1),
    );
    await expectLater(
      readDroppedPdf([grows]),
      throwsA(isA<ValidationFailure>()),
    );
  });

  test('읽기 오류는 안전한 안내로 변환한다', () async {
    await expectLater(
      readDroppedPdf([DropItemFile('not-existing-file.pdf')]),
      throwsA(
        isA<ValidationFailure>().having(
          (error) => error.message,
          'message',
          contains('읽지 못했어요'),
        ),
      ),
    );
  });
}

class _SizedPdf extends DropItemFile {
  _SizedPdf(this.reportedLength, this.data)
    : super.fromData(data, path: 'test.pdf');
  final int reportedLength;
  final Uint8List data;
  int readCount = 0;
  @override
  Future<int> length() async => reportedLength;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) {
    readCount++;
    return Stream.value(data);
  }
}
