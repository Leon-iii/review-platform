import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:review_platform/domain/models/folder.dart';

class FolderPickerField extends StatelessWidget {
  const FolderPickerField({
    required this.folders,
    required this.selectedFolderId,
    required this.onChanged,
    required this.labelText,
    this.helperText,
    this.allowRoot = false,
    this.rootLabel = '최상위',
    super.key,
  });

  final List<Folder> folders;
  final String? selectedFolderId;
  final ValueChanged<String?> onChanged;
  final String labelText;
  final String? helperText;
  final bool allowRoot;
  final String rootLabel;

  @override
  Widget build(BuildContext context) {
    final index = _FolderIndex(folders);
    final selectedPath = selectedFolderId == null
        ? rootLabel
        : index.pathFor(selectedFolderId!) ?? '폴더를 선택해 주세요.';

    return Semantics(
      button: true,
      label: '$labelText: $selectedPath',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _openPicker(context),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: labelText,
              helperText: helperText,
              border: const OutlineInputBorder(),
              suffixIcon: const Icon(Icons.folder_open_rounded),
            ),
            child: Text(
              selectedPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final selection = await showFolderPicker(
      context,
      folders: folders,
      selectedFolderId: selectedFolderId,
      allowRoot: allowRoot,
      rootLabel: rootLabel,
    );
    if (selection == null) return;
    if (selection.folderId != null) {
      _RecentFolders.record(selection.folderId!);
    }
    onChanged(selection.folderId);
  }
}

class FolderPickerSelection {
  const FolderPickerSelection(this.folderId);

  final String? folderId;
}

Future<FolderPickerSelection?> showFolderPicker(
  BuildContext context, {
  required List<Folder> folders,
  String? selectedFolderId,
  bool allowRoot = false,
  String rootLabel = '최상위',
}) {
  final useDialog = switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
  final panel = _FolderPickerPanel(
    folders: folders,
    selectedFolderId: selectedFolderId,
    allowRoot: allowRoot,
    rootLabel: rootLabel,
  );

  if (useDialog) {
    return showDialog<FolderPickerSelection>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 680),
          child: panel,
        ),
      ),
    );
  }

  return showModalBottomSheet<FolderPickerSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: panel,
    ),
  );
}

class _FolderPickerPanel extends StatefulWidget {
  const _FolderPickerPanel({
    required this.folders,
    required this.selectedFolderId,
    required this.allowRoot,
    required this.rootLabel,
  });

  final List<Folder> folders;
  final String? selectedFolderId;
  final bool allowRoot;
  final String rootLabel;

  @override
  State<_FolderPickerPanel> createState() => _FolderPickerPanelState();
}

class _FolderPickerPanelState extends State<_FolderPickerPanel> {
  late final TextEditingController _searchController;
  late final _FolderIndex _index;
  final Set<String> _expandedIds = {};

