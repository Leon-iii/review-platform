import 'package:flutter/material.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

class ConceptImportanceDialog extends StatefulWidget {
  const ConceptImportanceDialog({
    required this.title,
    required this.initialImportance,
    required this.onSave,
    super.key,
  });
  final String title;
  final ConceptImportance initialImportance;
  final Future<void> Function(ConceptImportance) onSave;
  @override
  State<ConceptImportanceDialog> createState() =>
      _ConceptImportanceDialogState();
}

class _ConceptImportanceDialogState extends State<ConceptImportanceDialog> {
  late ConceptImportance _importance = widget.initialImportance;
  bool _saving = false;
  Object? _error;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_importance);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error;
      });
      showAppError(context, error, fallback: '중요도를 저장하지 못했어요.');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      key: const Key('concept-importance-dialog'),
      title: const Text('중요도 설정'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 20),
              Text(
                _importance.label,
                key: const Key('concept-importance-label'),
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              Slider(
                key: const Key('concept-importance-field'),
                value: _importance.index.toDouble(),
                min: 0,
                max: 4,
                divisions: 4,
                label: _importance.label,
                semanticFormatterCallback: (value) =>
                    ConceptImportance.values[value.round()].label,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _importance = ConceptImportance.values[value.round()];
                      }),
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text('매우 낮음'), Text('매우 높음')],
              ),
              if (_saving) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                AppErrorNotice(error: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-concept-importance-button'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('save-concept-importance-button'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '저장 중…' : '저장'),
        ),
      ],
    ),
  );
}
