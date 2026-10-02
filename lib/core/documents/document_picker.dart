import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:review_platform/core/errors/app_failure.dart';

class PickedPdfDocument {
  const PickedPdfDocument({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;

  static const maximumFileSize = 25 * 1024 * 1024;

  void validate() {
    if (!fileName.toLowerCase().endsWith('.pdf')) {
      throw const ValidationFailure('PDF 파일만 가져올 수 있어요.');
    }
    if (bytes.isEmpty || bytes.length > maximumFileSize) {
      throw const ValidationFailure('PDF 파일은 25MB 이하만 가져올 수 있어요.');
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
      throw const ValidationFailure('PDF 파일은 25MB 이하만 가져올 수 있어요.');
    }
    // Bound the read too, in case the file grows after checking its length.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > PickedPdfDocument.maximumFileSize) {
        throw const ValidationFailure('PDF 파일은 25MB 이하만 가져올 수 있어요.');
      }
      bytes.add(chunk);
    }
    final document = PickedPdfDocument(
      fileName: file.name,
      bytes: bytes.takeBytes(),
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
        throw const ValidationFailure('PDF 파일은 25MB 이하만 가져올 수 있어요.');
      }
      final bytes = await file.readAsBytes();
      final document = PickedPdfDocument(fileName: file.name, bytes: bytes);
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
