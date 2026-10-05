import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/features/study/setup/study_setup_view_model.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';

class StudySetupView extends ConsumerStatefulWidget {
  const StudySetupView({
    this.initialFolderId,
    this.onlyWrong = false,
    super.key,
  });

  final String? initialFolderId;
  final bool onlyWrong;

  @override
  ConsumerState<StudySetupView> createState() => _StudySetupViewState();
}

class _StudySetupViewState extends ConsumerState<StudySetupView> {
  static const _difficultyLabels = {
    1: '매우 쉬움',
    2: '쉬움',
    3: '보통',
    4: '어려움',
    5: '매우 어려움',
  };
  late String? _folderId;
  final Set<QuestionType> _types = {
    QuestionType.multipleChoice,
    QuestionType.trueFalse,
    QuestionType.shortAnswer,
    QuestionType.essay,
  };
  int _questionCount = 10;
  bool _shuffle = true;
  bool _prioritizeImportantConcepts = true;
  RangeValues _difficultyRange = const RangeValues(1, 5);
  AnswerFeedbackTiming _feedbackTiming = AnswerFeedbackTiming.immediate;
  late bool _onlyWrong;

  @override
  void initState() {
    super.initState();
    _folderId = widget.initialFolderId;
    _onlyWrong = widget.onlyWrong;
  }

