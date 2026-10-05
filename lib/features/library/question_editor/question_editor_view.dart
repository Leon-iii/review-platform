import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/unsaved_changes_guard.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/question_editor/question_editor_view_model.dart';
import 'package:review_platform/features/library/question_editor/question_concept_picker.dart';

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
            child: AppErrorNotice(error: error, fallback: '문제를 불러오지 못했어요.'),
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
  final _exitGuardKey = GlobalKey<UnsavedChangesGuardState>();
  late final String _initialEditState;
  late final TextEditingController _promptController;
  late final TextEditingController _explanationController;
  late final List<TextEditingController> _choiceControllers;
  late final List<TextEditingController> _answerControllers;
  late QuestionType _type;
  late int _correctChoiceIndex;
  late int _difficulty;
  late ConceptImportance _importance;
  late bool _caseSensitive;
  late bool _whitespaceSensitive;
  bool _isSaving = false;
  bool _isPickingConcept = false;
  bool _primaryConceptChanged = false;
  String? _primaryConceptId;
  String? _primaryConceptLabel;

  @override
  void initState() {
    super.initState();
    final question = widget.initialQuestion;
    _type = question?.type ?? QuestionType.multipleChoice;
    _difficulty = question?.difficulty ?? 3;
    _importance = question?.importance ?? ConceptImportance.medium;
    _caseSensitive = question?.caseSensitive ?? false;
    _whitespaceSensitive = question?.whitespaceSensitive ?? false;
    _primaryConceptId = question?.primaryConceptId;
    final reference = question?.sourceReferences
        .where(
          (item) =>
              item.conceptId == _primaryConceptId && item.conceptId != null,
        )
        .firstOrNull;
    if (reference != null) {
      _primaryConceptLabel =
          '${reference.fileName} · ${reference.conceptTitle}';
    }
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
    _initialEditState = _editState;
  }

  String get _editState => jsonEncode([
    _type.name,
    _promptController.text,
    _explanationController.text,
    [for (final controller in _choiceControllers) controller.text],
    [for (final controller in _answerControllers) controller.text],
    _correctChoiceIndex,
    _difficulty,
    _importance.name,
    _caseSensitive,
    _whitespaceSensitive,
    _primaryConceptId,
  ]);

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
    return UnsavedChangesGuard(
      key: _exitGuardKey,
      hasChanges: _editState != _initialEditState,
      busy: _isSaving || _isPickingConcept,
      onSave: _save,
      savedResult: true,
      child: AbsorbPointer(
        absorbing: _isSaving,
        child: Form(
          key: _formKey,
          onChanged: () => setState(() {}),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '문제 유형',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<QuestionType>(
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
                          ButtonSegment(
                            value: QuestionType.essay,
                            icon: Icon(Icons.notes_rounded),
                            label: Text('서술형'),
                          ),
                        ],
                        selected: {_type},
                        onSelectionChanged: (selection) {
                          setState(() {
                            _type = selection.single;
                            if (_type == QuestionType.trueFalse &&
                                _correctChoiceIndex > 1) {
                              _correctChoiceIndex = 0;
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        key: const Key('question-prompt-field'),
                        controller: _promptController,
                        enabled: !_isSaving,
                        minLines: 3,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: '문제',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? '문제 내용을 입력해 주세요.'
                            : null,
                      ),
                      const SizedBox(height: 24),
                      switch (_type) {
                        QuestionType.multipleChoice =>
                          _buildMultipleChoiceFields(),
                        QuestionType.trueFalse => _buildTrueFalseFields(),
                        QuestionType.shortAnswer => _buildShortAnswerFields(),
                        QuestionType.essay => _buildShortAnswerFields(),
                      },
                      const SizedBox(height: 24),
                      DropdownButtonFormField<int>(
                        key: const Key('question-difficulty-field'),
                        initialValue: _difficulty,
                        decoration: const InputDecoration(
                          labelText: '난이도',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('1 · 매우 쉬움')),
                          DropdownMenuItem(value: 2, child: Text('2 · 쉬움')),
                          DropdownMenuItem(value: 3, child: Text('3 · 보통')),
                          DropdownMenuItem(value: 4, child: Text('4 · 어려움')),
                          DropdownMenuItem(value: 5, child: Text('5 · 매우 어려움')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _difficulty = value);
                          }
                        },
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _explanationController,
                        enabled: !_isSaving,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: '해설 (선택)',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '주개념 (선택)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              key: const Key('select-primary-concept-button'),
                              onPressed: _isSaving || _isPickingConcept
                                  ? null
                                  : _pickPrimaryConcept,
                              icon: const Icon(Icons.menu_book_rounded),
                              label: Text(
                                _primaryConceptLabel ?? '자료에서 개념 선택',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          if (_primaryConceptId != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              key: const Key('clear-primary-concept-button'),
                              tooltip: '주개념 연결 해제',
                              onPressed: _isSaving || _isPickingConcept
                                  ? null
                                  : () => setState(() {
                                      _primaryConceptId = null;
                                      _primaryConceptLabel = null;
                                      _primaryConceptChanged = true;
                                    }),
                              icon: const Icon(Icons.link_off_rounded),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '중요도 · ${_importance.label}',
                        key: const Key('question-importance-label'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Slider(
                        key: const Key('question-importance-slider'),
                        min: 1,
                        max: 5,
                        divisions: 4,
                        value: _importance.weight.toDouble(),
                        label: _importance.label,
                        onChanged: _primaryConceptId != null || _isSaving
                            ? null
                            : (value) => setState(
                                () => _importance =
                                    ConceptImportance.values[value.round() - 1],
                              ),
                      ),
                      Text(
                        _primaryConceptId != null
                            ? '출처 개념의 중요도를 따릅니다. 개념에서 수정하면 연결된 문제에도 반영됩니다.'
                            : '복습 출제 비중에 사용됩니다. 난이도와는 별개입니다.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        key: const Key('save-question-button'),
                        onPressed: _isSaving ? null : _saveAndClose,
                        icon: _isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
        ),
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
                      enabled: !_isSaving,
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
    final essay = _type == QuestionType.essay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          essay ? '모범 답안' : '허용 정답',
          style: Theme.of(context).textTheme.titleMedium,
        ),
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
                    enabled: !_isSaving,
                    minLines: essay ? 3 : 1,
                    maxLines: essay ? 8 : 1,
                    decoration: InputDecoration(
                      labelText: '${essay ? '모범 답안' : '허용 정답'} ${index + 1}',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? (essay ? '모범 답안을 입력해 주세요.' : '허용 정답을 입력해 주세요.')
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: essay ? '모범 답안 삭제' : '허용 정답 삭제',
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
            label: Text(essay ? '모범 답안 추가' : '허용 정답 추가'),
          ),
        ),
        if (!essay) ...[
          const SizedBox(height: 8),
          Text('채점 설정', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            key: const Key('short-answer-case-sensitive-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('영문 대소문자 구분'),
            subtitle: const Text('켜면 대문자와 소문자가 일치해야 해요.'),
            value: _caseSensitive,
            onChanged: _isSaving
                ? null
                : (value) => setState(() => _caseSensitive = value),
          ),
          SwitchListTile(
            key: const Key('short-answer-whitespace-sensitive-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('띄어쓰기 구분'),
            subtitle: const Text('켜면 내부 공백도 일치해야 해요. 앞뒤 공백은 항상 무시해요.'),
            value: _whitespaceSensitive,
            onChanged: _isSaving
                ? null
                : (value) => setState(() => _whitespaceSensitive = value),
          ),
        ],
      ],
    );
  }

  Widget _buildTrueFalseFields() {
    return RadioGroup<int>(
      groupValue: _correctChoiceIndex,
      onChanged: (value) {
        if (value != null) setState(() => _correctChoiceIndex = value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('정답', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'O 또는 X를 선택해 주세요.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          const RadioListTile<int>(
            key: Key('true-false-answer-o'),
            value: 0,
            title: Text('O'),
            contentPadding: EdgeInsets.zero,
          ),
          const RadioListTile<int>(
            key: Key('true-false-answer-x'),
            value: 1,
            title: Text('X'),
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
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

  Future<void> _saveAndClose() async {
    if (await _save() && mounted) {
      await _exitGuardKey.currentState?.close(true);
    }
  }

  Future<bool> _save() async {
    if (_isSaving || !(_formKey.currentState?.validate() ?? false)) {
      return false;
    }
    setState(() => _isSaving = true);

    final draft = QuestionDraft(
      folderId: widget.folderId,
      type: _type,
      prompt: _promptController.text,
      explanation: _explanationController.text,
      difficulty: _difficulty,
      importance: _importance,
      caseSensitive: _caseSensitive,
      whitespaceSensitive: _whitespaceSensitive,
      choices: switch (_type) {
        QuestionType.multipleChoice => [
          for (var index = 0; index < _choiceControllers.length; index++)
            QuestionChoiceDraft(
              text: _choiceControllers[index].text,
              isCorrect: index == _correctChoiceIndex,
            ),
        ],
        QuestionType.trueFalse => [
          QuestionChoiceDraft(text: 'O', isCorrect: _correctChoiceIndex == 0),
          QuestionChoiceDraft(text: 'X', isCorrect: _correctChoiceIndex == 1),
        ],
        QuestionType.shortAnswer || QuestionType.essay => const [],
      },
      acceptableAnswers:
          _type == QuestionType.shortAnswer || _type == QuestionType.essay
          ? [for (final controller in _answerControllers) controller.text]
          : const [],
    );

    try {
      await ref
          .read(questionEditorViewModelProvider(widget.questionId).notifier)
          .save(
            draft,
            primaryConceptId: _primaryConceptId,
            replacePrimaryConcept: _primaryConceptChanged,
            detachedImportance:
                _primaryConceptChanged && _primaryConceptId == null
                ? _importance
                : null,
          );
      return true;
    } catch (error) {
      if (!mounted) return false;
      final message = error is AppFailure ? error.message : '문제를 저장하지 못했어요.';
      showAppError(context, message);
      return false;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _pickPrimaryConcept() async {
    if (_isSaving || _isPickingConcept) return;
    setState(() => _isPickingConcept = true);
    try {
      final option = await showDialog<QuestionConceptOption>(
        context: context,
        builder: (context) => QuestionConceptPicker(
          selectedConceptId: _primaryConceptId,
          loadOptions: ref
              .read(questionEditorViewModelProvider(widget.questionId).notifier)
              .loadConceptOptions,
        ),
      );
      if (option == null || !mounted) return;
      setState(() {
        _primaryConceptId = option.concept.id;
        _primaryConceptLabel = option.label;
        _importance = option.concept.importance;
        _primaryConceptChanged = true;
      });
    } finally {
      if (mounted) setState(() => _isPickingConcept = false);
    }
  }
}
