import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
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
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onEdit,
    required this.onDelete,
  });

  final Question question;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          question.type == QuestionType.multipleChoice
              ? Icons.format_list_numbered_rounded
              : Icons.short_text_rounded,
        ),
        title: Text(
          question.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          question.type == QuestionType.multipleChoice ? '객관식' : '단답형',
        ),
        trailing: PopupMenuButton<_QuestionAction>(
          tooltip: '문제 메뉴',
          onSelected: (action) {
            switch (action) {
              case _QuestionAction.edit:
                onEdit();
              case _QuestionAction.delete:
                onDelete();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: _QuestionAction.edit, child: Text('수정')),
            PopupMenuItem(value: _QuestionAction.delete, child: Text('삭제')),
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

enum _QuestionAction { edit, delete }
