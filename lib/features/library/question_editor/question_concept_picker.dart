import 'package:review_platform/app/design_tokens.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/features/library/question_editor/question_editor_view_model.dart';
import 'package:review_platform/shared/widgets/app_error.dart';
import 'package:review_platform/shared/widgets/study_text.dart';

class QuestionConceptPicker extends StatefulWidget {
  const QuestionConceptPicker({
    required this.loadOptions,
    this.selectedConceptId,
    super.key,
  });
  final Future<List<QuestionConceptOption>> Function() loadOptions;
  final String? selectedConceptId;

  @override
  State<QuestionConceptPicker> createState() => _QuestionConceptPickerState();
}

class _QuestionConceptPickerState extends State<QuestionConceptPicker> {
  late Future<List<QuestionConceptOption>> _options;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _options = widget.loadOptions();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '주개념 선택',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const Key('close-concept-picker-button'),
                  tooltip: '닫기',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('primary-concept-search-field'),
              decoration: const InputDecoration(
                labelText: '자료·개념·폴더 이름 검색',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 12),
            const Text('정답을 결정하는 개념 하나를 선택하세요. 문제와 다른 폴더의 개념도 연결할 수 있습니다.'),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<QuestionConceptOption>>(
                future: _options,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          AppErrorNotice(
                            error: snapshot.error!,
                            fallback: '주개념 목록을 불러오지 못했어요.',
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            key: const Key('retry-concept-picker-button'),
                            onPressed: () {
                              final options = widget.loadOptions();
                              setState(() {
                                _options = options;
                              });
                            },
                            child: const Text('다시 시도'),
                          ),
                        ],
                      ),
                    );
                  }
                  final all = snapshot.data;
                  if (all == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final options = all
                      .where(
                        (option) => '${option.label} ${option.folderPath}'
                            .toLowerCase()
                            .contains(_query),
                      )
                      .toList();
                  if (options.isEmpty) {
                    return Center(
                      child: Text(
                        all.isEmpty
                            ? '선택할 개념이 없어요. 자료에서 개념을 먼저 추가해 주세요.'
                            : '검색 결과가 없어요.',
                      ),
                    );
                  }
                  return ListView.separated(
                    key: const Key('primary-concept-options'),
                    itemCount: options.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final option = options[index];
                      final concept = option.concept;
                      return ListTile(
                        key: Key('select-primary-concept-${concept.id}'),
                        selected: widget.selectedConceptId == concept.id,
                        title: StudyText(
                          concept.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${option.folderPath} / ${option.source.fileName}\n'
                          '중요도 ${concept.importance.label} · '
                          '${concept.status == ConceptStatus.approved ? '검토 완료' : '검토 필요'}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.of(context).pop(option),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
