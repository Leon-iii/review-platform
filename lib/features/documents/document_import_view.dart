import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/documents/document_import_view_model.dart';

class DocumentImportView extends ConsumerStatefulWidget {
  const DocumentImportView({
    required this.folderId,
    this.initialSourceId,
    super.key,
  });

  final String folderId;
  final String? initialSourceId;

  @override
  ConsumerState<DocumentImportView> createState() => _DocumentImportViewState();
}

class _DocumentImportViewState extends ConsumerState<DocumentImportView> {
  bool _initialSourceOpened = false;

  @override
  Widget build(BuildContext context) {
    final controllerProvider = documentImportControllerProvider(
      widget.folderId,
    );
    if (!_initialSourceOpened && widget.initialSourceId != null) {
      _initialSourceOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(controllerProvider.notifier)
            .loadSource(widget.initialSourceId!);
      });
    }
    final state = ref.watch(controllerProvider);
    return Scaffold(
      key: const Key('document-import-view'),
      appBar: AppBar(title: const Text('PDF 학습자료')),
      body: state.when(
        loading: () => const _ImportProgress(),
        error: (error, stackTrace) => _ImportError(
          message: error is AppFailure ? error.message : 'PDF를 처리하지 못했어요.',
          onBack: () =>
              ref.read(controllerProvider.notifier).showImportPrompt(),
          onRetry: () => ref.read(controllerProvider.notifier).pickAndImport(),
        ),
        data: (review) => review == null
            ? _ImportPrompt(provider: controllerProvider)
            : _ConceptReview(review: review, provider: controllerProvider),
      ),
    );
  }
}

