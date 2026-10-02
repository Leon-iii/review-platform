import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/documents/document_import_view_model.dart';
import 'package:review_platform/features/library/folder_browser/folder_browser_view_model.dart';
import 'package:review_platform/features/library/question_list/question_list_view_model.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';
import 'package:review_platform/shared/widgets/pdf_drop_zone.dart';

class QuestionListView extends ConsumerWidget {
  const QuestionListView({required this.folderId, super.key});

  final String folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = questionListViewModelProvider(folderId);
    final questions = ref.watch(provider);
    final sources = ref.watch(documentSourcesProvider(folderId));

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PdfDropZone(
            key: const Key('folder-pdf-drop-zone'),
            routePath: AppRoutes.folder(folderId),
            onPdfDropped: (document) async {
              // Start on the next frame, after the destination watches the
              // auto-disposed controller, so the dropped import stays alive.
              context.push(AppRoutes.documentsForFolder(folderId));
              await WidgetsBinding.instance.endOfFrame;
              if (!context.mounted) return;
              await ref
                  .read(documentImportControllerProvider(folderId).notifier)
                  .importPdf(document);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '자료',
                        key: const Key('source-section-header'),
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      key: const Key('import-pdf-nav-button'),
                      tooltip: 'PDF 가져오기',
                      onPressed: () =>
                          context.push(AppRoutes.documentsForFolder(folderId)),
                      icon: const Icon(Icons.upload_file_rounded),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.tonalIcon(
                      key: const Key('create-source-button'),
                      onPressed: () => _createSource(context, ref),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('새 자료'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (supportsPdfDrop) ...[
                  const Text(
                    '이 자료 영역에 PDF 파일을 끌어다 놓아 가져올 수 있어요. (1개 · 최대 25MB)',
                  ),
                  const SizedBox(height: 12),
                ],
                sources.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (error, stackTrace) => _QuestionError(
                    message: error is AppFailure
                        ? error.message
                        : '자료를 불러오지 못했어요.',
                    onRetry: () =>
                        ref.invalidate(documentSourcesProvider(folderId)),
                  ),
                  data: (items) => items.isEmpty
                      ? const Card(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                '이 폴더에 자료가 없어요. 새 자료를 만들거나 PDF를 가져와 주세요.',
                              ),
                            ),
                          ),
                        )
                      : Column(
                          children: [
                            for (final source in items) ...[
                              _PdfSourceCard(
                                source: source,
                                onOpen: () => context.push(
                                  AppRoutes.documentsForSource(
                                    folderId,
                                    source.id,
                                  ),
                                ),
                                onEdit: () => _renameSource(
                                  context,
                                  ref,
                                  provider,
                                  source,
                                ),
                                onMove: () => _moveItem(
                                  context,
                                  ref,
                                  title: '자료 이동',
                                  itemLabel: '자료',
                                  move: (targetId) => ref
                                      .read(provider.notifier)
                                      .moveSource(
                                        id: source.id,
                                        folderId: targetId,
                                      ),
                                ),
                                onDelete: () => _deleteSource(
                                  context,
                                  ref,
                                  provider,
                                  source,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
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
                      onMove: () => _moveItem(
                        context,
                        ref,
                        title: '문제 이동',
                        itemLabel: '문제',
                        move: (targetId) => ref
                            .read(provider.notifier)
                            .moveQuestion(id: question.id, folderId: targetId),
                      ),
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

  Future<void> _createSource(BuildContext context, WidgetRef ref) async {
    final formKey = GlobalKey<FormState>();
    var name = '';
    var saving = false;
    String? errorMessage;
    final created = await showDialog<StudySourceWithConcepts>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: const Text('새 자료'),
            content: SizedBox(
              width: 480,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      key: const Key('new-source-name-field'),
                      autofocus: true,
                      enabled: !saving,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: '자료 이름'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '자료 이름을 입력해 주세요.'
                          : null,
                      onChanged: (value) => name = value,
                    ),
                    if (errorMessage != null)
                      Text(
                        errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const Key('save-new-source-button'),
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setDialogState(() {
                          saving = true;
                          errorMessage = null;
                        });
                        try {
                          final result = await ref
                              .read(sourceRepositoryProvider)
                              .createSource(folderId: folderId, name: name);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, result);
                          }
                        } catch (error) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() {
                            saving = false;
                            errorMessage = error is AppFailure
                                ? error.message
                                : '자료를 만들지 못했어요.';
                          });
                        }
                      },
                child: Text(saving ? '생성 중…' : '만들기'),
              ),
            ],
          ),
        ),
      ),
    );
    if (created == null || !context.mounted) return;
    ref.invalidate(documentSourcesProvider(folderId));
    context.push(AppRoutes.documentsForSource(folderId, created.source.id));
  }

  Future<void> _moveItem(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String itemLabel,
    required Future<void> Function(String folderId) move,
  }) async {
    try {
      final state = await ref.read(
        folderBrowserViewModelProvider(folderId).future,
      );
      if (!context.mounted) return;
      final folders = state.allFolders;
      if (!folders.any((folder) => folder.id != folderId)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이동할 다른 폴더를 먼저 만들어 주세요.')));
        return;
      }

      final selection = await showFolderPicker(
        context,
        folders: folders,
        selectedFolderId: folderId,
        title: title,
      );
      if (selection == null || !context.mounted) return;
      final targetId = selection.folderId;
      if (targetId == null || targetId == folderId) return;

      await move(targetId);
      if (!context.mounted) return;
      // PDF lists are future providers, unlike the live question/folder lists.
      ref.invalidate(documentSourcesProvider(folderId));
      ref.invalidate(documentSourcesProvider(targetId));
      final target = folders.firstWhere((folder) => folder.id == targetId);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('$itemLabel 항목을 ${target.name} 폴더로 이동했어요.')),
        );
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure
          ? error.message
          : '$itemLabel 항목을 이동하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
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

  Future<void> _renameSource(
    BuildContext context,
    WidgetRef ref,
    QuestionListViewModelProvider provider,
    StudySource source,
  ) async {
    var draftName = source.fileName;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('자료 이름 변경'),
        content: TextFormField(
          key: const Key('pdf-source-name-field'),
          initialValue: source.fileName,
          autofocus: true,
          maxLength: 200,
          decoration: InputDecoration(
            labelText: '자료 이름',
            hintText: source.isManual ? '복습 노트' : '강의자료.pdf',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => draftName = value,
          onFieldSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.of(context).pop(value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('save-pdf-source-button'),
            onPressed: () {
              final value = draftName.trim();
              if (value.isNotEmpty) Navigator.of(context).pop(value);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name == null || !context.mounted) return;

    try {
      await ref
          .read(provider.notifier)
          .renameSource(id: source.id, fileName: name);
      ref.invalidate(documentSourcesProvider(folderId));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('자료 이름을 변경했어요.')));
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '자료 이름을 변경하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _deleteSource(
    BuildContext context,
    WidgetRef ref,
    QuestionListViewModelProvider provider,
    StudySource source,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('자료 삭제'),
        content: Text(
          '${source.fileName}을(를) 삭제하시겠습니까?\n\n'
          '포함된 개념과 문제의 출처 연결은 제거되지만, 이미 생성된 문제는 유지됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('confirm-delete-pdf-source-button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(provider.notifier).deleteSource(source.id);
      ref.invalidate(documentSourcesProvider(folderId));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('자료를 삭제했어요.')));
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '자료를 삭제하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _PdfSourceCard extends StatelessWidget {
  const _PdfSourceCard({
    required this.source,
    required this.onOpen,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  final StudySource source;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        key: ValueKey('pdf-source-${source.id}'),
        leading: Icon(
          source.isManual ? Icons.notes_rounded : Icons.picture_as_pdf_outlined,
        ),
        title: Text(
          source.fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          source.isManual
              ? '사용자 생성 자료'
              : '${source.pageCount}페이지 · ${_extractionLabel(source.extractionMethod)}',
        ),
        onTap: onOpen,
        trailing: PopupMenuButton<_PdfSourceAction>(
          key: ValueKey('pdf-source-menu-${source.id}'),
          tooltip: '자료 메뉴',
          onSelected: (action) {
            switch (action) {
              case _PdfSourceAction.edit:
                onEdit();
              case _PdfSourceAction.move:
                onMove();
              case _PdfSourceAction.delete:
                onDelete();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: _PdfSourceAction.edit, child: Text('이름 변경')),
            PopupMenuItem(value: _PdfSourceAction.move, child: Text('이동')),
            PopupMenuItem(value: _PdfSourceAction.delete, child: Text('삭제')),
          ],
        ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onApprove,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });

  final Question question;
  final VoidCallback onApprove;
  final VoidCallback onEdit;
  final VoidCallback onMove;
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
        subtitle: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${switch (question.type) {
                QuestionType.multipleChoice => '객관식',
                QuestionType.trueFalse => 'O/X',
                QuestionType.shortAnswer => '단답형',
                QuestionType.essay => '서술형',
              }}${question.status.name == 'draft' ? ' · Draft' : ''}',
            ),
            Text('난이도 ${question.difficulty}/5'),
            if (question.sourceReferences.isNotEmpty)
              Text(_sourceLabel(question.sourceReferences.first)),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<_QuestionAction>(
          key: ValueKey('question-menu-${question.id}'),
          tooltip: '문제 메뉴',
          onSelected: (action) {
            switch (action) {
              case _QuestionAction.approve:
                onApprove();
              case _QuestionAction.edit:
                onEdit();
              case _QuestionAction.move:
                onMove();
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
            const PopupMenuItem(value: _QuestionAction.move, child: Text('이동')),
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

enum _QuestionAction { approve, edit, move, delete }

enum _PdfSourceAction { edit, move, delete }

String _sourceLabel(QuestionSourceReference reference) {
  final pages = reference.pageNumbers.isEmpty
      ? ''
      : ' · p.${reference.pageNumbers.join(', ')}';
  final concept = reference.conceptTitle == null
      ? ''
      : ' · ${reference.conceptTitle}';
  return '출처: ${reference.fileName}$pages$concept';
}

String _extractionLabel(String method) => switch (method) {
  'textLayer' => '텍스트 레이어',
  'visionOcr' || 'ocr' => 'OCR',
  'hybrid' => '텍스트 + OCR',
  _ => method,
};
