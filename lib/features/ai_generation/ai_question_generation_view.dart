import 'package:review_platform/shared/widgets/question_type_options.dart';
import 'package:review_platform/shared/widgets/app_dialog.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/app_action_group.dart';
import 'package:review_platform/shared/widgets/app_option_selector.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/ai_generation/ai_question_generation_view_model.dart';
import 'package:review_platform/features/ai_generation/ai_source_picker.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:review_platform/shared/widgets/concept_source_badge.dart';
import 'package:review_platform/shared/widgets/review_status_badge.dart';
import 'package:review_platform/shared/widgets/concept_importance_badge.dart';

class AiQuestionGenerationView extends ConsumerStatefulWidget {
  const AiQuestionGenerationView({
    this.initialFolderId,
    this.initialConceptId,
    this.initialSourceId,
    super.key,
  });

  final String? initialFolderId;
  final String? initialConceptId;
  final String? initialSourceId;

  @override
  ConsumerState<AiQuestionGenerationView> createState() =>
      _AiQuestionGenerationViewState();
}

class _AiQuestionGenerationViewState
    extends ConsumerState<AiQuestionGenerationView> {
  static const _difficultyLabels = {
    1: '매우 쉬움',
    2: '쉬움',
    3: '보통',
    4: '어려움',
    5: '매우 어려움',
  };
  final _formKey = GlobalKey<FormState>();
  final _sourceTextController = TextEditingController();
  final _manualQuestionCountController = TextEditingController(text: '10');
  final _conceptScrollController = ScrollController(keepScrollOffset: false);
  String? _selectedFolderId;
  AiQuestionGenerationMode _generationMode = AiQuestionGenerationMode.automatic;
  AiQuestionDensity _automaticDensity = AiQuestionDensity.medium;
  RangeValues _difficultyRange = const RangeValues(1, 5);
  Set<QuestionType> _questionTypes = {
    QuestionType.multipleChoice,
    QuestionType.trueFalse,
    QuestionType.shortAnswer,
  };
  ConceptGenerationSeed? _conceptSeed;
  SourceGenerationSeed? _sourceSeed;
  StudySource? _selectedSource;
  Object? _conceptSeedError;
  bool _loadingConceptSeed = false;
  bool _reflectConceptImportance = true;
  AiGenerationProgress? _progress;
  String? _lastProgressConceptTitle;
  final _selectedConceptIds = <String>{};
  bool get _sourceLocked =>
      widget.initialConceptId != null || widget.initialSourceId != null;
  bool get _usesConcepts => _sourceLocked || _selectedSource != null;
  String? get _sourceLabel =>
      _conceptSeed?.sourceLabel ?? _sourceSeed?.sourceLabel;
  List<StudyConcept> get _availableConcepts => _conceptSeed != null
      ? [_conceptSeed!.concept]
      : _sourceSeed?.concepts ?? const [];
  List<StudyConcept> get _generationConcepts => _availableConcepts
      .where((concept) => _selectedConceptIds.contains(concept.id))
      .toList();

  @override
  void initState() {
    super.initState();
    _selectedFolderId = widget.initialFolderId;
    if (widget.initialConceptId != null || widget.initialSourceId != null) {
      _loadingConceptSeed = true;
      Future<void>.microtask(_loadConceptSeed);
    }
  }

  @override
  void dispose() {
    _sourceTextController.dispose();
    _manualQuestionCountController.dispose();
    _conceptScrollController.dispose();
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
      appBar: AppPageBar(title: const Text('AI 문제 생성')),
      body: _loadingConceptSeed
          ? const Center(child: CircularProgressIndicator())
          : generation.when(
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
                            value:
                                _progress == null ||
                                    _progress!.totalConcepts == 0
                                ? null
                                : _progress!.completedConcepts /
                                      _progress!.totalConcepts,
                          ),
                        ),
                        SizedBox(height: 12),
                        if (_progress == null)
                          Text(
                            '문제 수와 모델 성능에 따라 시간이 걸릴 수 있어요.',
                            textAlign: TextAlign.center,
                          )
                        else ...[
                          Tooltip(
                            message: _lastProgressConceptTitle ?? '',
                            child: Text(
                              '개념 ${_progress!.currentConceptNumber}/${_progress!.totalConcepts}'
                              '${_lastProgressConceptTitle == null ? '' : ' - "$_lastProgressConceptTitle"'}',
                              key: const Key('ai-generation-concept-progress'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '성공 ${_progress!.successfulConcepts}건 · 실패 ${_progress!.failedConcepts}건',
                            key: const Key('ai-generation-concept-counts'),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '총 ${_progress!.generatedQuestions}문항 생성',
                            key: const Key('ai-generation-question-count'),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              error: (error, stackTrace) =>
                  _buildForm(folders, errorMessage: _messageFor(error)),
              data: (review) => review == null
                  ? _buildForm(
                      folders,
                      errorMessage: _conceptSeedError == null
                          ? null
                          : _messageFor(_conceptSeedError!),
                    )
                  : _ReviewPanel(review: review, provider: provider),
            ),
    );
  }

  Widget _buildForm(AsyncValue<List<Folder>> folders, {String? errorMessage}) {
    return folders.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) =>
          Center(child: AppErrorNotice(error: _messageFor(error))),
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
            padding: AppLayout.pagePadding(context),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppLayout.readingWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (errorMessage != null) ...[
                        AppErrorNotice(error: errorMessage),
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
                      AiSourcePickerField(
                        key: const Key('ai-source-label-field'),
                        source: _selectedSource,
                        locked: _sourceLocked,
                        onTap: () => _pickSource(items),
                        onClear: _sourceLocked ? null : _clearSource,
                      ),
                      const SizedBox(height: 8),
                      if (_usesConcepts) ...[
                        _ConceptSelectionHeader(
                          key: const Key('ai-concept-list-header'),
                          children: [
                            Expanded(
                              child: Text(
                                '학습 개념 · 선택 ${_generationConcepts.length}/${_availableConcepts.length}개',
                                key: const Key('ai-concept-selection-label'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              key: const Key('ai-select-all-concepts'),
                              onPressed: () => setState(
                                () => _selectedConceptIds
                                  ..clear()
                                  ..addAll(_availableConcepts.map((c) => c.id)),
                              ),
                              child: const Text('전체 선택'),
                            ),
                            TextButton(
                              key: const Key('ai-deselect-all-concepts'),
                              onPressed: () =>
                                  setState(_selectedConceptIds.clear),
                              child: const Text('선택 해제'),
                            ),
                          ],
                        ),
                        _buildConceptList(),
                        const SizedBox(height: 8),
                        const Text(
                          '선택한 개념을 하나씩 요청합니다. 문항 수는 서버가 배분하고 난이도는 생성 후 평가합니다.',
                        ),
                      ] else
                        TextFormField(
                          key: const Key('ai-source-text-field'),
                          controller: _sourceTextController,
                          readOnly: _conceptSeed != null || _sourceSeed != null,
                          minLines: 10,
                          maxLines: 20,
                          maxLength: 50000,
                          decoration: const InputDecoration(
                            labelText: '학습 내용',
                            hintText: '문제를 만들 학습 내용을 붙여 넣으세요.',
                            alignLabelWithHint: true,
                          ),
                          validator: (value) {
                            final length = value?.trim().length ?? 0;
                            if (length < 10) return '학습 내용을 10자 이상 입력해 주세요.';
                            if (length > 50000) {
                              return '학습 내용은 50,000자 이하로 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                      const SizedBox(height: 16),
                      Text(
                        '문제 유형',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      AppOptionSelector<QuestionType>(
                        multiSelectionEnabled: true,
                        emptySelectionAllowed: false,
                        segments: questionTypeOptions,
                        selected: _questionTypes,
                        onSelectionChanged: (value) =>
                            setState(() => _questionTypes = value),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '목표 난이도',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            '${_difficultyRange.start.round()} ~ ${_difficultyRange.end.round()}',
                            key: const Key('ai-difficulty-range-label'),
                          ),
                        ],
                      ),
                      RangeSlider(
                        key: const Key('ai-difficulty-range-slider'),
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
                            child: Text('5 · 매우 어려움', textAlign: TextAlign.end),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '생성 목표 범위이며, 최종 난이도는 생성된 문제를 다시 평가합니다.',
                        style: Theme.of(context).textTheme.bodySmall,
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
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '자동 생성량',
                          ),
                          items: [
                            DropdownMenuItem(
                              value: AiQuestionDensity.low,
                              child: Text(
                                _generationConcepts.isNotEmpty &&
                                        _reflectConceptImportance
                                    ? '적음 · 중요도별 배분'
                                    : '적음 · 개념별 1~2개',
                              ),
                            ),
                            DropdownMenuItem(
                              value: AiQuestionDensity.medium,
                              child: Text(
                                _generationConcepts.isNotEmpty &&
                                        _reflectConceptImportance
                                    ? '보통 · 중요도별 배분'
                                    : '보통 · 개념별 3~4개',
                              ),
                            ),
                            DropdownMenuItem(
                              value: AiQuestionDensity.high,
                              child: Text(
                                _generationConcepts.isNotEmpty &&
                                        _reflectConceptImportance
                                    ? '많음 · 중요도별 배분'
                                    : '많음 · 개념별 5~6개',
                              ),
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
                          ),
                          validator: (value) {
                            final count = int.tryParse(value ?? '');
                            if (count == null || count < 1 || count > 20) {
                              return '문제 수를 1에서 20 사이로 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                      if (_generationConcepts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SwitchListTile(
                          key: const Key('ai-concept-importance-switch'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('개념 중요도 반영'),
                          subtitle: const Text(
                            '중요한 개념에 더 많은 문제를 배정합니다. 난이도에는 영향을 주지 않으며, 생성 상한은 개념별 요청에 적용합니다.',
                          ),
                          value: _reflectConceptImportance,
                          onChanged: (value) =>
                              setState(() => _reflectConceptImportance = value),
                        ),
                      ],
                      const SizedBox(height: 28),
                      FilledButton.icon(
                        key: const Key('generate-ai-questions-button'),
                        onPressed:
                            _conceptSeedError != null ||
                                (_usesConcepts && _generationConcepts.isEmpty)
                            ? null
                            : () => _generate(selectedId!),
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

  Widget _buildConceptList() {
    final concepts = _availableConcepts;
    final theme = Theme.of(context);
    return Container(
      key: const Key('ai-concept-list-box'),
      height: (MediaQuery.sizeOf(context).height * 0.45).clamp(220.0, 420.0),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ScrollConfiguration(
        // Use one explicit scrollbar/controller, independent of the form's
        // primary scroll controller and automatic desktop scrollbars.
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _conceptScrollController,
          thumbVisibility: true,
          child: ListView.builder(
            key: const Key('ai-concept-list'),
            controller: _conceptScrollController,
            primary: false,
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
            itemCount: concepts.length,
            itemBuilder: (context, index) {
              final concept = concepts[index];
              return Card(
                key: ValueKey('ai-concept-${concept.id}'),
                child: ListTile(
                  leading: Checkbox(
                    value: _selectedConceptIds.contains(concept.id),
                    onChanged: (selected) => setState(() {
                      if (selected == true) {
                        _selectedConceptIds.add(concept.id);
                      } else {
                        _selectedConceptIds.remove(concept.id);
                      }
                    }),
                  ),
                  title: LayoutBuilder(
                    builder: (context, constraints) => Row(
                      children: [
                        Flexible(
                          child: Tooltip(
                            message: '${index + 1}. ${concept.title}',
                            child: StudyText(
                              '${index + 1}. ${concept.title}',
                              key: ValueKey('ai-concept-title-${concept.id}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.65,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: ConceptImportanceBadge(
                                  key: ValueKey(
                                    'ai-concept-importance-${concept.id}',
                                  ),
                                  importance: concept.importance,
                                  compact: true,
                                ),
                              ),
                              if (concept.hasPageSource) ...[
                                const SizedBox(width: 4),
                                Flexible(
                                  child: ConceptSourceBadge(
                                    key: ValueKey(
                                      'ai-concept-page-source-${concept.id}',
                                    ),
                                    sourceId: concept.sourceId,
                                    pages: concept.pageNumbers,
                                    compact: true,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  onTap: () => setState(() {
                    if (!_selectedConceptIds.contains(concept.id)) {
                      _selectedConceptIds.add(concept.id);
                    } else {
                      _selectedConceptIds.remove(concept.id);
                    }
                  }),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _generate(String folderId) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _progress = null;
      _lastProgressConceptTitle = null;
    });
    final provider = aiQuestionGenerationControllerProvider(
      widget.initialFolderId,
    );
    try {
      await ref
          .read(provider.notifier)
          .generate(
            folderId: folderId,
            sourceText: _usesConcepts ? '' : _sourceTextController.text,
            onProgress: (progress) {
              if (mounted) {
                setState(() {
                  _progress = progress;
                  _lastProgressConceptTitle =
                      progress.conceptTitle ?? _lastProgressConceptTitle;
                });
              }
            },
            sourceLabel: _sourceLabel,
            questionTypes: _questionTypes,
            minimumDifficulty: _difficultyRange.start.round(),
            maximumDifficulty: _difficultyRange.end.round(),
            concepts: _generationConcepts,
            reflectConceptImportance:
                _generationConcepts.isNotEmpty && _reflectConceptImportance,
            generationMode: _generationMode,
            automaticDensity:
                _generationMode == AiQuestionGenerationMode.automatic
                ? _automaticDensity
                : null,
            questionCount: _generationMode == AiQuestionGenerationMode.manual
                ? int.parse(_manualQuestionCountController.text)
                : null,
            sourceReference: _conceptSeed == null
                ? _sourceSeed?.sourceReference
                : QuestionSourceDraft(
                    sourceId: _conceptSeed!.source.id,
                    conceptId: _conceptSeed!.concept.id,
                    pageNumbers: _conceptSeed!.concept.pageNumbers,
                  ),
          );
    } catch (error) {
      if (!mounted) return;
      showAppError(context, _messageFor(error));
    }
  }

  String _difficultyLabel(double value) {
    final level = value.round();
    return '$level · ${_difficultyLabels[level]}';
  }

  String _messageFor(Object error) =>
      error is AppFailure ? error.message : 'AI 문제 생성을 완료하지 못했어요.';

  Future<void> _pickSource(List<Folder> folders) async {
    if (_sourceLocked) return;
    final repository = ref.read(sourceRepositoryProvider);
    final byId = {for (final folder in folders) folder.id: folder};
    String pathFor(Folder folder) {
      final parts = <String>[];
      final visited = <String>{};
      Folder? current = folder;
      while (current != null && visited.add(current.id)) {
        parts.add(current.name);
        current = byId[current.parentId];
      }
      return parts.reversed.join(' / ');
    }

    final source = await showAiSourcePicker(
      context,
      selectedSourceId: _selectedSource?.id,
      loadOptions: () async {
        final groups = await Future.wait(
          folders.map(
            (folder) async => [
              for (final source in await repository.getSources(folder.id))
                AiSourceOption(source: source, folderPath: pathFor(folder)),
            ],
          ),
        );
        return groups.expand((group) => group).toList()..sort((a, b) {
          final order = a.folderPath.compareTo(b.folderPath);
          return order == 0
              ? a.source.fileName.compareTo(b.source.fileName)
              : order;
        });
      },
    );
    if (!mounted || source == null) return;
    await _loadSource(source);
  }

  void _clearSource() {
    if (_sourceLocked) return;
    setState(() {
      _selectedSource = null;
      _sourceSeed = null;
      _conceptSeed = null;
      _conceptSeedError = null;
      _selectedConceptIds.clear();
    });
  }

  Future<void> _loadSource(
    StudySource source, {
    bool useSourceFolder = false,
  }) async {
    setState(() {
      _loadingConceptSeed = true;
      _selectedSource = source;
      _sourceSeed = null;
      _conceptSeed = null;
      _conceptSeedError = null;
      _selectedConceptIds.clear();
    });
    try {
      final seed = await ref
          .read(sourceRepositoryProvider)
          .getSourceGenerationSeed(source.id);
      if (!mounted) return;
      setState(() {
        _sourceSeed = seed;
        _selectedSource = seed.source;
        _selectedConceptIds.addAll(seed.concepts.map((concept) => concept.id));
        if (useSourceFolder) _selectedFolderId = seed.folderId;
        _loadingConceptSeed = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _conceptSeedError = error;
        _loadingConceptSeed = false;
      });
    }
  }

  Future<void> _loadConceptSeed() async {
    try {
      if (widget.initialConceptId == null) {
        final review = await ref
            .read(sourceRepositoryProvider)
            .getSourceWithConcepts(widget.initialSourceId!);
        if (!mounted) return;
        await _loadSource(review.source, useSourceFolder: true);
        return;
      }
      final seed = await ref
          .read(sourceRepositoryProvider)
          .getConceptGenerationSeed(widget.initialConceptId!);
      if (!mounted) return;
      setState(() {
        _conceptSeed = seed;
        _selectedSource = seed.source;
        _selectedConceptIds.add(seed.concept.id);
        _selectedFolderId = seed.folderId;
        _loadingConceptSeed = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _conceptSeedError = error;
        _loadingConceptSeed = false;
      });
    }
  }
}

class _ReviewPanel extends ConsumerStatefulWidget {
  const _ReviewPanel({required this.review, required this.provider});

  final AiQuestionReviewState review;
  final AiQuestionGenerationControllerProvider provider;

  @override
  ConsumerState<_ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends ConsumerState<_ReviewPanel> {
  bool _busy = false;
  AiQuestionReviewState get review => widget.review;
  AiQuestionGenerationControllerProvider get provider => widget.provider;

  @override
  Widget build(BuildContext context) {
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
                if (review.failures.isNotEmpty) ...[
                  AppErrorNotice(
                    error:
                        '일부 개념의 생성에 실패했어요. 성공한 문제는 아래에서 검토할 수 있어요.\n${review.failures.map((failure) => '${failure.title}: ${failure.error}').join('\n')}',
                  ),
                  const SizedBox(height: 16),
                ],
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '생성된 문제 ${review.items.length}개',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text('생성 모델: ${review.metadata.model}'),
                        const SizedBox(height: 16),
                        AppActionGroup(
                          children: [
                            FilledButton.icon(
                              key: const Key('approve-all-ai-questions-button'),
                              onPressed: _busy || review.pendingCount == 0
                                  ? null
                                  : () => _run(
                                      context,
                                      () => ref
                                          .read(provider.notifier)
                                          .approveAll(),
                                      '남은 문제를 모두 승인했어요.',
                                    ),
                              icon: const Icon(Icons.done_all_rounded),
                              label: Text('남은 ${review.pendingCount}개 모두 승인'),
                            ),
                            OutlinedButton(
                              onPressed: _busy
                                  ? null
                                  : () => context.go(
                                      AppRoutes.folder(review.folderId),
                                    ),
                              child: const Text('검수 종료'),
                            ),
                          ],
                        ),
                        if (_busy) ...[
                          const SizedBox(height: AppSpacing.sm),
                          const LinearProgressIndicator(
                            semanticsLabel: '검수 변경사항 저장 중',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (final item in review.items) ...[
                  _ReviewCard(
                    item: item,
                    provider: provider,
                    enabled: !_busy,
                    run: (action, success) => _run(context, action, success),
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

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String? success,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!context.mounted) return;
      if (success != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error) {
      if (!context.mounted) return;
      final message = error is AppFailure ? error.message : '검수 작업을 완료하지 못했어요.';
      showAppError(context, message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ReviewCard extends ConsumerWidget {
  const _ReviewCard({
    required this.item,
    required this.provider,
    required this.enabled,
    required this.run,
  });

  final AiQuestionReviewItem item;
  final AiQuestionGenerationControllerProvider provider;
  final bool enabled;
  final Future<void> Function(Future<void> Function(), String?) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final question = item.question;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ConceptBadge(label: _typeLabel(question.type)),
                ReviewStatusBadge(
                  reviewed: item.status == AiReviewStatus.approved,
                  label: _statusLabel(item.status),
                ),
                ConceptBadge(label: '난이도 ${question.difficulty}/5'),
              ],
            ),
            const SizedBox(height: 10),
            StudyText(
              question.prompt,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (question.type == QuestionType.multipleChoice ||
                question.type == QuestionType.trueFalse) ...[
              const SizedBox(height: 12),
              for (final choice in question.choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: StudyText(
                    choice.isCorrect ? '✓ ${choice.text}' : choice.text,
                  ),
                ),
            ] else ...[
              const SizedBox(height: 12),
              StudyText('허용 정답: ${question.acceptableAnswers.join(' / ')}'),
            ],
            if (question.explanation case final explanation?) ...[
              const SizedBox(height: 10),
              StudyText('해설: $explanation'),
            ],
            if (item.status == AiReviewStatus.pending) ...[
              const SizedBox(height: 16),
              AppActionGroup(
                children: [
                  FilledButton.tonal(
                    onPressed: enabled ? () => _approve(context, ref) : null,
                    child: const Text('승인'),
                  ),
                  OutlinedButton(
                    onPressed: enabled ? () => _edit(context, ref) : null,
                    child: const Text('수정 후 승인'),
                  ),
                  TextButton(
                    onPressed: enabled ? () => _reject(context, ref) : null,
                    child: const Text('삭제'),
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
    await run(() async {
      final saved = await context.push<bool>(
        AppRoutes.editQuestion(item.questionId),
      );
      if (saved == true && context.mounted) {
        ref.read(provider.notifier).markEditedAndApproved(item.questionId);
      }
    }, null);
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: const Text('문제 삭제'),
        content: Text('다음 생성 문제를 삭제할까요?\n\n${item.question.prompt}'),
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
    await _run(
      context,
      () => ref.read(provider.notifier).reject(item.questionId),
      '생성 문제를 삭제했어요.',
    );
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String success,
  ) => run(action, success);

  String _typeLabel(QuestionType type) => switch (type) {
    QuestionType.multipleChoice => '객관식',
    QuestionType.trueFalse => 'O/X',
    QuestionType.shortAnswer => '단답형',
    QuestionType.essay => '서술형',
  };

  String _statusLabel(AiReviewStatus status) => switch (status) {
    AiReviewStatus.pending => '미승인',
    AiReviewStatus.approved => '승인됨',
    AiReviewStatus.rejected => '삭제됨',
  };
}

class _ConceptSelectionHeader extends StatelessWidget {
  const _ConceptSelectionHeader({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth >= 300 * scale) return Row(children: children);
      // Unwrap the row's Expanded label in a narrow vertical layout.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          (children.first as Expanded).child,
          Wrap(spacing: 8, runSpacing: 8, children: children.skip(2).toList()),
        ],
      );
    },
  );
}
