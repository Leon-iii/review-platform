import 'package:flutter/material.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/shared/widgets/folder_picker.dart';

Future<String?> showFolderNameDialog(
  BuildContext context, {
  required String title,
  String initialName = '',
}) async {
  return showDialog<String>(
    context: context,
    builder: (context) =>
        _FolderNameDialog(title: title, initialName: initialName),
  );
}

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({required this.title, required this.initialName});

  final String title;
  final String initialName;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '폴더 이름',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return '폴더 이름을 입력해 주세요.';
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}

class FolderMoveSelection {
  const FolderMoveSelection(this.parentId);

  final String? parentId;
}

Future<FolderMoveSelection?> showFolderMoveDialog(
  BuildContext context, {
  required Folder folder,
  required List<Folder> targets,
}) {
  String? selectedParentId = folder.parentId;

  return showDialog<FolderMoveSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('폴더 옮기기'),
        content: SizedBox(
          width: 360,
          child: FolderPickerField(
            key: const Key('move-folder-parent-field'),
            folders: targets,
            selectedFolderId: selectedParentId,
            labelText: '새 상위 폴더',
            allowRoot: true,
            onChanged: (value) => setState(() => selectedParentId = value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context)
                    .pop(FolderMoveSelection(selectedParentId)),
            child: const Text('옮기기'),
          ),
        ],
      ),
    ),
  );
}

Future<bool> showFolderDeleteDialog(
  BuildContext context, {
  required Folder folder,
  required FolderDeletionImpact impact,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('폴더 삭제'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${folder.name} 폴더를 삭제하시겠습니까?'),
          const SizedBox(height: 16),
          Text('하위 폴더: ${impact.descendantFolderCount}개'),
          Text('포함 문제: ${impact.questionCount}개'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: const Text('삭제'),
        ),
      ],
    ),
  );

  return confirmed ?? false;
}
