import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/question_list/question_list_view_model.dart';

class QuestionListView extends ConsumerWidget {
  const QuestionListView({required this.folderId, super.key});

  final String folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = questionListViewModelProvider(folderId);
    final questions = ref.watch(provider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '문제',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                key: const Key('generate-ai-questions-nav-button'),
                tooltip: 'AI 문제 생성',
                onPressed: () =>
                    context.push(AppRoutes.aiGenerateForFolder(folderId)),
                icon: const Icon(Icons.auto_awesome_rounded),
              ),
              const SizedBox(width: 4),
              FilledButton.tonalIcon(
                key: const Key('add-question-button'),
                onPressed: () => context.push(
                  Uri(
                    path: AppRoutes.newQuestion,
                    queryParameters: {'folderId': folderId},
                  ).toString(),
                ),
                icon: const Icon(Icons.add_rounded),
                label: const Text('문제 추가'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          questions.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (error, stackTrace) => _QuestionError(
              message: error is AppFailure
                  ? error.message
                  : '문제 목록을 불러오지 못했어요.',
              onRetry: () => ref.invalidate(provider),
            ),
            data: (items) {
              if (items.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('이 폴더에 저장된 문제가 없어요.')),
                  ),
                );
              }

              return Column(
                children: [
                  for (final question in items) ...[
                    _QuestionCard(
                      question: question,
                      onApprove: () =>
                          _approveQuestion(context, ref, provider, question),
                      onEdit: () =>
                          context.push(AppRoutes.editQuestion(question.id)),
                      onDelete: () =>
                          _deleteQuestion(context, ref, provider, question),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteQuestion(
    BuildContext context,
    WidgetRef ref,
    QuestionListViewModelProvider provider,
    Question question,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('문제 삭제'),
        content: const Text('이 문제를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(provider.notifier).deleteQuestion(question.id);
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '문제를 삭제하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _approveQuestion(
    BuildContext context,
    WidgetRef ref,
    QuestionListViewModelProvider provider,
    Question question,
  ) async {
    try {
      await ref.read(provider.notifier).approveQuestion(question.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Draft 문제를 승인했어요.')));
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '문제를 승인하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onApprove,
    required this.onEdit,
    required this.onDelete,
  });

  final Question question;
  final VoidCallback onApprove;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(switch (question.type) {
          QuestionType.multipleChoice => Icons.format_list_numbered_rounded,
          QuestionType.trueFalse => Icons.rule_rounded,
          QuestionType.shortAnswer => Icons.short_text_rounded,
          QuestionType.essay => Icons.notes_rounded,
        }),
        title: Text(
          question.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${switch (question.type) {
            QuestionType.multipleChoice => '객관식',
            QuestionType.trueFalse => 'O/X',
            QuestionType.shortAnswer => '단답형',
            QuestionType.essay => '서술형',
          }}'
          '${question.status.name == 'draft' ? ' · Draft' : ''}',
        ),
        trailing: PopupMenuButton<_QuestionAction>(
          tooltip: '문제 메뉴',
          onSelected: (action) {
            switch (action) {
              case _QuestionAction.approve:
                onApprove();
              case _QuestionAction.edit:
                onEdit();
              case _QuestionAction.delete:
                onDelete();
            }
          },
          itemBuilder: (context) => [
            if (question.status == QuestionStatus.draft)
              const PopupMenuItem(
                value: _QuestionAction.approve,
                child: Text('Draft 승인'),
              ),
            const PopupMenuItem(value: _QuestionAction.edit, child: Text('수정')),
            const PopupMenuItem(
              value: _QuestionAction.delete,
              child: Text('삭제'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuestionError extends StatelessWidget {
  const _QuestionError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(message),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ),
      ),
    );
  }
}

enum _QuestionAction { approve, edit, delete }
