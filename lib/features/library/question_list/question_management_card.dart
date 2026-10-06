import 'package:review_platform/shared/widgets/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/formatters/page_number_formatter.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/shared/widgets/animated_card_expansion.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:review_platform/shared/widgets/concept_importance_badge.dart';
import 'package:review_platform/shared/widgets/review_status_badge.dart';

String questionTypeLabel(QuestionType type) => switch (type) {
  QuestionType.multipleChoice => '객관식',
  QuestionType.trueFalse => 'O/X',
  QuestionType.shortAnswer => '단답형',
  QuestionType.essay => '서술형',
};

String questionStatusLabel(QuestionStatus status) => switch (status) {
  QuestionStatus.draft => '미승인',
  QuestionStatus.approved => '승인됨',
  QuestionStatus.archived => '보관됨',
};

enum QuestionManagementAction { approve, edit, move, delete }

/// A whole-card expansion target; checkboxes, menus and links keep their own
/// gestures so interacting with them does not unexpectedly collapse the card.
class QuestionManagementCard extends StatefulWidget {
  const QuestionManagementCard({
    required this.question,
    required this.onAction,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.selected = false,
    this.onSelect,
    this.enabled = true,
    super.key,
  });

  final Question question;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final ValueChanged<QuestionManagementAction> onAction;
  final bool selected;
  final ValueChanged<bool>? onSelect;
  final bool enabled;

  @override
  State<QuestionManagementCard> createState() => _QuestionManagementCardState();
}

class _QuestionManagementCardState extends State<QuestionManagementCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant QuestionManagementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.question.id != widget.question.id) {
      _expanded = widget.initiallyExpanded;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    // Remember the state for filtering without rebuilding the parent list.
    widget.onExpansionChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question;
    final expanded = _expanded;
    final enabled = widget.enabled;
    final selected = widget.selected;
    final onSelect = widget.onSelect;
    final onAction = widget.onAction;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('question-card-${question.id}'),
        onTap: enabled ? _toggle : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedCardHeader(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (onSelect != null)
                          Semantics(
                            label: '문제 선택: ${question.prompt}',
                            child: Checkbox(
                              key: ValueKey('select-question-${question.id}'),
                              value: selected,
                              onChanged: enabled
                                  ? (value) => onSelect(value ?? false)
                                  : null,
                            ),
                          ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              question.prompt,
                              key: ValueKey('question-prompt-${question.id}'),
                              maxLines: expanded ? null : 2,
                              overflow: expanded ? null : TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                        PopupMenuButton<QuestionManagementAction>(
                          key: ValueKey('question-menu-${question.id}'),
                          enabled: enabled,
                          tooltip: '문제 메뉴',
                          onSelected: onAction,
                          itemBuilder: (context) => [
                            if (question.status == QuestionStatus.draft)
                              const PopupMenuItem(
                                value: QuestionManagementAction.approve,
                                child: Text('승인'),
                              ),
                            const PopupMenuItem(
                              value: QuestionManagementAction.edit,
                              child: Text('수정'),
                            ),
                            const PopupMenuItem(
                              value: QuestionManagementAction.move,
                              child: Text('이동'),
                            ),
                            const PopupMenuItem(
                              value: QuestionManagementAction.delete,
                              child: Text('삭제'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Wrap(
                      key: ValueKey('question-badges-${question.id}'),
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        ConceptBadge(
                          label: questionTypeLabel(question.type),
                          compact: true,
                        ),
                        ConceptBadge(
                          label: '난이도 ${question.difficulty}/5',
                          compact: true,
                        ),
                        ConceptImportanceBadge(
                          importance: question.importance,
                          compact: true,
                          showPrefix: true,
                        ),
                        ReviewStatusBadge(
                          reviewed: question.status == QuestionStatus.approved,
                          label: questionStatusLabel(question.status),
                          compact: true,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              AnimatedCardBody(
                key: ValueKey('question-details-${question.id}'),
                expanded: expanded,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Divider(
                      key: ValueKey('question-answer-divider-${question.id}'),
                      height: 24,
                    ),
                    Text(
                      '선택지 / 정답',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    if (question.choices.isNotEmpty)
                      for (final choice in question.choices)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 26,
                                child: choice.isCorrect
                                    ? Icon(
                                        Icons.check_rounded,
                                        size: 20,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        semanticLabel: '정답',
                                      )
                                    : null,
                              ),
                              Expanded(
                                child: Text(
                                  '${question.type == QuestionType.trueFalse ? '' : '${choice.position + 1}. '}${choice.text}',
                                ),
                              ),
                            ],
                          ),
                        )
                    else if (question.acceptableAnswers.isNotEmpty)
                      Text(
                        question.acceptableAnswers
                            .map((answer) => answer.text)
                            .join('\n'),
                      )
                    else
                      const Text('등록된 정답이 없어요.'),
                    Divider(
                      key: ValueKey(
                        'question-explanation-divider-${question.id}',
                      ),
                      height: 24,
                    ),
                    Text('해설', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Text(
                      question.explanation?.trim().isNotEmpty == true
                          ? question.explanation!
                          : '등록된 해설이 없어요.',
                    ),
                    Divider(
                      key: ValueKey('question-source-divider-${question.id}'),
                      height: 24,
                    ),
                    Text('출처', style: Theme.of(context).textTheme.labelLarge),
                    if (question.sourceReferences.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('연결된 출처가 없어요.'),
                      ),
                    for (final reference in question.sourceReferences) ...[
                      const SizedBox(height: 8),
                      Text(questionSourceLabel(reference)),
                      if (reference.conceptId != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: ValueKey(
                              'view-question-concept-${question.id}-${reference.conceptId}',
                            ),
                            onPressed: enabled
                                ? () => showQuestionConcept(context, reference)
                                : null,
                            icon: const Icon(Icons.account_tree_outlined),
                            label: const Text('연결된 개념 보기'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String questionSourceLabel(QuestionSourceReference reference) {
  final pages = reference.pageNumbers.isEmpty
      ? ''
      : ' · p.${formatPageNumbers(reference.pageNumbers)}';
  final concept = reference.conceptTitle == null
      ? ''
      : ' · ${reference.conceptTitle}';
  return '출처: ${reference.fileName}$pages$concept';
}

Future<void> showQuestionConcept(
  BuildContext context,
  QuestionSourceReference reference,
) {
  final navigationContext = context;
  final repository = ProviderScope.containerOf(context)
      .read(sourceRepositoryProvider);
  final future = repository.getSourceWithConcepts(reference.sourceId);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AppDialog(
      title: const Text('연결된 개념'),
      content: SizedBox(
        width: 640,
        child: FutureBuilder<StudySourceWithConcepts>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return AppErrorNotice(
                error: snapshot.error is AppFailure
                    ? (snapshot.error as AppFailure).message
                    : '연결된 개념을 불러오지 못했어요.',
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!;
            final concept = data.concepts
                .where((concept) => concept.id == reference.conceptId)
                .firstOrNull;
            if (concept == null) return const Text('연결된 개념이 삭제되었거나 존재하지 않아요.');
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    concept.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ConceptImportanceBadge(importance: concept.importance),
                  const Divider(),
                  Text(concept.content),
                  const Divider(),
                  Text(data.source.fileName),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      if (!navigationContext.mounted) return;
                      navigationContext.push(
                        AppRoutes.documentsForConcept(
                          data.source.folderId,
                          data.source.id,
                          concept.id,
                        ),
                      );
                    },
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('자료에서 보기'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('닫기'),
        ),
      ],
    ),
  );
}