  String get _query => _searchController.text.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()..addListener(_onSearchChanged);
    _index = _FolderIndex(widget.folders);
    _expandedIds.addAll(_index.roots.map((folder) => folder.id));
    var parentId = widget.selectedFolderId == null
        ? null
        : _index.byId[widget.selectedFolderId!]?.parentId;
    while (parentId != null) {
      _expandedIds.add(parentId);
      parentId = _index.byId[parentId]?.parentId;
    }
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final matches = _query.isEmpty
        ? const <Folder>[]
        : widget.folders
              .where((folder) {
                final path = _index.pathFor(folder.id) ?? folder.name;
                return folder.name.toLowerCase().contains(_query) ||
                    path.toLowerCase().contains(_query);
              })
              .toList(growable: false);
    final recentFolders = _RecentFolders.ids
        .map((id) => _index.byId[id])
        .whereType<Folder>()
        .take(5)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '폴더 선택',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            key: const Key('folder-picker-search-field'),
            controller: _searchController,
            autofocus: MediaQuery.sizeOf(context).width >= 600,
            decoration: InputDecoration(
              hintText: '폴더 이름이나 경로 검색',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '검색어 지우기',
                      onPressed: _searchController.clear,
                      icon: const Icon(Icons.clear_rounded),
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _query.isNotEmpty
              ? _SearchResults(
                  folders: matches,
                  index: _index,
                  selectedFolderId: widget.selectedFolderId,
                  onSelected: _select,
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    if (recentFolders.isNotEmpty) ...[
                      const _SectionLabel('최근 사용'),
                      for (final folder in recentFolders)
                        _FolderRow(
                          itemKey: Key(
                            'folder-picker-recent-item-${folder.id}',
                          ),
                          folder: folder,
                          path: _index.pathFor(folder.id),
                          selected: folder.id == widget.selectedFolderId,
                          onSelected: () => _select(folder.id),
                        ),
                      const Divider(height: 24),
                    ],
                    const _SectionLabel('모든 폴더'),
                    if (widget.allowRoot)
                      _FolderRow(
                        itemKey: const Key('folder-picker-root-item'),
                        label: widget.rootLabel,
                        selected: widget.selectedFolderId == null,
                        icon: Icons.account_tree_outlined,
                        onSelected: () => _select(null),
                      ),
                    for (final root in _index.roots) ..._treeRows(root, 0),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _treeRows(Folder folder, int depth) {
    final children = _index.childrenOf(folder.id);
    final expanded = _expandedIds.contains(folder.id);
    return [
      _FolderRow(
        itemKey: Key('folder-picker-tree-item-${folder.id}'),
        folder: folder,
        depth: depth,
        selected: folder.id == widget.selectedFolderId,
        expanded: expanded,
        hasChildren: children.isNotEmpty,
        onToggleExpanded: () => setState(() {
          if (expanded) {
            _expandedIds.remove(folder.id);
          } else {
            _expandedIds.add(folder.id);
          }
        }),
        onSelected: () => _select(folder.id),
      ),
      if (expanded)
        for (final child in children) ..._treeRows(child, depth + 1),
    ];
  }

  void _select(String? folderId) {
    Navigator.of(context).pop(FolderPickerSelection(folderId));
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.folders,
    required this.index,
    required this.selectedFolderId,
    required this.onSelected,
  });

  final List<Folder> folders;
  final _FolderIndex index;
  final String? selectedFolderId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return const Center(child: Text('검색 결과가 없어요.'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionLabel('검색 결과 ${folders.length}개'),
        for (final folder in folders)
          _FolderRow(
            itemKey: Key('folder-picker-item-${folder.id}'),
            folder: folder,
            path: index.pathFor(folder.id),
            selected: folder.id == selectedFolderId,
            onSelected: () => onSelected(folder.id),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.selected,
    required this.onSelected,
    this.itemKey,
    this.folder,
    this.label,
    this.path,
    this.depth = 0,
    this.icon = Icons.folder_outlined,
    this.expanded = false,
    this.hasChildren = false,
    this.onToggleExpanded,
  });

  final Folder? folder;
  final Key? itemKey;
  final String? label;
  final String? path;
  final int depth;
  final IconData icon;
  final bool selected;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback? onToggleExpanded;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: itemKey,
      contentPadding: EdgeInsets.only(left: 8 + depth * 20, right: 16),
      selected: selected,
      onTap: onSelected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            child: hasChildren
                ? IconButton(
                    tooltip: expanded ? '접기' : '펼치기',
                    onPressed: onToggleExpanded,
                    icon: Icon(
                      expanded
                          ? Icons.expand_more_rounded
                          : Icons.chevron_right_rounded,
                    ),
                  )
                : null,
          ),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off),
          const SizedBox(width: 12),
          Icon(icon),
        ],
      ),
      title: Text(label ?? folder!.name),
      subtitle: path == null ? null : Text(path!, maxLines: 1),
    );
  }
}

class _FolderIndex {
  _FolderIndex(List<Folder> folders) {
    byId = {for (final folder in folders) folder.id: folder};
    for (final folder in folders) {
      final parentId = byId.containsKey(folder.parentId)
          ? folder.parentId
          : null;
      (_childrenByParent[parentId] ??= []).add(folder);
    }
  }

  late final Map<String, Folder> byId;
  final Map<String?, List<Folder>> _childrenByParent = {};

  List<Folder> get roots => _childrenByParent[null] ?? const [];

  List<Folder> childrenOf(String parentId) =>
      _childrenByParent[parentId] ?? const [];

  String? pathFor(String id) {
    final folder = byId[id];
    if (folder == null) return null;
    final names = <String>[];
    final visited = <String>{};
    Folder? current = folder;
    while (current != null && visited.add(current.id)) {
      names.add(current.name);
      current = current.parentId == null ? null : byId[current.parentId!];
    }
    return names.reversed.join(' › ');
  }
}

abstract final class _RecentFolders {
  static final List<String> _ids = [];

  static List<String> get ids => List.unmodifiable(_ids);

  static void record(String id) {
    _ids
      ..remove(id)
      ..insert(0, id);
    if (_ids.length > 10) _ids.removeRange(10, _ids.length);
  }
}