class _ImportPrompt extends ConsumerWidget {
  const _ImportPrompt({required this.provider});

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
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'PDF에서 학습 개념 추출',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'PDF를 서버에서 분석하고, 페이지 근거가 포함된 보류 상태의 개념을 만듭니다.',
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
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          key: const Key('request-concept-revision-button'),
                          onPressed: () => _requestRevision(
                            context,
                            ref,
                            initialSelectedIds: const {},
                          ),
                          icon: const Icon(Icons.auto_fix_high_rounded),
                          label: const Text('수정 요청'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (
                  var index = 0;
                  index < review.concepts.length;
                  index++
                ) ...[
                  _ConceptCard(
                    number: index + 1,
                    concept: review.concepts[index],
                    folderId: review.source.folderId,
                    provider: provider,
                    onRequestRevision: () => _requestRevision(
                      context,
                      ref,
                      initialSelectedIds: {review.concepts[index].id},
                    ),
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

  Future<void> _requestRevision(
    BuildContext context,
    WidgetRef ref, {
    required Set<String> initialSelectedIds,
  }) async {
    var instruction = '';
    final selectedIds = Set<String>.of(initialSelectedIds);
    var isSending = false;
    String? errorMessage;
    final revisions = await showDialog<List<ConceptRevision>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('개념 수정 요청'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    key: const Key('concept-revision-instruction-field'),
                    enabled: !isSending,
                    minLines: 4,
                    maxLines: 10,
                    maxLength: 4000,
                    decoration: const InputDecoration(
                      labelText: '요청사항',
                      hintText: '개념을 어떻게 수정할지 입력해 주세요.',
                      alignLabelWithHint: true,
                    ),
                    onChanged: (value) => instruction = value,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '수정할 개념 (${selectedIds.length}/${review.concepts.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: isSending
                              ? null
                              : () => setDialogState(() {
                                  selectedIds
                                    ..clear()
                                    ..addAll(
                                      review.concepts.map(
                                        (concept) => concept.id,
                                      ),
                                    );
                                }),
                          child: const Text('전체 선택'),
                        ),
                        TextButton(
                          onPressed: isSending || selectedIds.isEmpty
                              ? null
                              : () => setDialogState(selectedIds.clear),
                          child: const Text('선택 해제'),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 280),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: review.concepts.length,
                      itemBuilder: (context, index) {
                        final concept = review.concepts[index];
                        return CheckboxListTile(
                          key: ValueKey(
                            'concept-revision-target-${concept.id}',
                          ),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text('${index + 1}. ${concept.title}'),
                          subtitle: Text(
                            '${concept.status == ConceptStatus.approved ? '승인됨' : '보류됨'}'
                            ' · 중요도 ${concept.importance.label}'
                            ' · p.${concept.pageNumbers.join(', ')}',
                          ),
                          value: selectedIds.contains(concept.id),
                          onChanged: isSending
                              ? null
                              : (selected) => setDialogState(() {
                                  if (selected == true) {
                                    selectedIds.add(concept.id);
                                  } else {
                                    selectedIds.remove(concept.id);
                                  }
                                }),
                        );
                      },
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSending ? null : () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            FilledButton.icon(
              key: const Key('send-concept-revision-button'),
              onPressed: isSending
                  ? null
                  : () async {
                      if (instruction.trim().isEmpty) {
                        setDialogState(
                          () => errorMessage = '수정 요청사항을 입력해 주세요.',
                        );
                        return;
                      }
                      if (selectedIds.isEmpty) {
                        setDialogState(
                          () => errorMessage = '수정할 개념을 하나 이상 선택해 주세요.',
                        );
                        return;
                      }
                      setDialogState(() {
                        isSending = true;
                        errorMessage = null;
                      });
                      try {
                        final generated = await ref
                            .read(provider.notifier)
                            .requestConceptRevision(
                              instruction: instruction,
                              targetConceptIds: Set<String>.of(selectedIds),
                            );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, generated);
                        }
                      } catch (error) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          isSending = false;
                          errorMessage = error is AppFailure
                              ? error.message
                              : '개념 수정 요청을 처리하지 못했어요.';
                        });
                      }
                    },
              icon: isSending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(isSending ? '전송 중...' : '요청 전송'),
            ),
          ],
        ),
      ),
    );
    if (revisions == null || !context.mounted) return;
    if (revisions.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('수정된 개념이 없어요.')));
      return;
    }
    final shouldApply = await _confirmRevisions(context, revisions);
    if (shouldApply != true || !context.mounted) return;
    int changedCount;
    try {
      changedCount = await ref
          .read(provider.notifier)
          .applyConceptRevisions(revisions);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is AppFailure ? error.message : '개념 수정안을 적용하지 못했어요.',
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          changedCount == 0
              ? '수정된 개념이 없어요.'
              : '$changedCount개 개념을 수정하고 보류 상태로 변경했어요.',
        ),
      ),
    );
  }

  Future<bool?> _confirmRevisions(
    BuildContext context,
    List<ConceptRevision> revisions,
  ) {
    final originals = {
      for (final concept in review.concepts) concept.id: concept,
    };
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AI 수정안 검토'),
        content: SizedBox(
          width: 680,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: revisions.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final revision = revisions[index];
                final original = originals[revision.id];
                if (original == null) return const SizedBox.shrink();
                final originalNumber = review.concepts.indexWhere(
                  (concept) => concept.id == revision.id,
                );
                return _ConceptRevisionPreview(
                  number: originalNumber + 1,
                  original: original,
                  revision: revision,
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('cancel-concept-revisions-button'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton.icon(
            key: const Key('apply-concept-revisions-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.check_rounded),
            label: const Text('수정안 적용'),
          ),
        ],
      ),
    );
  }
}

class _ConceptRevisionPreview extends StatelessWidget {
  const _ConceptRevisionPreview({
    required this.number,
    required this.original,
    required this.revision,
  });

  final int number;
  final StudyConcept original;
  final ConceptRevision revision;

  @override
  Widget build(BuildContext context) {
    final changes = <Widget>[];
    if (original.title != revision.title) {
      changes.add(
        _RevisionField(
          label: '제목',
          before: original.title,
          after: revision.title,
        ),
      );
    }
    if (original.content != revision.content) {
      changes.add(
        _RevisionField(
          label: '내용',
          before: original.content,
          after: revision.content,
        ),
      );
    }
    final originalPages = original.pageNumbers.join(', ');
    final revisedPages = revision.pageNumbers.join(', ');
    if (originalPages != revisedPages) {
      changes.add(
        _RevisionField(
          label: '페이지',
          before: originalPages,
          after: revisedPages,
        ),
      );
    }
    if (original.importance != revision.importance) {
      changes.add(
        _RevisionField(
          label: '중요도',
          before: original.importance.label,
          after: revision.importance.label,
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$number. ${original.title}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < changes.length; index++) ...[
              changes[index],
              if (index != changes.length - 1) const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _RevisionField extends StatelessWidget {
  const _RevisionField({
    required this.label,
    required this.before,
    required this.after,
  });

  final String label;
  final String before;
  final String after;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        _RevisionValue(
          label: '변경 전',
          value: before,
          color: colorScheme.errorContainer.withValues(alpha: 0.45),
        ),
        const SizedBox(height: 6),
        _RevisionValue(
          label: '변경 후',
          value: after,
          color: colorScheme.primaryContainer.withValues(alpha: 0.55),
        ),
      ],
    );
  }
}

class _RevisionValue extends StatelessWidget {
  const _RevisionValue({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(value),
          ],
        ),
      ),
    );
  }
}

