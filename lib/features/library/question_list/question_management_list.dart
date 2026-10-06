import 'package:review_platform/app/design_tokens.dart';
import 'package:review_platform/shared/widgets/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/folder_browser/folder_browser_view_model.dart';
import 'package:review_platform/features/library/question_list/question_management_card.dart';
import 'package:review_platform/features/library/question_list/question_management_filter.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';

class QuestionManagementList extends ConsumerStatefulWidget {
  const QuestionManagementList({
    required this.questions,
    this.folderId,
    this.scopeLabel = '현재 폴더',
    super.key,
  });
  final List<Question> questions;
  final String? folderId;
  final String scopeLabel;

  @override
  ConsumerState<QuestionManagementList> createState() =>
      _QuestionManagementListState();
}

class _QuestionManagementListState
    extends ConsumerState<QuestionManagementList> {
  final _search = TextEditingController();
  final _selected = <String>{};
  // A non-reactive cache restores expansion when a filter temporarily removes
  // a card. Each mounted card owns its actual expansion state and rebuilds.
  final _expandedIds = <String>{};
  var _filter = const QuestionManagementFilter();
  var _sort = QuestionManagementSort.updated;
  bool _busy = false;
  bool _writing = false;
  List<Question>? _cachedQuestions;
  QuestionManagementFilter? _cachedFilter;
  QuestionManagementSort? _cachedSort;
  String? _cachedQuery;
  List<Question> _visibleQuestions = const [];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QuestionManagementList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cachedQuestions = null;
    if (oldWidget.folderId != widget.folderId) {
      _search.clear();
      _filter = const QuestionManagementFilter();
      _selected.clear();
      _expandedIds.clear();
    }
    final active = widget.questions.map((question) => question.id).toSet();
    _selected.retainAll(active);
    _expandedIds.retainAll(active);
  }

  @override
  Widget build(BuildContext context) {
    // Local expansion/selection does not change filtering or sort order.
    if (!identical(_cachedQuestions, widget.questions) ||
        !identical(_cachedFilter, _filter) ||
        _cachedQuery != _search.text ||
        _cachedSort != _sort) {
      _visibleQuestions = _filter.apply(
        widget.questions,
        query: _search.text,
        sort: _sort,
      );
      _cachedQuestions = widget.questions;
      _cachedFilter = _filter;
      _cachedQuery = _search.text;
      _cachedSort = _sort;
    }
    final visible = _visibleQuestions;
    final visibleIds = visible.map((question) => question.id).toSet();
    final selected = visible
        .where((question) => _selected.contains(question.id))
        .toList();
    final sources = <String, String>{
      for (final question in widget.questions)
        for (final source in question.sourceReferences)
          source.sourceId: source.fileName,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('question-search-field'),
          controller: _search,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: '문제 검색',
            hintText: '문제·정답·해설·자료·개념 검색 (${widget.scopeLabel})',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '검색어 지우기',
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _search.clear();
                            _selected.clear();
                          }),
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
          onChanged: (_) => setState(_selected.clear),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${widget.scopeLabel} · ${visible.length}/${widget.questions.length}개',
            ),
            IconButton(
              key: const Key('question-filter-button'),
              tooltip: '문제 필터',
              isSelected: _filter.isActive,
              onPressed: _busy ? null : () => _showFilters(sources),
              icon: const Icon(Icons.filter_alt_outlined),
              selectedIcon: const Icon(Icons.filter_alt_rounded),
            ),
            PopupMenuButton<QuestionManagementSort>(
              key: const Key('question-sort-button'),
              tooltip: '문제 정렬',
              enabled: !_busy,
              onSelected: (sort) => setState(() => _sort = sort),
              itemBuilder: (context) => [
                for (final sort in QuestionManagementSort.values)
                  CheckedPopupMenuItem(
                    value: sort,
                    checked: sort == _sort,
                    child: Text(_sortLabel(sort)),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('${_sortLabel(_sort)} ▾'),
              ),
            ),
            TextButton(
              key: const Key('select-all-visible-questions'),
              onPressed: _busy || visible.isEmpty
                  ? null
                  : () => setState(() {
                      _selected.clear();
                      _selected.addAll(visibleIds);
                    }),
              child: const Text('검색 결과 전체 선택'),
            ),
            if (_selected.isNotEmpty)
              TextButton(
                onPressed: _busy ? null : () => setState(_selected.clear),
                child: const Text('선택 해제'),
              ),
          ],
        ),
        if (_filter.isActive)
          Wrap(
            spacing: 6,
            children: [
              if (_filter.type != null)
                ConceptBadge(label: questionTypeLabel(_filter.type!)),
              if (_filter.status != null)
                ConceptBadge(label: questionStatusLabel(_filter.status!)),
              if (_filter.importance != null)
                ConceptBadge(label: '중요도 ${_filter.importance!.label}'),
              if (_filter.minDifficulty != 1 || _filter.maxDifficulty != 5)
                ConceptBadge(
                  label:
                      '난이도 ${_filter.minDifficulty}–${_filter.maxDifficulty}',
                ),
              if (_filter.sourceId != null)
                ConceptBadge(label: sources[_filter.sourceId] ?? '선택한 자료'),
              TextButton(
                key: const Key('reset-question-filters'),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _filter = const QuestionManagementFilter();
                        _selected.clear();
                      }),
                child: const Text('필터 초기화'),
              ),
            ],
          ),
        if (selected.isNotEmpty)
          Card(
            key: const Key('question-selection-actions'),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${selected.length}개 선택'),
                  if (_writing)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  TextButton.icon(
                    key: const Key('approve-selected-questions'),
                    onPressed:
                        _busy ||
                            !selected.any(
                              (question) =>
                                  question.status == QuestionStatus.draft,
                            )
                        ? null
                        : () =>
                              _act(QuestionManagementAction.approve, selected),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('승인'),
                  ),
                  TextButton.icon(
                    key: const Key('move-selected-questions'),
                    onPressed: _busy
                        ? null
                        : () => _act(QuestionManagementAction.move, selected),
                    icon: const Icon(Icons.drive_file_move_outlined),
                    label: const Text('이동'),
                  ),
                  TextButton.icon(
                    key: const Key('delete-selected-questions'),
                    onPressed: _busy
                        ? null
                        : () => _act(QuestionManagementAction.delete, selected),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('삭제'),
                  ),
                ],
              ),
            ),
          ),
        if (visible.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text(
                widget.questions.isEmpty
                    ? widget.folderId != null
                          ? '이 폴더에 저장된 문제가 없어요.'
                          : '이 개념에 연결된 문제가 없어요.'
                    : '검색 조건에 맞는 문제가 없어요.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        for (final question in visible) ...[
          QuestionManagementCard(
            key: ValueKey((widget.folderId, question.id)),
            question: question,
            initiallyExpanded: _expandedIds.contains(question.id),
            onExpansionChanged: (expanded) {
              if (expanded) {
                _expandedIds.add(question.id);
              } else {
                _expandedIds.remove(question.id);
              }
            },
            selected: _selected.contains(question.id),
            onSelect: (value) => setState(() {
              if (value) {
                _selected.add(question.id);
              } else {
                _selected.remove(question.id);
              }
            }),
            enabled: !_busy,
            onAction: (action) => _act(action, [question]),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Future<void> _act(
    QuestionManagementAction action,
    List<Question> questions,
  ) async {
    if (_busy || questions.isEmpty) return;
    if (action == QuestionManagementAction.edit) {
      context.push(AppRoutes.editQuestion(questions.single.id));
      return;
    }
    // Lock before any dialog/network/database await, not only during the write.
    setState(() => _busy = true);
    try {
      final repository = ref.read(questionRepositoryProvider);
      var ids = questions
          .map((question) => question.id)
          .toList(growable: false);
      switch (action) {
        case QuestionManagementAction.approve:
          ids = questions
              .where((question) => question.status == QuestionStatus.draft)
              .map((question) => question.id)
              .toList();
          if (ids.isEmpty) return;
          setState(() => _writing = true);
          await repository.approveQuestions(ids);
        case QuestionManagementAction.move:
          final state = await ref.read(
            folderBrowserViewModelProvider(
              widget.folderId ?? questions.first.folderId,
            ).future,
          );
          if (!mounted) return;
          if (!state.allFolders.any(
            (folder) =>
                questions.any((question) => question.folderId != folder.id),
          )) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('이동할 다른 폴더를 먼저 만들어 주세요.')),
            );
            return;
          }
          final choice = await showFolderPicker(
            context,
            folders: state.allFolders,
            selectedFolderId: widget.folderId ?? questions.first.folderId,
            title: ids.length == 1 ? '문제 이동' : '${ids.length}개 문제 이동',
          );
          if (choice?.folderId == null || !mounted) return;
          if (questions.every(
            (question) => question.folderId == choice!.folderId,
          )) {
            return;
          }
          setState(() => _writing = true);
          await repository.moveQuestions(ids: ids, folderId: choice!.folderId!);
        case QuestionManagementAction.delete:
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AppDialog(
              title: const Text('문제 삭제'),
              content: Text('선택한 문제 ${ids.length}개를 삭제하시겠습니까?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  key: const Key('confirm-delete-selected-questions'),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('삭제'),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
          setState(() => _writing = true);
          await repository.deleteQuestions(ids);
        case QuestionManagementAction.edit:
          return;
      }
      if (!mounted) return;
      setState(() => _selected.removeAll(ids));
      final verb = switch (action) {
        QuestionManagementAction.approve => '승인',
        QuestionManagementAction.move => '이동',
        QuestionManagementAction.delete => '삭제',
        QuestionManagementAction.edit => '수정',
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${ids.length}개 문제를 $verb했어요.')));
    } catch (error) {
      if (mounted) showAppError(context, error, fallback: '문제 작업을 완료하지 못했어요.');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _writing = false;
        });
      }
    }
  }

  Future<void> _showFilters(Map<String, String> sources) async {
    var type = _filter.type;
    var status = _filter.status;
    var importance = _filter.importance;
    var sourceId = sources.containsKey(_filter.sourceId)
        ? _filter.sourceId
        : null;
    var range = RangeValues(
      _filter.minDifficulty.toDouble(),
      _filter.maxDifficulty.toDouble(),
    );
    final result = await showDialog<QuestionManagementFilter>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AppDialog(
          title: const Text('문제 필터'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<QuestionType>(
                    key: const Key('question-type-filter'),
                    initialValue: type,
                    decoration: const InputDecoration(labelText: '문제 유형'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('전체')),
                      for (final value in QuestionType.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(questionTypeLabel(value)),
                        ),
                    ],
                    onChanged: (value) => update(() => type = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<QuestionStatus>(
                    key: const Key('question-status-filter'),
                    initialValue: status,
                    decoration: const InputDecoration(labelText: '승인 여부'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('전체')),
                      for (final value in QuestionStatus.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(questionStatusLabel(value)),
                        ),
                    ],
                    onChanged: (value) => update(() => status = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ConceptImportance>(
                    key: const Key('question-importance-filter'),
                    initialValue: importance,
                    decoration: const InputDecoration(labelText: '중요도'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('전체')),
                      for (final value in ConceptImportance.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) => update(() => importance = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('question-source-filter'),
                    initialValue: sourceId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '출처 자료'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('전체')),
                      for (final source in sources.entries)
                        DropdownMenuItem(
                          value: source.key,
                          child: Text(
                            source.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => update(() => sourceId = value),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '난이도 ${range.start.round()}–${range.end.round()}',
                    ),
                  ),
                  RangeSlider(
                    key: const Key('question-difficulty-filter'),
                    values: range,
                    min: 1,
                    max: 5,
                    divisions: 4,
                    labels: RangeLabels(
                      '${range.start.round()}',
                      '${range.end.round()}',
                    ),
                    onChanged: (value) => update(() => range = value),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('apply-question-filters'),
              onPressed: () => Navigator.pop(
                context,
                QuestionManagementFilter(
                  type: type,
                  status: status,
                  importance: importance,
                  sourceId: sourceId,
                  minDifficulty: range.start.round(),
                  maxDifficulty: range.end.round(),
                ),
              ),
              child: const Text('적용'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _filter = result;
        _selected.clear();
      });
    }
  }
}

String _sortLabel(QuestionManagementSort sort) => switch (sort) {
  QuestionManagementSort.updated => '최근 수정순',
  QuestionManagementSort.created => '최근 생성순',
  QuestionManagementSort.difficulty => '난이도 높은순',
  QuestionManagementSort.importance => '중요도 높은순',
};
