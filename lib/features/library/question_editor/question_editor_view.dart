import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/question_editor/question_editor_view_model.dart';

class QuestionEditorView extends ConsumerWidget {
  const QuestionEditorView({this.folderId, this.questionId, super.key});

  final String? folderId;
  final String? questionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = ref.watch(questionEditorViewModelProvider(questionId));

    return Scaffold(
      appBar: AppBar(title: Text(questionId == null ? '문제 추가' : '문제 수정')),
      body: question.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error is AppFailure ? error.message : '문제를 불러오지 못했어요.'),
          ),
        ),
        data: (loadedQuestion) {
          final targetFolderId = loadedQuestion?.folderId ?? folderId;
          if (targetFolderId == null) {
            return const Center(child: Text('문제를 저장할 폴더가 필요해요.'));
          }

          return _QuestionEditorForm(
            key: ValueKey(questionId ?? targetFolderId),
            folderId: targetFolderId,
            questionId: questionId,
            initialQuestion: loadedQuestion,
          );
        },
      ),
    );
  }
}

class _QuestionEditorForm extends ConsumerStatefulWidget {
  const _QuestionEditorForm({
    required this.folderId,
    required this.questionId,
    required this.initialQuestion,
    super.key,
  });

  final String folderId;
  final String? questionId;
  final Question? initialQuestion;

  @override
  ConsumerState<_QuestionEditorForm> createState() =>
      _QuestionEditorFormState();
}

class _QuestionEditorFormState extends ConsumerState<_QuestionEditorForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _promptController;
  late final TextEditingController _explanationController;
  late final List<TextEditingController> _choiceControllers;
  late final List<TextEditingController> _answerControllers;
  late QuestionType _type;
  late int _correctChoiceIndex;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final question = widget.initialQuestion;
    _type = question?.type ?? QuestionType.multipleChoice;
    _promptController = TextEditingController(text: question?.prompt ?? '');
    _explanationController = TextEditingController(
      text: question?.explanation ?? '',
    );

    final choices = question?.choices ?? const <QuestionChoice>[];
    _choiceControllers = choices.isEmpty
        ? List.generate(4, (_) => TextEditingController())
        : [
            for (final choice in choices)
              TextEditingController(text: choice.text),
          ];
    final correctIndex = choices.indexWhere((choice) => choice.isCorrect);
    _correctChoiceIndex = correctIndex < 0 ? 0 : correctIndex;

    final answers = question?.acceptableAnswers ?? const <AcceptableAnswer>[];
    _answerControllers = answers.isEmpty
        ? [TextEditingController()]
        : [
            for (final answer in answers)
              TextEditingController(text: answer.text),
          ];
  }

  @override
  void dispose() {
    _promptController.dispose();
    _explanationController.dispose();
    for (final controller in _choiceControllers) {
      controller.dispose();
    }
    for (final controller in _answerControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                  Text('문제 유형', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<QuestionType>(
                    segments: const [
                      ButtonSegment(
                        value: QuestionType.multipleChoice,
                        icon: Icon(Icons.format_list_numbered_rounded),
                        label: Text('객관식'),
                      ),
                      ButtonSegment(
                        value: QuestionType.shortAnswer,
                        icon: Icon(Icons.short_text_rounded),
                        label: Text('단답형'),
                      ),
                    ],
                    selected: {_type},
                    onSelectionChanged: (selection) {
                      setState(() => _type = selection.single);
                    },
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    key: const Key('question-prompt-field'),
                    controller: _promptController,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '문제',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '문제 내용을 입력해 주세요.'
                        : null,
                  ),
                  const SizedBox(height: 24),
                  if (_type == QuestionType.multipleChoice)
                    _buildMultipleChoiceFields()
                  else
                    _buildShortAnswerFields(),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _explanationController,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '해설 (선택)',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    key: const Key('save-question-button'),
                    onPressed: _isSaving ? null : _save,
                    icon: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_isSaving ? '저장 중...' : '저장'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMultipleChoiceFields() {
    return RadioGroup<int>(
      groupValue: _correctChoiceIndex,
      onChanged: (value) {
        if (value != null) setState(() => _correctChoiceIndex = value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('선택지', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('정답 하나를 선택해 주세요.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (var index = 0; index < _choiceControllers.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Radio<int>(value: index),
                  Expanded(
                    child: TextFormField(
                      key: Key('choice-field-$index'),
                      controller: _choiceControllers[index],
                      decoration: InputDecoration(
                        labelText: '선택지 ${index + 1}',
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? '선택지를 입력해 주세요.'
                          : null,
                    ),
                  ),
                  IconButton(
                    tooltip: '선택지 삭제',
                    onPressed: _choiceControllers.length <= 2
                        ? null
                        : () => _removeChoice(index),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(
                () => _choiceControllers.add(TextEditingController()),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('선택지 추가'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortAnswerFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('허용 정답', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (var index = 0; index < _answerControllers.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: Key('answer-field-$index'),
                    controller: _answerControllers[index],
                    decoration: InputDecoration(
                      labelText: '허용 정답 ${index + 1}',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '허용 정답을 입력해 주세요.'
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: '허용 정답 삭제',
                  onPressed: _answerControllers.length <= 1
                      ? null
                      : () => _removeAnswer(index),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _answerControllers.add(TextEditingController())),
            icon: const Icon(Icons.add_rounded),
            label: const Text('허용 정답 추가'),
          ),
        ),
      ],
    );
  }

  void _removeChoice(int index) {
    setState(() {
      final controller = _choiceControllers.removeAt(index);
      controller.dispose();
      if (_correctChoiceIndex == index) {
        _correctChoiceIndex = 0;
      } else if (_correctChoiceIndex > index) {
        _correctChoiceIndex--;
      }
    });
  }

  void _removeAnswer(int index) {
    setState(() {
      final controller = _answerControllers.removeAt(index);
      controller.dispose();
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);

    final draft = QuestionDraft(
      folderId: widget.folderId,
      type: _type,
      prompt: _promptController.text,
      explanation: _explanationController.text,
      choices: _type == QuestionType.multipleChoice
          ? [
              for (var index = 0; index < _choiceControllers.length; index++)
                QuestionChoiceDraft(
                  text: _choiceControllers[index].text,
                  isCorrect: index == _correctChoiceIndex,
                ),
            ]
          : const [],
      acceptableAnswers: _type == QuestionType.shortAnswer
          ? [for (final controller in _answerControllers) controller.text]
          : const [],
    );

    try {
      await ref
          .read(questionEditorViewModelProvider(widget.questionId).notifier)
          .save(draft);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      final message = error is AppFailure ? error.message : '문제를 저장하지 못했어요.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
