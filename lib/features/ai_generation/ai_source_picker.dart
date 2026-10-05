import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

class AiSourceOption {
  const AiSourceOption({required this.source, required this.folderPath});
  final StudySource source;
  final String folderPath;
}

class AiSourcePickerField extends StatelessWidget {
  const AiSourcePickerField({
    required this.source,
    required this.locked,
    required this.onTap,
    this.onClear,
    super.key,
  });
  final StudySource? source;
  final bool locked;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: !locked,
    label:
        '자료 이름: ${source?.fileName ?? '자료를 선택해 주세요.'}${locked ? ', 변경 불가' : ''}',
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('ai-source-picker-button'),
        onTap: locked ? null : onTap,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: '자료 이름',
            enabled: !locked,
            border: const OutlineInputBorder(),
            helperText: locked ? '자료 화면에서 시작한 경우 자료를 변경할 수 없어요.' : null,
            helperMaxLines: 2,
            suffixIcon: locked
                ? const Icon(
                    Icons.lock_outline_rounded,
                    key: Key('ai-source-picker-lock'),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (source != null && onClear != null)
                        IconButton(
                          key: const Key('clear-ai-source-button'),
                          tooltip: '자료 선택 해제',
                          onPressed: onClear,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Icon(Icons.arrow_drop_down_rounded),
                      ),
                    ],
                  ),
          ),
          child: Text(
            source?.fileName ?? '자료를 선택해 주세요.',
            key: const Key('ai-selected-source-name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ),
  );
}

Future<StudySource?> showAiSourcePicker(
  BuildContext context, {
  required Future<List<AiSourceOption>> Function() loadOptions,
  String? selectedSourceId,
}) {
  final panel = _AiSourcePickerPanel(
    loadOptions: loadOptions,
    selectedSourceId: selectedSourceId,
  );
  if (defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux) {
    return showDialog<StudySource>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 600),
          child: panel,
        ),
      ),
    );
  }
  return showModalBottomSheet<StudySource>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: panel,
      ),
    ),
  );
}

class _AiSourcePickerPanel extends StatefulWidget {
  const _AiSourcePickerPanel({
    required this.loadOptions,
    this.selectedSourceId,
  });
  final Future<List<AiSourceOption>> Function() loadOptions;
  final String? selectedSourceId;
  @override
  State<_AiSourcePickerPanel> createState() => _AiSourcePickerPanelState();
}

class _AiSourcePickerPanelState extends State<_AiSourcePickerPanel> {
  late Future<List<AiSourceOption>> _options;
  String _query = '';
  @override
  void initState() {
    super.initState();
    _options = widget.loadOptions();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '자료 선택',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              key: const Key('close-ai-source-picker'),
              tooltip: '닫기',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ai-source-search-field'),
          decoration: const InputDecoration(
            labelText: '자료·폴더 이름 검색',
            prefixIcon: Icon(Icons.search_rounded),
            border: OutlineInputBorder(),
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: FutureBuilder<List<AiSourceOption>>(
            future: _options,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AppErrorNotice(
                      error: snapshot.error is AppFailure
                          ? (snapshot.error! as AppFailure).message
                          : '자료 목록을 불러오지 못했어요.',
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _options = widget.loadOptions()),
                      child: const Text('다시 시도'),
                    ),
                  ],
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snapshot.data!
                  .where(
                    (option) =>
                        _query.isEmpty ||
                        '${option.source.fileName} ${option.folderPath}'
                            .toLowerCase()
                            .contains(_query),
                  )
                  .toList();
              if (items.isEmpty) {
                return Center(
                  child: Text(
                    snapshot.data!.isEmpty
                        ? '선택할 자료가 없어요. 폴더에서 자료를 먼저 추가해 주세요.'
                        : '검색 결과가 없어요.',
                  ),
                );
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final option = items[index];
                  return ListTile(
                    key: ValueKey('ai-source-option-${option.source.id}'),
                    selected: option.source.id == widget.selectedSourceId,
                    leading: Icon(
                      option.source.isManual
                          ? Icons.article_outlined
                          : Icons.picture_as_pdf_outlined,
                    ),
                    title: Text(option.source.fileName),
                    subtitle: Text(option.folderPath),
                    trailing: option.source.id == widget.selectedSourceId
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(option.source),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}
