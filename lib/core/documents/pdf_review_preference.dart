import 'package:flutter_riverpod/flutter_riverpod.dart';

// Session preference shared by file selection and folder drag-and-drop.
final pdfReviewPreferenceProvider = NotifierProvider<PdfReviewPreference, bool>(
  PdfReviewPreference.new,
);

class PdfReviewPreference extends Notifier<bool> {
  @override
  bool build() => false;
  void setEnabled(bool value) => state = value;
}
