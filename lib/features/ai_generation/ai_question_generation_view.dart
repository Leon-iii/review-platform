import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/features/ai_generation/ai_question_generation_view_model.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';

class AiQuestionGenerationView extends ConsumerStatefulWidget {
  const AiQuestionGenerationView({this.initialFolderId, super.key});

  final String? initialFolderId;

  @override
  ConsumerState<AiQuestionGenerationView> createState() =>
      _AiQuestionGenerationViewState();
}

class _AiQuestionGenerationViewState
    extends ConsumerState<AiQuestionGenerationView> {
  final _formKey = GlobalKey<FormState>();
  final _sourceLabelController = TextEditingController();
  final _sourceTextController = TextEditingController();
  final _manualQuestionCountController = TextEditingController(text: '10');
  String? _selectedFolderId;
  AiQuestionGenerationMode _generationMode = AiQuestionGenerationMode.automatic;
  AiQuestionDensity _automaticDensity = AiQuestionDensity.medium;
  Set<QuestionType> _questionTypes = {
    QuestionType.multipleChoice,
    QuestionType.trueFalse,
    QuestionType.shortAnswer,
  };

  @override
  void initState() {
    super.initState();
    _selectedFolderId = widget.initialFolderId;
  }

  @override
  void dispose() {
    _sourceLabelController.dispose();
    _sourceTextController.dispose();
    _manualQuestionCountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folders = ref.watch(aiGenerationFoldersProvider);
    final provider = aiQuestionGenerationControllerProvider(
      widget.initialFolderId,
    );
    final generation = ref.watch(provider);

    return Scaffold(
      key: const Key('ai-generation-view'),
      appBar: AppBar(title: const Text('AI 문제 생성')),
      body: generation.when(
        loading: () => Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 40),
                  SizedBox(height: 16),
                  Text(
                    '학습 내용을 분석하고 문제를 생성하고 있어요.',
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 20),
                  Semantics(
                    label: 'AI 문제 생성 진행 중',
                    child: LinearProgressIndicator(
                      key: Key('ai-generation-progress-bar'),
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '문제 수와 모델 성능에 따라 시간이 걸릴 수 있어요.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
        error: (error, stackTrace) =>
            _buildForm(folders, errorMessage: _messageFor(error)),
        data: (review) => review == null
            ? _buildForm(folders)
            : _ReviewPanel(review: review, provider: provider),
      ),
    );
  }

  Widget _buildForm(AsyncValue<List<Folder>> folders, {String? errorMessage}) {
    return folders.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(child: Text(_messageFor(error))),
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('문제를 저장할 폴더를 먼저 만들어 주세요.'));
        }
        final availableIds = items.map((folder) => folder.id).toSet();
        final selectedId = availableIds.contains(_selectedFolderId)
            ? _selectedFolderId
            : items.first.id;
        return Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (errorMessage != null) ...[
                        Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(errorMessage),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      FolderPickerField(
                        key: const Key('ai-folder-field'),
                        folders: items,
                        selectedFolderId: selectedId,
                        labelText: '저장할 폴더',
                        onChanged: (value) =>
                            setState(() => _selectedFolderId = value),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('ai-source-label-field'),
                        controller: _sourceLabelController,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '자료 이름 (선택)',
                          hintText: '예: 전자기학 3주차 노트',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        key: const Key('ai-source-text-field'),
                        controller: _sourceTextController,
                        minLines: 10,
                        maxLines: 20,
                        maxLength: 50000,
                        decoration: const InputDecoration(
                          labelText: '학습 내용',
                          hintText: '문제를 만들 학습 내용을 붙여 넣으세요.',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value?.trim().length ?? 0) < 10
                            ? '학습 내용을 10자 이상 입력해 주세요.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '문제 유형',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<QuestionType>(
                        multiSelectionEnabled: true,
                        emptySelectionAllowed: false,
                        segments: const [
                          ButtonSegment(
                            value: QuestionType.multipleChoice,
                            icon: Icon(Icons.format_list_numbered_rounded),
                            label: Text('객관식'),
                          ),
                          ButtonSegment(
                            value: QuestionType.trueFalse,
                            icon: Icon(Icons.rule_rounded),
                            label: Text('O/X'),
                          ),
                          ButtonSegment(
                            value: QuestionType.shortAnswer,
                            icon: Icon(Icons.short_text_rounded),
                            label: Text('단답형'),
                          ),
                        ],
                        selected: _questionTypes,
                        onSelectionChanged: (value) =>
                            setState(() => _questionTypes = value),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '문제 수 설정',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      RadioGroup<AiQuestionGenerationMode>(
                        groupValue: _generationMode,
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _generationMode = value);
                          }
                        },
                        child: const Row(
                          children: [
                            Expanded(
                              child: RadioListTile<AiQuestionGenerationMode>(
                                key: Key('ai-count-mode-automatic'),
                                value: AiQuestionGenerationMode.automatic,
                                title: Text('자동'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            Expanded(
                              child: RadioListTile<AiQuestionGenerationMode>(
                                key: Key('ai-count-mode-manual'),
                                value: AiQuestionGenerationMode.manual,
                                title: Text('수동'),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_generationMode == AiQuestionGenerationMode.automatic)
                        DropdownButtonFormField<AiQuestionDensity>(
                          key: const Key('ai-automatic-density-field'),
                          initialValue: _automaticDensity,
                          decoration: const InputDecoration(
                            labelText: '자동 생성량',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: AiQuestionDensity.low,
                              child: Text('적음 · 개념별 1~2개'),
                            ),
                            DropdownMenuItem(
                              value: AiQuestionDensity.medium,
                              child: Text('보통 · 개념별 3~4개'),
                            ),
                            DropdownMenuItem(
                              value: AiQuestionDensity.high,
                              child: Text('많음 · 개념별 5~6개'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) _automaticDensity = value;
                          },
                        )
                      else
                        TextFormField(
                          key: const Key('ai-manual-question-count-field'),
                          controller: _manualQuestionCountController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '문제 수',
                            helperText: '1개에서 20개까지 입력할 수 있어요.',
                            suffixText: '개',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) {
                            final count = int.tryParse(value ?? '');
                            if (count == null || count < 1 || count > 20) {
                              return '문제 수를 1에서 20 사이로 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        key: const Key('generate-ai-questions-button'),
                        onPressed: () => _generate(selectedId!),
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('문제 생성'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _generate(String folderId) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final provider = aiQuestionGenerationControllerProvider(
      widget.initialFolderId,
    );
    try {
      await ref
          .read(provider.notifier)
          .generate(
            folderId: folderId,
            sourceText: _sourceTextController.text,
            sourceLabel: _sourceLabelController.text.trim().isEmpty
                ? null
                : _sourceLabelController.text.trim(),
            questionTypes: _questionTypes,
            generationMode: _generationMode,
            automaticDensity:
                _generationMode == AiQuestionGenerationMode.automatic
                ? _automaticDensity
                : null,
            questionCount: _generationMode == AiQuestionGenerationMode.manual
                ? int.parse(_manualQuestionCountController.text)
                : null,
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_messageFor(error))));
    }
  }

  String _messageFor(Object error) =>
      error is AppFailure ? error.message : 'AI 문제 생성을 완료하지 못했어요.';
}

class _ReviewPanel extends ConsumerWidget {
  const _ReviewPanel({required this.review, required this.provider});

  final AiQuestionReviewState review;
  final AiQuestionGenerationControllerProvider provider;

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
                          '생성된 문제 ${review.items.length}개',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${review.metadata.provider} · ${review.metadata.model} · '
                          '${review.metadata.promptVersion}',
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                key: const Key(
                                  'approve-all-ai-questions-button',
                                ),
                                onPressed: review.pendingCount == 0
                                    ? null
                                    : () => _run(
                                        context,
                                        () => ref
                                            .read(provider.notifier)
                                            .approveAll(),
                                        '남은 Draft 문제를 모두 승인했어요.',
                                      ),
                                icon: const Icon(Icons.done_all_rounded),
                                label: Text('남은 ${review.pendingCount}개 모두 승인'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton(
                              onPressed: () =>
                                  context.go(AppRoutes.folder(review.folderId)),
                              child: const Text('검수 종료'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (final item in review.items) ...[
                  _ReviewCard(item: item, provider: provider),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String success,
  ) async {
    try {
      await action();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '검수 작업을 완료하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _ReviewCard extends ConsumerWidget {
  const _ReviewCard({required this.item, required this.provider});

  final AiQuestionReviewItem item;
  final AiQuestionGenerationControllerProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = item.question;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(_typeLabel(question.type))),
                Chip(label: Text(_statusLabel(item.status))),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              question.prompt,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (question.type == QuestionType.multipleChoice ||
                question.type == QuestionType.trueFalse) ...[
              const SizedBox(height: 12),
              for (final choice in question.choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    choice.isCorrect ? '✓ ${choice.text}' : choice.text,
                  ),
                ),
            ] else ...[
              const SizedBox(height: 12),
              Text('허용 정답: ${question.acceptableAnswers.join(' / ')}'),
            ],
            if (question.explanation case final explanation?) ...[
              const SizedBox(height: 10),
              Text('해설: $explanation'),
            ],
            if (item.status == AiReviewStatus.pending) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () => _approve(context, ref),
                    child: const Text('승인'),
                  ),
                  OutlinedButton(
                    onPressed: () => _edit(context, ref),
                    child: const Text('수정 후 승인'),
                  ),
                  TextButton(
                    onPressed: () => _reject(context, ref),
                    child: const Text('거절'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    await _run(
      context,
      () => ref.read(provider.notifier).approve(item.questionId),
      '문제를 승인했어요.',
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final saved = await context.push<bool>(
      AppRoutes.editQuestion(item.questionId),
    );
    if (saved == true) {
      ref.read(provider.notifier).markEditedAndApproved(item.questionId);
    }
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('생성 문제 거절'),
        content: const Text('이 Draft 문제를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('거절'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await _run(
      context,
      () => ref.read(provider.notifier).reject(item.questionId),
      '생성 문제를 거절했어요.',
    );
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String success,
  ) async {
    try {
      await action();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '검수 작업을 완료하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  String _typeLabel(QuestionType type) => switch (type) {
    QuestionType.multipleChoice => '객관식',
    QuestionType.trueFalse => 'O/X',
    QuestionType.shortAnswer => '단답형',
    QuestionType.essay => '서술형',
  };

  String _statusLabel(AiReviewStatus status) => switch (status) {
    AiReviewStatus.pending => 'Draft',
    AiReviewStatus.approved => '승인됨',
    AiReviewStatus.rejected => '거절됨',
  };
}