class _ConceptCard extends ConsumerWidget {
  const _ConceptCard({
    required this.number,
    required this.concept,
    required this.folderId,
    required this.provider,
    required this.onRequestRevision,
  });

  final int number;
  final StudyConcept concept;
  final String folderId;
  final DocumentImportControllerProvider provider;
  final VoidCallback onRequestRevision;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ConceptStatusBadge(
                        key: ValueKey('concept-status-${concept.id}'),
                        status: concept.status,
                      ),
                      Chip(label: Text('중요도 ${concept.importance.label}')),
                      Chip(label: Text('p.${concept.pageNumbers.join(', ')}')),
                    ],
                  ),
                ),
                PopupMenuButton<_ConceptAction>(
                  tooltip: '개념 메뉴',
                  onSelected: (action) {
                    switch (action) {
                      case _ConceptAction.edit:
                        _edit(context, ref);
                      case _ConceptAction.delete:
                        _confirmDelete(context, ref);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _ConceptAction.edit,
                      child: Text('수정'),
                    ),
                    PopupMenuItem(
                      value: _ConceptAction.delete,
                      child: Text('삭제'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '$number. ${concept.title}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(concept.content),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: ValueKey('concept-approval-${concept.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('승인'),
              value: concept.status == ConceptStatus.approved,
              onChanged: (value) {
                if (value == null) return;
                ref.read(provider.notifier).setApproved(concept.id, value);
              },
            ),
            OutlinedButton.icon(
              key: ValueKey('request-concept-revision-${concept.id}'),
              onPressed: onRequestRevision,
              icon: const Icon(Icons.auto_fix_high_rounded),
              label: const Text('AI 수정 요청'),
            ),
            const SizedBox(height: 8),
            if (concept.status == ConceptStatus.approved)
              FilledButton.icon(
                onPressed: () => context.push(
                  AppRoutes.aiGenerateForConcept(folderId, concept.id),
                ),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('이 개념으로 문제 생성'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    var title = concept.title;
    var content = concept.content;
    var importance = concept.importance;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('개념 수정'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    initialValue: concept.title,
                    decoration: const InputDecoration(labelText: '제목'),
                    onChanged: (value) => title = value,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: concept.content,
                    minLines: 4,
                    maxLines: 10,
                    decoration: const InputDecoration(labelText: '내용'),
                    onChanged: (value) => content = value,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ConceptImportance>(
                    key: const Key('concept-importance-field'),
                    initialValue: importance,
                    decoration: const InputDecoration(labelText: '중요도'),
                    items: [
                      for (final value in ConceptImportance.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => importance = value);
                      }
                    },
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
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await ref
          .read(provider.notifier)
          .updateConcept(
            conceptId: concept.id,
            title: title,
            content: content,
            importance: importance,
          );
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('개념 삭제'),
        content: Text('${concept.title} 개념을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('confirm-delete-concept-button'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(provider.notifier).deleteConcept(concept.id);
    }
  }
}

class _ConceptStatusBadge extends StatelessWidget {
  const _ConceptStatusBadge({required this.status, super.key});

  final ConceptStatus status;

  @override
  Widget build(BuildContext context) {
    final approved = status == ConceptStatus.approved;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: approved
            ? null
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        gradient: approved
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF66BB6A), Color(0xFF388E3C)],
              )
            : null,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          approved ? '승인됨' : '보류됨',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: approved
                ? Colors.white
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

enum _ConceptAction { edit, delete }

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
                OutlinedButton(
                  onPressed: onBack,
                  child: const Text('PDF 선택 화면'),
                ),
                FilledButton(onPressed: onRetry, child: const Text('다시 선택')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
