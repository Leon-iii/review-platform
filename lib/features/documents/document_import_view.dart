import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/documents/document_import_view_model.dart';

class DocumentImportView extends ConsumerWidget {
  const DocumentImportView({required this.folderId, super.key});

  final String folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controllerProvider = documentImportControllerProvider(folderId);
    final state = ref.watch(controllerProvider);
    return Scaffold(
      key: const Key('document-import-view'),
      appBar: AppBar(title: const Text('PDF 학습자료')),
      body: state.when(
        loading: () => const _ImportProgress(),
        error: (error, stackTrace) => _ImportError(
          message: error is AppFailure ? error.message : 'PDF를 처리하지 못했어요.',
          onBack: () => ref.read(controllerProvider.notifier).showSourceList(),
          onRetry: () => ref.read(controllerProvider.notifier).pickAndImport(),
        ),
        data: (review) => review == null
            ? _SourceList(folderId: folderId, provider: controllerProvider)
            : _ConceptReview(review: review, provider: controllerProvider),
      ),
    );
  }
}

class _SourceList extends ConsumerWidget {
  const _SourceList({required this.folderId, required this.provider});

  final String folderId;
  final DocumentImportControllerProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(documentSourcesProvider(folderId));
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'PDF에서 학습 개념 추출',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '텍스트 레이어가 있는 PDF를 서버에서 분석하고, 페이지 근거가 포함된 Draft 개념을 만듭니다.',
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const Key('pick-pdf-button'),
                          onPressed: () =>
                              ref.read(provider.notifier).pickAndImport(),
                          icon: const Icon(Icons.picture_as_pdf_rounded),
                          label: const Text('PDF 선택 및 분석'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('가져온 자료', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                sources.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (error, stackTrace) => const Card(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('가져온 자료를 불러오지 못했어요.'),
                    ),
                  ),
                  data: (items) => items.isEmpty
                      ? const Card(
                          child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('아직 가져온 PDF가 없어요.'),
                          ),
                        )
                      : Column(
                          children: [
                            for (final source in items)
                              Card(
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.picture_as_pdf_rounded,
                                  ),
                                  title: Text(source.fileName),
                                  subtitle: Text(
                                    '${source.pageCount}페이지 · ${_extractionLabel(source.extractionMethod)}',
                                  ),
                                  trailing: const Icon(
                                    Icons.chevron_right_rounded,
                                  ),
                                  onTap: () => ref
                                      .read(provider.notifier)
                                      .loadSource(source.id),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ConceptReview extends ConsumerWidget {
  const _ConceptReview({required this.review, required this.provider});

  final StudySourceWithConcepts review;
  final DocumentImportControllerProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          review.source.fileName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${review.source.pageCount}페이지 · 추출 개념 ${review.concepts.length}개',
                        ),
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: () =>
                              ref.read(provider.notifier).showSourceList(),
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('자료 목록'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (final concept in review.concepts) ...[
                  _ConceptCard(
                    concept: concept,
                    folderId: review.source.folderId,
                    provider: provider,
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ConceptCard extends ConsumerWidget {
  const _ConceptCard({
    required this.concept,
    required this.folderId,
    required this.provider,
  });

  final StudyConcept concept;
  final String folderId;
  final DocumentImportControllerProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(_statusLabel(concept.status))),
                Chip(label: Text('p.${concept.pageNumbers.join(', ')}')),
              ],
            ),
            const SizedBox(height: 8),
            Text(concept.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(concept.summary),
            const SizedBox(height: 8),
            Text(concept.details, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 14),
            if (concept.status == ConceptStatus.approved)
              FilledButton.icon(
                onPressed: () => context.push(
                  AppRoutes.aiGenerateForConcept(folderId, concept.id),
                ),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('이 개념으로 문제 생성'),
              )
            else if (concept.status != ConceptStatus.rejected)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () =>
                        ref.read(provider.notifier).approve(concept.id),
                    child: const Text('승인'),
                  ),
                  OutlinedButton(
                    onPressed: () => _edit(context, ref),
                    child: const Text('수정 후 승인'),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(provider.notifier).hold(concept.id),
                    child: const Text('보류'),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(provider.notifier).reject(concept.id),
                    child: const Text('삭제'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController(text: concept.title);
    final summary = TextEditingController(text: concept.summary);
    final details = TextEditingController(text: concept.details);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('개념 수정'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: '제목'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: summary,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '요약'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: details,
                  minLines: 4,
                  maxLines: 10,
                  decoration: const InputDecoration(labelText: '상세 내용'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('저장 및 승인'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(provider.notifier)
          .updateAndApprove(
            conceptId: concept.id,
            title: title.text,
            summary: summary.text,
            details: details.text,
          );
    }
    title.dispose();
    summary.dispose();
    details.dispose();
  }
}

class _ImportProgress extends StatelessWidget {
  const _ImportProgress();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              LinearProgressIndicator(key: Key('pdf-import-progress')),
              SizedBox(height: 18),
              Text('PDF 텍스트와 학습 개념을 추출하고 있어요.'),
              SizedBox(height: 8),
              Text('페이지 수와 모델 성능에 따라 시간이 걸릴 수 있어요.'),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportError extends StatelessWidget {
  const _ImportError({
    required this.message,
    required this.onBack,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.error,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(onPressed: onBack, child: const Text('자료 목록')),
                FilledButton(onPressed: onRetry, child: const Text('다시 선택')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(ConceptStatus status) => switch (status) {
  ConceptStatus.draft => 'Draft',
  ConceptStatus.approved => '승인됨',
  ConceptStatus.held => '보류',
  ConceptStatus.rejected => '삭제됨',
};

String _extractionLabel(String method) => switch (method) {
  'textLayer' => '텍스트 레이어',
  'ocr' => 'OCR',
  _ => method,
};
