import 'package:review_platform/shared/widgets/app_dialog.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_action_group.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/shared/widgets/animated_card_expansion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/formatters/page_number_formatter.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/documents/document_import_view_model.dart';
import 'package:review_platform/features/documents/concept_importance_dialog.dart';
import 'package:review_platform/features/documents/document_job_panel.dart';
import 'package:review_platform/shared/widgets/concept_importance_badge.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:review_platform/shared/widgets/concept_status_badge.dart';
import 'package:review_platform/shared/widgets/pdf_drop_zone.dart';
import 'package:review_platform/shared/widgets/unsaved_changes_guard.dart';

class DocumentImportView extends ConsumerStatefulWidget {
  const DocumentImportView({
    required this.folderId,
    this.initialSourceId,
    this.initialJobId,
    this.initialConceptId,
    super.key,
  });

  final String folderId;
  final String? initialSourceId;
  final String? initialJobId;
  final String? initialConceptId;

  @override
  ConsumerState<DocumentImportView> createState() => _DocumentImportViewState();
}

class _DocumentImportViewState extends ConsumerState<DocumentImportView> {
  bool _initialSourceOpened = false;
  bool _defaultExpanded = true;
  final Map<String, bool> _conceptExpansion = {};

  bool _isExpanded(String id) => _conceptExpansion[id] ?? _defaultExpanded;

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
    ref.listen(controllerProvider, (previous, next) {
      if (next.hasError && !identical(previous?.error, next.error)) {
        showAppError(context, next.error!, fallback: '자료를 처리하지 못했어요.');
      }
    });
    final jobId =
        widget.initialJobId ??
        ref.read(controllerProvider.notifier).activeJobId;
    return Scaffold(
      key: const Key('document-import-view'),
      appBar: AppPageBar(
        fallback: AppRoutes.folder(widget.folderId),
        title: Text(
          state.value?.source.fileName ?? 'PDF 학습자료',
          key: const Key('document-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: PdfDropZone(
        key: const Key('pdf-import-drop-zone'),
        routePath: AppRoutes.documents,
        enabled:
            !state.isLoading &&
            state.value == null &&
            jobId == null &&
            widget.initialSourceId == null,
        onPdfDropped: (document) async {
          await ref.read(controllerProvider.notifier).importPdf(document);
        },
        child: state.when(
          loading: () => const _ImportProgress(),
          error: (error, stackTrace) => _ImportError(
            message: error is AppFailure ? error.message : '자료를 처리하지 못했어요.',
            onBack: () =>
                ref.read(controllerProvider.notifier).showImportPrompt(),
            onRetry: () => widget.initialSourceId == null
                ? ref.read(controllerProvider.notifier).pickAndImport()
                : ref
                      .read(controllerProvider.notifier)
                      .loadSource(widget.initialSourceId!),
          ),
          data: (review) => review == null
              ? jobId == null
                    ? _ImportPrompt(provider: controllerProvider)
                    : DocumentJobPanel(
                        jobId: jobId,
                        onReady: (sourceId) => ref
                            .read(controllerProvider.notifier)
                            .loadSource(sourceId),
                        onUploadAgain: () {
                          ref
                              .read(controllerProvider.notifier)
                              .showImportPrompt();
                          context.replace(
                            AppRoutes.documentsForFolder(widget.folderId),
                          );
                        },
                        onDeleted: () {
                          ref
                              .read(controllerProvider.notifier)
                              .showImportPrompt();
                          context.go(AppRoutes.folder(widget.folderId));
                        },
                      )
              : _ConceptReview(
                  review: review,
                  initialConceptId: widget.initialConceptId,
                  provider: controllerProvider,
                  expandedConceptIds: {
                    for (final concept in review.concepts)
                      if (_isExpanded(concept.id)) concept.id,
                  },
                  onToggleConcept: (id) => setState(() {
                    _conceptExpansion[id] = !_isExpanded(id);
                  }),
                  onSetAllExpanded: (expanded) => setState(() {
                    _defaultExpanded = expanded;
                    _conceptExpansion.clear();
                  }),
                ),
        ),
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
      padding: AppLayout.pagePadding(context),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppLayout.managementWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'PDF에서 학습 개념 추출',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'PDF를 서버에서 분석하고, 페이지 근거가 포함된 검토 필요 상태의 개념을 만듭니다.',
                        ),
                        const SizedBox(height: 16),
                        if (supportsPdfDrop) ...[
                          const Text(
                            '이 화면에 PDF 파일을 끌어다 놓거나 아래 버튼으로 선택해 주세요. (1개 · 용량 제한은 서버 설정에 따릅니다.)',
                          ),
                          const SizedBox(height: 12),
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          key: const Key('pick-pdf-button'),
                          onPressed: () =>
                              ref.read(provider.notifier).pickAndImport(),
                          icon: const Icon(Icons.picture_as_pdf_rounded),
                          label: const Text('PDF 업로드'),
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
  const _ConceptReview({
    required this.review,
    this.initialConceptId,
    required this.provider,
    required this.expandedConceptIds,
    required this.onToggleConcept,
    required this.onSetAllExpanded,
  });

  final StudySourceWithConcepts review;
  final String? initialConceptId;
  final DocumentImportControllerProvider provider;
  final Set<String> expandedConceptIds;
  final ValueChanged<String> onToggleConcept;
  final ValueChanged<bool> onSetAllExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // This screen already builds its concepts eagerly inside one Column.
    // Avoid ListView's synthetic two-pane semantics node: switching tooltip
    // overlays can leave dangling Windows AXTree children (flutter/flutter#182444).
    // Fix the shared ancestor so title, badges, popup menu and source actions
    // keep their tooltips and accessibility without the broken viewport path.
    return SingleChildScrollView(
      key: const Key('concept-review-scroll-view'),
      padding: AppLayout.pagePadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.managementWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${review.source.isManual ? '사용자 생성 자료' : '${review.source.pageCount}페이지'} · 개념 ${review.concepts.length}개',
                          ),
                          const SizedBox(height: 16),
                          LayoutBuilder(
                            key: const Key('source-actions'),
                            builder: (context, constraints) {
                              final showIcons =
                                  constraints.maxWidth >=
                                  480 *
                                      MediaQuery.textScalerOf(context)
                                          .scale(14) /
                                      14;
                              return AppActionGroup(
                                children: [
                                  OutlinedButton.icon(
                                    key: const Key('add-concept-button'),
                                    onPressed: () => _showConceptEditor(
                                      context,
                                      onSave:
                                          (
                                            title,
                                            content,
                                            importance,
                                            reviewed,
                                          ) => ref
                                              .read(provider.notifier)
                                              .addConcept(
                                                title: title,
                                                content: content,
                                                importance: importance,
                                                reviewed: reviewed,
                                              ),
                                    ),
                                    icon: showIcons
                                        ? const Icon(Icons.add_rounded)
                                        : null,
                                    label: const Text(
                                      '개념 추가',
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    key: const Key(
                                      'request-concept-revision-button',
                                    ),
                                    onPressed: () => _requestRevision(
                                      context,
                                      ref,
                                      initialSelectedIds: const {},
                                    ),
                                    icon: showIcons
                                        ? const Icon(
                                            Icons.auto_fix_high_rounded,
                                          )
                                        : null,
                                    label: const Text(
                                      '수정 요청',
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  Tooltip(
                                    message: '이 자료의 검토 완료된 개념으로 문제를 생성합니다.',
                                    child: FilledButton.icon(
                                      key: const Key(
                                        'generate-source-questions-button',
                                      ),
                                      onPressed:
                                          review.concepts.any(
                                            (concept) =>
                                                concept.status ==
                                                ConceptStatus.approved,
                                          )
                                          ? () => context.push(
                                              AppRoutes.aiGenerateForSource(
                                                review.source.folderId,
                                                review.source.id,
                                              ),
                                            )
                                          : null,
                                      icon: showIcons
                                          ? const Icon(
                                              Icons.auto_awesome_rounded,
                                            )
                                          : null,
                                      label: const Text(
                                        '문제 생성',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (review.concepts.isNotEmpty) ...[
                    Align(
                      key: const Key('concept-expansion-actions'),
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            key: const Key('expand-all-concepts'),
                            onPressed:
                                expandedConceptIds.length ==
                                    review.concepts.length
                                ? null
                                : () => onSetAllExpanded(true),
                            icon: const Icon(Icons.unfold_more_rounded),
                            label: const Text('전체 펼치기'),
                          ),
                          TextButton.icon(
                            key: const Key('collapse-all-concepts'),
                            onPressed: expandedConceptIds.isEmpty
                                ? null
                                : () => onSetAllExpanded(false),
                            icon: const Icon(Icons.unfold_less_rounded),
                            label: const Text('전체 접기'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (review.concepts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '아직 개념이 없어요. 개념 추가로 학습 내용을 작성해 주세요.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (
                    var index = 0;
                    index < review.concepts.length;
                    index++
                  ) ...[
                    _ConceptFocusTarget(
                      key: ValueKey(
                        'concept-focus-${review.concepts[index].id}',
                      ),
                      focus: initialConceptId == review.concepts[index].id,
                      child: _ConceptCard(
                        key: ValueKey(review.concepts[index].id),
                        number: index + 1,
                        concept: review.concepts[index],
                        folderId: review.source.folderId,
                        provider: provider,
                        expanded: expandedConceptIds.contains(
                          review.concepts[index].id,
                        ),
                        onToggle: () =>
                            onToggleConcept(review.concepts[index].id),
                        onRequestRevision: () => _requestRevision(
                          context,
                          ref,
                          initialSelectedIds: {review.concepts[index].id},
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
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
    var allowAdditions = false;
    var allowDeletions = false;
    String? errorMessage;
    final proposal = await showDialog<ConceptRevisionProposal>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AppDialog(
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
                  SwitchListTile(
                    key: const Key('allow-concept-additions'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('새 개념 추가 허용'),
                    subtitle: const Text('추가만 요청할 때는 기존 개념을 선택하지 않아도 됩니다.'),
                    value: allowAdditions,
                    onChanged: isSending
                        ? null
                        : (value) =>
                              setDialogState(() => allowAdditions = value),
                  ),
                  SwitchListTile(
                    key: const Key('allow-concept-deletions'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('기존 개념 삭제 허용'),
                    subtitle: const Text(
                      '선택한 개념에 한해 삭제안을 제안합니다. 확인 전에는 삭제하지 않습니다.',
                    ),
                    value: allowDeletions,
                    onChanged: isSending
                        ? null
                        : (value) =>
                              setDialogState(() => allowDeletions = value),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '수정·삭제할 개념 (${selectedIds.length}/${review.concepts.length})',
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
                          title: StudyText('${index + 1}. ${concept.title}'),
                          subtitle: Text(
                            '${concept.status.label}'
                            ' · 중요도 ${concept.importance.label}'
                            '${concept.hasPageSource ? ' · p.${formatPageNumbers(concept.pageNumbers)}' : ''}',
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
                    AppErrorNotice(error: errorMessage!),
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
                      if (selectedIds.isEmpty && !allowAdditions) {
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
                              allowAdditions: allowAdditions,
                              allowDeletions: allowDeletions,
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
                        showAppError(dialogContext, errorMessage!);
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
    if (proposal == null || !context.mounted) return;
    if (proposal.changes.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('수정된 개념이 없어요.')));
      return;
    }
    final selection = await _confirmRevisions(context, proposal);
    if (selection == null || !context.mounted) return;
    final markReviewed =
        selection.action == _RevisionApplyAction.applyAndReview;
    int changedCount;
    try {
      changedCount = await ref
          .read(provider.notifier)
          .applyConceptRevisions(
            proposal,
            selection.changes,
            markReviewed: markReviewed,
          );
    } catch (error) {
      if (!context.mounted) return;
      showAppError(context, error, fallback: '개념 수정안을 적용하지 못했어요.');
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          changedCount == 0
              ? '수정된 개념이 없어요.'
              : markReviewed
              ? '$changedCount개 변경을 적용했어요. 추가·수정 개념을 검토 완료로 표시했어요.'
              : '$changedCount개 변경을 적용했어요. 추가·수정 개념은 검토 필요 상태예요.',
        ),
      ),
    );
  }

  Future<_RevisionSelection?> _confirmRevisions(
    BuildContext context,
    ConceptRevisionProposal proposal,
  ) {
    final revisions = proposal.changes;
    final originals = {
      for (final concept in proposal.original.concepts) concept.id: concept,
    };
    final deletionGroups = revisions
        .where((item) => item.kind == ConceptChangeKind.delete)
        .map((item) => item.groupId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final selected = <int>{
      for (var index = 0; index < revisions.length; index++)
        if (revisions[index].kind != ConceptChangeKind.delete &&
            !deletionGroups.contains(revisions[index].groupId))
          index,
    };
    String label(ConceptChangeKind kind) => switch (kind) {
      ConceptChangeKind.update => '수정',
      ConceptChangeKind.add => '추가',
      ConceptChangeKind.delete => '삭제',
    };
    void apply(BuildContext dialogContext, _RevisionApplyAction action) =>
        Navigator.pop(
          dialogContext,
          _RevisionSelection(action, [
            for (var i = 0; i < revisions.length; i++)
              if (selected.contains(i)) revisions[i],
          ]),
        );
    return showDialog<_RevisionSelection>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AppDialog(
          title: const Text('AI 수정안 검토'),
          content: SizedBox(
            width: 680,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    ConceptChangeKind.values
                        .map(
                          (kind) =>
                              '${label(kind)} ${revisions.where((item) => item.kind == kind).length}개',
                        )
                        .join(' · '),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '적용할 변경을 선택해 주세요. (${selected.length}/${revisions.length})\n삭제 및 삭제가 포함된 연결 그룹은 기본 미선택입니다.',
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      key: const Key('concept-changes-list'),
                      shrinkWrap: true,
                      itemCount: revisions.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final revision = revisions[index];
                        final original = originals[revision.id];
                        final originalNumber = proposal.original.concepts
                            .indexWhere((concept) => concept.id == revision.id);
                        return Card(
                          margin: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              CheckboxListTile(
                                key: ValueKey('select-concept-change-$index'),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: selected.contains(index),
                                title: StudyText(
                                  '${label(revision.kind)} · ${original?.title ?? revision.title}',
                                ),
                                subtitle: revision.groupId.isEmpty
                                    ? null
                                    : Text(
                                        '연결된 변경: ${revision.groupId} · 그룹 전체가 함께 선택됩니다.',
                                      ),
                                onChanged: (value) => setDialogState(() {
                                  for (var i = 0; i < revisions.length; i++) {
                                    if (i == index ||
                                        (revision.groupId.isNotEmpty &&
                                            revisions[i].groupId ==
                                                revision.groupId)) {
                                      if (value == true) {
                                        selected.add(i);
                                      } else {
                                        selected.remove(i);
                                      }
                                    }
                                  }
                                }),
                              ),
                              if (revision.kind == ConceptChangeKind.update &&
                                  original != null)
                                _ConceptRevisionPreview(
                                  number: originalNumber + 1,
                                  original: original,
                                  revision: revision,
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      StudyText(
                                        revision.kind ==
                                                ConceptChangeKind.delete
                                            ? original?.content ?? ''
                                            : revision.content,
                                        selectable: true,
                                      ),
                                      const SizedBox(height: 8),
                                      if (revision.kind ==
                                          ConceptChangeKind.add) ...[
                                        Text(
                                          '중요도 ${revision.importance.label}',
                                        ),
                                        Text(
                                          revision.pageNumbers.isEmpty
                                              ? 'PDF 페이지 출처 없음'
                                              : 'p.${formatPageNumbers(revision.pageNumbers)}',
                                        ),
                                      ],
                                      if (revision.reason.isNotEmpty)
                                        Text('이유: ${revision.reason}'),
                                      if (revision.kind ==
                                          ConceptChangeKind.delete)
                                        const Text('기존 문제와 풀이 기록은 유지됩니다.'),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const Key('cancel-concept-revisions-button'),
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            OutlinedButton(
              key: const Key('apply-concept-revisions-button'),
              onPressed: selected.isEmpty
                  ? null
                  : () => apply(dialogContext, _RevisionApplyAction.apply),
              child: const Text('적용'),
            ),
            FilledButton(
              key: const Key('apply-and-review-concept-revisions-button'),
              onPressed: selected.isEmpty
                  ? null
                  : () => apply(
                      dialogContext,
                      _RevisionApplyAction.applyAndReview,
                    ),
              child: const Text('적용 후 검토 완료'),
            ),
          ],
        ),
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
    final originalPages = formatPageNumbers(original.pageNumbers);
    final revisedPages = formatPageNumbers(revision.pageNumbers);
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
            StudyText(value, selectable: true),
          ],
        ),
      ),
    );
  }
}

class _DesktopConceptSelection extends StatelessWidget {
  const _DesktopConceptSelection({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => SelectionArea(child: child),
    _ => child,
  };
}

class _ConceptCard extends ConsumerStatefulWidget {
  const _ConceptCard({
    required this.number,
    required this.concept,
    required this.folderId,
    required this.provider,
    required this.onRequestRevision,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final int number;
  final StudyConcept concept;
  final String folderId;
  final DocumentImportControllerProvider provider;
  final VoidCallback onRequestRevision;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  ConsumerState<_ConceptCard> createState() => _ConceptCardState();
}

class _ConceptCardState extends ConsumerState<_ConceptCard> {
  bool _saving = false;
  bool _importanceDialogOpen = false;
  int get number => widget.number;
  StudyConcept get concept => widget.concept;
  String get folderId => widget.folderId;
  DocumentImportControllerProvider get provider => widget.provider;
  VoidCallback get onRequestRevision => widget.onRequestRevision;
  bool get expanded => widget.expanded;
  VoidCallback get onToggle => widget.onToggle;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedCardHeader(child: _header(context, ref)),
            AnimatedCardBody(
              key: ValueKey('concept-details-${concept.id}'),
              expanded: expanded,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 4),
                  Wrap(
                    key: ValueKey('concept-badges-${concept.id}'),
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: _badges(context, ref, compact: false),
                  ),
                  const SizedBox(height: 8),
                  _DesktopConceptSelection(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: AppLayout.readingWidth,
                        ),
                        child: StudyText(
                          concept.content,
                          key: ValueKey('concept-content-${concept.id}'),
                        ),
                      ),
                    ),
                  ),
                  Divider(
                    key: ValueKey('concept-actions-divider-${concept.id}'),
                    height: 24,
                  ),
                  LayoutBuilder(
                    key: ValueKey('concept-actions-${concept.id}'),
                    builder: (context, constraints) {
                      final wide =
                          constraints.maxWidth >=
                          600 * MediaQuery.textScalerOf(context).scale(14) / 14;
                      final approval = Row(
                        mainAxisSize: wide
                            ? MainAxisSize.min
                            : MainAxisSize.max,
                        mainAxisAlignment: wide
                            ? MainAxisAlignment.start
                            : MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('검토 완료'),
                          const SizedBox(width: 4),
                          Semantics(
                            label: '${concept.title} 검토 완료',
                            child: Switch(
                              key: ValueKey('concept-approval-${concept.id}'),
                              value: concept.status == ConceptStatus.approved,
                              onChanged: _saving
                                  ? null
                                  : (value) =>
                                        _setApproved(context, ref, value),
                            ),
                          ),
                        ],
                      );
                      final revision = OutlinedButton.icon(
                        key: ValueKey('request-concept-revision-${concept.id}'),
                        onPressed: onRequestRevision,
                        icon: const Icon(Icons.auto_fix_high_rounded),
                        label: const Text('AI 수정 요청'),
                      );
                      final generation = FilledButton.icon(
                        key: ValueKey(
                          'generate-concept-questions-${concept.id}',
                        ),
                        onPressed: concept.status == ConceptStatus.approved
                            ? () => context.push(
                                AppRoutes.aiGenerateForConcept(
                                  folderId,
                                  concept.id,
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('이 개념으로 문제 생성'),
                      );
                      if (wide) {
                        return AppActionGroup(
                          minimumButtonWidth: 190,
                          children: [approval, revision, generation],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          approval,
                          const SizedBox(height: 8),
                          revision,
                          const SizedBox(height: 8),
                          generation,
                        ],
                      );
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: ValueKey('view-concept-questions-${concept.id}'),
                      onPressed: () => context.push(
                        AppRoutes.questionsForConcept(
                          concept.id,
                          concept.title,
                        ),
                      ),
                      icon: const Icon(Icons.quiz_outlined),
                      label: const Text('연결된 문제 모두 보기'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _badges(
    BuildContext context,
    WidgetRef ref, {
    required bool compact,
  }) => [
    _ConceptBadgeAction(
      key: ValueKey('concept-status-${concept.id}'),
      label: '${concept.title} ${concept.status.label}',
      tooltip: concept.status == ConceptStatus.approved
          ? '검토 필요로 변경'
          : '검토 완료로 변경',
      toggled: concept.status == ConceptStatus.approved,
      onTap: _saving
          ? null
          : () => _setApproved(
              context,
              ref,
              concept.status != ConceptStatus.approved,
            ),
      child: ConceptStatusBadge(status: concept.status, compact: compact),
    ),
    _ConceptBadgeAction(
      key: ValueKey('concept-importance-${concept.id}'),
      label: '${concept.title} 중요도 ${concept.importance.label}',
      tooltip: '중요도 변경',
      onTap: _saving || _importanceDialogOpen ? null : _editImportance,
      child: ConceptImportanceBadge(
        importance: concept.importance,
        compact: compact,
      ),
    ),
    if (concept.hasPageSource)
      Tooltip(
        message: 'p.${formatPageNumbers(concept.pageNumbers)}',
        child: ConceptBadge(
          key: ValueKey('concept-page-source-${concept.id}'),
          label: 'p.${formatPageNumbers(concept.pageNumbers)}',
          compact: compact,
        ),
      ),
  ];

  Widget _header(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, constraints) {
      final badges = _badges(context, ref, compact: true);
      final inlineBadges =
          constraints.maxWidth >=
          480 * MediaQuery.textScalerOf(context).scale(14) / 14;
      final titleRow = Row(
        key: ValueKey('concept-header-${concept.id}'),
        crossAxisAlignment: expanded
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  fit: expanded ? FlexFit.tight : FlexFit.loose,
                  child: Semantics(
                    button: true,
                    expanded: expanded,
                    child: _DesktopConceptSelection(
                      child: Tooltip(
                        message:
                            '${expanded ? '접기' : '펼치기'}: $number. ${concept.title}',
                        child: InkWell(
                          key: ValueKey('concept-toggle-${concept.id}'),
                          onTap: onToggle,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisSize: expanded
                                  ? MainAxisSize.max
                                  : MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AnimatedRotation(
                                  turns: expanded ? 0.25 : 0,
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : cardExpansionDuration,
                                  curve: Curves.easeInOutCubic,
                                  child: const Icon(Icons.arrow_right_rounded),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  fit: expanded ? FlexFit.tight : FlexFit.loose,
                                  child: StudyText(
                                    '$number. ${concept.title}',
                                    key: ValueKey(
                                      'concept-title-${concept.id}',
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                    maxLines: expanded ? null : 1,
                                    overflow: expanded
                                        ? null
                                        : TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!expanded && inlineBadges) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.65,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var index = 0; index < badges.length; index++) ...[
                          if (index > 0) const SizedBox(width: 4),
                          Flexible(child: badges[index]),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!expanded) const SizedBox(width: 4),
          SizedBox(
            width: AppLayout.touchTarget,
            height: AppLayout.touchTarget,
            child: PopupMenuButton<_ConceptAction>(
              key: ValueKey('concept-menu-${concept.id}'),
              tooltip: '개념 메뉴',
              iconSize: 20,
              padding: EdgeInsets.zero,
              onSelected: (action) {
                switch (action) {
                  case _ConceptAction.edit:
                    _edit(context, ref);
                  case _ConceptAction.delete:
                    _confirmDelete(context, ref);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: _ConceptAction.edit, child: Text('수정')),
                PopupMenuItem(value: _ConceptAction.delete, child: Text('삭제')),
              ],
            ),
          ),
        ],
      );
      if (expanded || inlineBadges) return titleRow;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          titleRow,
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: badges,
          ),
        ],
      );
    },
  );

  Future<void> _setApproved(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(provider.notifier).setApproved(concept.id, value);
    } catch (error) {
      if (!context.mounted) return;
      showAppError(context, error, fallback: '검토 상태를 변경하지 못했어요.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editImportance() async {
    if (_saving || _importanceDialogOpen) return;
    final controller = ref.read(provider.notifier);
    final id = concept.id;
    setState(() => _importanceDialogOpen = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ConceptImportanceDialog(
          title: concept.title,
          initialImportance: concept.importance,
          onSave: (importance) => controller.setImportance(id, importance),
        ),
      );
    } finally {
      if (mounted) setState(() => _importanceDialogOpen = false);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) => _showConceptEditor(
    context,
    initialConcept: concept,
    onSave: (title, content, importance, _) => ref
        .read(provider.notifier)
        .updateConcept(
          conceptId: concept.id,
          title: title,
          content: content,
          importance: importance,
        ),
  );

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
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

class _ConceptFocusTarget extends StatefulWidget {
  const _ConceptFocusTarget({
    required this.focus,
    required this.child,
    super.key,
  });
  final bool focus;
  final Widget child;
  @override
  State<_ConceptFocusTarget> createState() => _ConceptFocusTargetState();
}

class _ConceptFocusTargetState extends State<_ConceptFocusTarget> {
  final _target = GlobalKey();
  @override
  void initState() {
    super.initState();
    if (widget.focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final targetContext = _target.currentContext;
        if (mounted && targetContext != null) {
          Scrollable.ensureVisible(
            targetContext,
            duration: const Duration(milliseconds: 250),
            alignment: 0.05,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(key: _target, child: widget.child);
}

class _ConceptBadgeAction extends StatelessWidget {
  const _ConceptBadgeAction({
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.toggled,
    super.key,
  });
  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;
  final bool? toggled;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    enabled: onTap != null,
    toggled: toggled,
    // Descendant semantics are excluded to avoid duplicate chip/button nodes;
    // expose the action here so screen readers can still activate the badge.
    onTap: onTap,
    excludeSemantics: true,
    child: Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          // The visual Chip stays passive; this control owns taps and focus.
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: AppLayout.touchTarget,
              minHeight: AppLayout.touchTarget,
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: IgnorePointer(child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _showConceptEditor(
  BuildContext context, {
  StudyConcept? initialConcept,
  required Future<void> Function(String, String, ConceptImportance, bool)
  onSave,
}) async {
  final formKey = GlobalKey<FormState>();
  var title = initialConcept?.title ?? '';
  var content = initialConcept?.content ?? '';
  var importance = initialConcept?.importance ?? ConceptImportance.medium;
  var reviewed =
      initialConcept == null || initialConcept.status == ConceptStatus.approved;
  final initialEditState = (title, content, importance, reviewed);
  final exitGuardKey = GlobalKey<UnsavedChangesGuardState>();
  var saving = false;
  String? errorMessage;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<bool> save() async {
          if (saving || !(formKey.currentState?.validate() ?? false)) {
            return false;
          }
          setDialogState(() {
            saving = true;
            errorMessage = null;
          });
          try {
            await onSave(title, content, importance, reviewed);
            return true;
          } catch (error) {
            if (!dialogContext.mounted) return false;
            setDialogState(() {
              errorMessage = error is AppFailure
                  ? error.message
                  : '개념을 저장하지 못했어요.';
            });
            showAppError(dialogContext, errorMessage!);
            return false;
          } finally {
            if (dialogContext.mounted) setDialogState(() => saving = false);
          }
        }

        return UnsavedChangesGuard(
          key: exitGuardKey,
          hasChanges:
              (title, content, importance, reviewed) != initialEditState,
          busy: saving,
          onSave: save,
          child: AppDialog(
            title: Text(initialConcept == null ? '개념 추가' : '개념 수정'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        key: const Key('concept-title-field'),
                        initialValue: title,
                        enabled: !saving,
                        autofocus: initialConcept == null,
                        maxLength: 200,
                        decoration: const InputDecoration(labelText: '제목'),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '제목을 입력해 주세요.'
                            : null,
                        onChanged: (value) =>
                            setDialogState(() => title = value),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('concept-content-field'),
                        initialValue: content,
                        enabled: !saving,
                        minLines: 4,
                        maxLines: 10,
                        maxLength: 8000,
                        decoration: const InputDecoration(
                          labelText: '내용',
                          helperText: studyNotationInputHint,
                          helperMaxLines: 3,
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '내용을 입력해 주세요.'
                            : null,
                        onChanged: (value) =>
                            setDialogState(() => content = value),
                      ),
                      const SizedBox(height: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Text('중요도'),
                              const Spacer(),
                              Text(
                                importance.label,
                                key: const Key('concept-importance-label'),
                              ),
                            ],
                          ),
                          Slider(
                            key: const Key('concept-importance-field'),
                            value: importance.index.toDouble(),
                            min: 0,
                            max: 4,
                            divisions: 4,
                            label: importance.label,
                            semanticFormatterCallback: (value) =>
                                ConceptImportance.values[value.round()].label,
                            onChanged: saving
                                ? null
                                : (value) => setDialogState(() {
                                    importance =
                                        ConceptImportance.values[value.round()];
                                  }),
                          ),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [Text('매우 낮음'), Text('매우 높음')],
                          ),
                        ],
                      ),
                      if (initialConcept == null)
                        SwitchListTile(
                          key: const Key('new-concept-reviewed-field'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('검토 완료'),
                          subtitle: const Text('직접 작성한 내용을 바로 문제 생성에 사용합니다.'),
                          value: reviewed,
                          onChanged: saving
                              ? null
                              : (value) =>
                                    setDialogState(() => reviewed = value),
                        ),
                      if (errorMessage != null) ...[
                        const SizedBox(height: 12),
                        AppErrorNotice(error: errorMessage!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving
                    ? null
                    : () => exitGuardKey.currentState?.requestExit(),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const Key('save-concept-button'),
                onPressed: saving
                    ? null
                    : () async {
                        if (await save() && dialogContext.mounted) {
                          await exitGuardKey.currentState?.close();
                        }
                      },
                child: Text(saving ? '저장 중…' : '저장'),
              ),
            ],
          ),
        );
      },
    ),
  );
}

enum _ConceptAction { edit, delete }

enum _RevisionApplyAction { apply, applyAndReview }

class _RevisionSelection {
  const _RevisionSelection(this.action, this.changes);
  final _RevisionApplyAction action;
  final List<ConceptRevision> changes;
}

class _ImportProgress extends StatelessWidget {
  const _ImportProgress();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
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
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppErrorNotice(error: message),
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
