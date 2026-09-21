import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:review_platform/core/errors/app_failure.dart';

class PickedPdfDocument {
  const PickedPdfDocument({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

abstract interface class DocumentPicker {
  Future<PickedPdfDocument?> pickPdf();
}

class FilePickerDocumentPicker implements DocumentPicker {
  static const _maximumFileSize = 25 * 1024 * 1024;

  @override
  Future<PickedPdfDocument?> pickPdf() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (file == null) return null;
      final length = await file.length();
      if (length == null || length < 1 || length > _maximumFileSize) {
        throw const ValidationFailure('PDF 파일은 25MB 이하만 가져올 수 있어요.');
      }
      final bytes = await file.readAsBytes();
      return PickedPdfDocument(fileName: file.name, bytes: bytes);
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
