import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:review_platform/core/errors/app_failure.dart';

class PickedPdfDocument {
  const PickedPdfDocument({required String fileName, required Uint8List bytes})
    : this._(fileName, bytes, null, null);

  const PickedPdfDocument.stream({
    required String fileName,
    required int length,
    required Stream<List<int>> Function() openRead,
  }) : this._(fileName, null, length, openRead);
  const PickedPdfDocument._(
    this.fileName,
    this._bytes,
    this._length,
    this._openRead,
  );

  final String fileName;
  final Uint8List? _bytes;
  final int? _length;
  final Stream<List<int>> Function()? _openRead;
  int get length => _length ?? _bytes!.length;

  // Transport ceiling; the configurable server limit is checked before upload.
  static const maximumFileSize = 2048 * 1024 * 1024;

  Stream<List<int>> openRead() async* {
    var read = 0;
    try {
      await for (final chunk in _openRead?.call() ?? Stream.value(_bytes!)) {
        read += chunk.length;
        if (read > length) {
          throw const ValidationFailure('전송 중 PDF 파일 크기가 변경되었어요.');
        }
        yield chunk;
      }
      if (read != length) throw const ValidationFailure('PDF 파일을 끝까지 읽지 못했어요.');
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        const ValidationFailure('PDF 파일을 읽지 못했어요. 파일 접근 권한을 확인해 주세요.'),
        stackTrace,
      );
    }
  }

  // Compatibility with the old, synchronous import endpoint only.
  Future<Uint8List> readBytes() async {
    final result = BytesBuilder(copy: false);
    await for (final chunk in openRead()) {
      result.add(chunk);
    }
    return result.takeBytes();
  }

  void validate() {
    if (!fileName.toLowerCase().endsWith('.pdf')) {
      throw const ValidationFailure('PDF 파일만 가져올 수 있어요.');
    }
    if (length < 1 || length > maximumFileSize) {
      throw const ValidationFailure('PDF 파일이 비어 있거나 전송 가능한 크기를 초과했어요.');
    }
  }
}

Future<PickedPdfDocument> readDroppedPdf(List<DropItem> files) async {
  if (files.length != 1) {
    throw const ValidationFailure('한 번에 PDF 파일 하나를 놓아 주세요.');
  }
  final file = files.single;
  if (file is! DropItemFile || !file.name.toLowerCase().endsWith('.pdf')) {
    throw const ValidationFailure('폴더가 아닌 PDF 파일을 놓아 주세요.');
  }
  try {
    final length = await file.length();
    if (length < 1 || length > PickedPdfDocument.maximumFileSize) {
      throw const ValidationFailure('PDF 파일이 비어 있거나 전송 가능한 크기를 초과했어요.');
    }
    final document = PickedPdfDocument.stream(
      fileName: file.name,
      length: length,
      openRead: () => file.openRead(),
    );
    document.validate();
    return document;
  } on AppFailure {
    rethrow;
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      const ValidationFailure('PDF 파일을 읽지 못했어요. 파일 접근 권한을 확인해 주세요.'),
      stackTrace,
    );
  }
}

abstract interface class DocumentPicker {
  Future<PickedPdfDocument?> pickPdf();
}

class FilePickerDocumentPicker implements DocumentPicker {
  @override
  Future<PickedPdfDocument?> pickPdf() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (file == null) return null;
      final length = await file.length();
      if (length == null ||
          length < 1 ||
          length > PickedPdfDocument.maximumFileSize) {
        throw const ValidationFailure('PDF 파일이 비어 있거나 전송 가능한 크기를 초과했어요.');
      }
      final document = PickedPdfDocument.stream(
        fileName: file.name,
        length: length,
        openRead: file.readAsByteStream,
      );
      document.validate();
      return document;
    } on AppFailure {
      rethrow;
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        const ValidationFailure('PDF 파일을 선택하지 못했어요.'),
        stackTrace,
      );
    }
  }
}
