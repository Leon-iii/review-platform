import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/pdf_review_preference.dart';
import 'package:review_platform/core/documents/remote_document_api.dart';

class PdfReviewOption extends ConsumerWidget {
  const PdfReviewOption({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => SwitchListTile(
    key: const Key('review-ocr-before-concepts'),
    contentPadding: EdgeInsets.zero,
    title: const Text('OCR 검토 후 개념 추출'),
    subtitle: const Text('추출 내용과 영역을 직접 확인한 뒤 개념 추출을 시작합니다. 끄면 자동 진행합니다.'),
    value: ref.watch(pdfReviewPreferenceProvider),
    onChanged: ref.watch(remoteDocumentApiProvider) is RemoteDocumentReviewApi
        ? (value) =>
              ref.read(pdfReviewPreferenceProvider.notifier).setEnabled(value)
        : null,
  );
}