  @override
  Widget build(BuildContext context) {
    final folders = ref.watch(studyFolderOptionsProvider);
    final startState = ref.watch(studySetupViewModelProvider);

    return Scaffold(
      key: const Key('study-setup-view'),
      appBar: AppBar(title: const Text('문제 풀기 설정')),
      body: folders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorMessage(error: error),
        data: (options) {
          if (options.isEmpty) return const _EmptyFolders();
          final selectedFolderId =
              options.any((option) => option.folder.id == _folderId)
              ? _folderId!
              : options.first.folder.id;

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '학습 범위',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 16),
                          FolderPickerField(
                            key: const Key('study-folder-field'),
                            folders: [
                              for (final option in options) option.folder,
                            ],
                            selectedFolderId: selectedFolderId,
                            labelText: '폴더',
                            helperText: '선택한 폴더의 하위 폴더도 포함합니다.',
                            onChanged: (value) =>
                                setState(() => _folderId = value),
                          ),
                          const SizedBox(height: 28),
                          Text(
                            '문제 유형',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                key: const Key('true-false-filter'),
                                label: const Text('O/X'),
                                avatar: const Icon(Icons.rule_rounded),
                                selected: _types.contains(
                                  QuestionType.trueFalse,
                                ),
                                onSelected: (selected) => _toggleType(
                                  QuestionType.trueFalse,
                                  selected,
                                ),
                              ),
                              FilterChip(
                                key: const Key('multiple-choice-filter'),
                                label: const Text('객관식'),
                                avatar: const Icon(Icons.list_alt_rounded),
                                selected: _types.contains(
                                  QuestionType.multipleChoice,
                                ),
                                onSelected: (selected) => _toggleType(
                                  QuestionType.multipleChoice,
                                  selected,
                                ),
                              ),
                              FilterChip(
                                key: const Key('short-answer-filter'),
                                label: const Text('단답형'),
                                avatar: const Icon(Icons.short_text_rounded),
                                selected: _types.contains(
                                  QuestionType.shortAnswer,
                                ),
                                onSelected: (selected) => _toggleType(
                                  QuestionType.shortAnswer,
                                  selected,
                                ),
                              ),
                              FilterChip(
                                key: const Key('essay-filter'),
                                label: const Text('서술형'),
                                avatar: const Icon(Icons.notes_rounded),
                                selected: _types.contains(QuestionType.essay),
                                onSelected: (selected) =>
                                    _toggleType(QuestionType.essay, selected),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          Text(
                            '난이도',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          RangeSlider(
                            key: const Key('difficulty-range-slider'),
                            min: 1,
                            max: 5,
                            divisions: 4,
                            values: _difficultyRange,
                            labels: RangeLabels(
                              _difficultyLabel(_difficultyRange.start),
                              _difficultyLabel(_difficultyRange.end),
                            ),
                            semanticFormatterCallback: _difficultyLabel,
                            onChanged: (values) => setState(() {
                              _difficultyRange = RangeValues(
                                values.start.roundToDouble(),
                                values.end.roundToDouble(),
                              );
                            }),
                          ),
                          const Row(
                            children: [
                              Expanded(child: Text('1 · 매우 쉬움')),
                              Expanded(
                                child: Text(
                                  '5 · 매우 어려움',
                                  textAlign: TextAlign.end,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          DropdownButtonFormField<int>(
                            key: const Key('question-count-field'),
                            initialValue: _questionCount,
                            decoration: const InputDecoration(
                              labelText: '문제 수',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(value: 5, child: Text('5문제')),
                              DropdownMenuItem(value: 10, child: Text('10문제')),
                              DropdownMenuItem(value: 20, child: Text('20문제')),
                              DropdownMenuItem(value: 50, child: Text('50문제')),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _questionCount = value);
                              }
                            },
                          ),
                          const SizedBox(height: 24),
                          SwitchListTile(
                            key: const Key('answer-feedback-switch'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('정답 바로 확인'),
                            subtitle: Text(
                              _feedbackTiming == AnswerFeedbackTiming.immediate
                                  ? '각 답안을 제출하면 바로 정답·오답을 알려줍니다.'
                                  : '풀이 중에는 정답·오답을 숨기고, 학습 종료 후 결과 화면에서 확인합니다.',
                            ),
                            value:
                                _feedbackTiming ==
                                AnswerFeedbackTiming.immediate,
                            onChanged: (value) => setState(() {
                              _feedbackTiming = value
                                  ? AnswerFeedbackTiming.immediate
                                  : AnswerFeedbackTiming.afterCompletion;
                            }),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('문제 순서 섞기'),
                            subtitle: const Text('매번 다른 순서로 출제합니다.'),
                            value: _shuffle,
                            onChanged: (value) =>
                                setState(() => _shuffle = value),
                          ),
                          SwitchListTile(
                            key: const Key('important-concepts-switch'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('중요 개념 우선'),
                            subtitle: const Text(
                              '개념별 중요도로 가중 출제하고, 최근 오답·모름을 조금 더 자주 복습합니다.',
                            ),
                            value: _prioritizeImportantConcepts,
                            onChanged: (value) => setState(
                              () => _prioritizeImportantConcepts = value,
                            ),
                          ),
                          SwitchListTile(
                            key: const Key('only-wrong-filter'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('최근 오답만'),
                            subtitle: const Text('가장 최근 풀이가 오답인 문제만 출제합니다.'),
                            value: _onlyWrong,
                            onChanged: (value) =>
                                setState(() => _onlyWrong = value),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            key: const Key('start-quiz-button'),
                            onPressed: startState.isLoading
                                ? null
                                : () => _start(selectedFolderId),
                            icon: startState.isLoading
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow_rounded),
                            label: Text(
                              startState.isLoading ? '준비 중...' : '학습 시작',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _toggleType(QuestionType type, bool selected) {
    setState(() {
      if (selected) {
        _types.add(type);
      } else {
        _types.remove(type);
      }
    });
  }

  String _difficultyLabel(double value) {
    final level = value.round();
    return '$level · ${_difficultyLabels[level]}';
  }

  Future<void> _start(String folderId) async {
    try {
      final result = await ref
          .read(studySetupViewModelProvider.notifier)
          .start(
            QuizFilter(
              rootFolderId: folderId,
              enabledQuestionTypes: Set.unmodifiable(_types),
              questionCount: _questionCount,
              onlyWrongQuestions: _onlyWrong,
              shuffle: _shuffle,
              prioritizeImportantConcepts: _prioritizeImportantConcepts,
              enabledDifficulties: Set.unmodifiable({
                for (
                  var level = _difficultyRange.start.round();
                  level <= _difficultyRange.end.round();
                  level++
                )
                  level,
              }),
              feedbackTiming: _feedbackTiming,
            ),
          );
      if (mounted) context.go(AppRoutes.studySession(result.sessionId));
    } catch (error) {
      if (!mounted) return;
      final message = error is AppFailure ? error.message : '학습을 시작하지 못했어요.';
      showAppError(context, message);
    }
  }
}

class _EmptyFolders extends StatelessWidget {
  const _EmptyFolders();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.create_new_folder_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              '먼저 문제를 담을 폴더를 만들어 주세요.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go(AppRoutes.library),
              child: const Text('문제 관리로 이동'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppErrorNotice(error: error, fallback: '폴더를 불러오지 못했어요.'),
    );
  }
}
