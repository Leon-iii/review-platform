import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:review_platform/app/router.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/features/library/folder_browser/folder_browser_view_model.dart';
import 'package:review_platform/features/library/folder_browser/folder_dialogs.dart';
import 'package:review_platform/features/library/question_list/question_list_view.dart';

class FolderBrowserView extends ConsumerWidget {
  const FolderBrowserView({this.folderId, super.key});

  final String? folderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = folderBrowserViewModelProvider(folderId);
    final browserState = ref.watch(provider);

    return Scaffold(
      key: const Key('library-view'),
      appBar: AppBar(
        title: browserState.maybeWhen(
          data: (state) => Text(state.currentFolder?.name ?? '문제 관리'),
          orElse: () => const Text('문제 관리'),
        ),
        actions: [
          IconButton(
            tooltip: '문제 추가',
            onPressed: folderId == null
                ? null
                : () => context.push(
                    Uri(
                      path: AppRoutes.newQuestion,
                      queryParameters: {'folderId': folderId},
                    ).toString(),
                  ),
            icon: const Icon(Icons.note_add_outlined),
          ),
        ],
      ),
      body: browserState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorState(
          message: _messageFor(error),
          onRetry: () => ref.invalidate(provider),
        ),
        data: (state) => _FolderList(
          state: state,
          onOpen: (folder) => context.push(AppRoutes.folder(folder.id)),
          onRename: (folder) => _renameFolder(context, ref, folder),
          onMove: (folder) => _moveFolder(context, ref, state, folder),
          onDelete: (folder) => _deleteFolder(context, ref, folder),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create-folder-button'),
        onPressed: () => _createFolder(context, ref),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('새 폴더'),
      ),
    );
  }

  Future<void> _createFolder(BuildContext context, WidgetRef ref) async {
    final name = await showFolderNameDialog(context, title: '새 폴더');
    if (name == null || !context.mounted) return;

    await _runAction(
      context,
      () => ref
          .read(folderBrowserViewModelProvider(folderId).notifier)
          .createFolder(name),
      successMessage: '$name 폴더를 생성했어요.',
    );
  }

  Future<void> _renameFolder(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final name = await showFolderNameDialog(
      context,
      title: '폴더 이름 변경',
      initialName: folder.name,
    );
    if (name == null || !context.mounted) return;

    await _runAction(
      context,
      () => ref
          .read(folderBrowserViewModelProvider(folderId).notifier)
          .renameFolder(id: folder.id, name: name),
      successMessage: '폴더 이름을 변경했어요.',
    );
  }

  Future<void> _moveFolder(
    BuildContext context,
    WidgetRef ref,
    FolderBrowserState state,
    Folder folder,
  ) async {
    final selection = await showFolderMoveDialog(
      context,
      folder: folder,
      targets: state.moveTargetsFor(folder.id),
    );
    if (selection == null || !context.mounted) return;

    await _runAction(
      context,
      () => ref
          .read(folderBrowserViewModelProvider(folderId).notifier)
          .moveFolder(id: folder.id, parentId: selection.parentId),
      successMessage: '폴더를 옮겼어요.',
    );
  }

  Future<void> _deleteFolder(
    BuildContext context,
    WidgetRef ref,
    Folder folder,
  ) async {
    final viewModel = ref.read(
      folderBrowserViewModelProvider(folderId).notifier,
    );

    try {
      final impact = await viewModel.getDeletionImpact(folder.id);
      if (!context.mounted) return;

      final confirmed = await showFolderDeleteDialog(
        context,
        folder: folder,
        impact: impact,
      );
      if (!confirmed || !context.mounted) return;

      await _runAction(
        context,
        () => viewModel.deleteFolder(folder.id),
        successMessage: '${folder.name} 폴더를 삭제했어요.',
      );
    } catch (error) {
      if (context.mounted) _showMessage(context, _messageFor(error));
    }
  }

  Future<void> _runAction(
    BuildContext context,
    Future<void> Function() action, {
    required String successMessage,
  }) async {
    try {
      await action();
      if (context.mounted) _showMessage(context, successMessage);
    } catch (error) {
      if (context.mounted) _showMessage(context, _messageFor(error));
    }
  }

  static String _messageFor(Object error) {
    return switch (error) {
      AppFailure failure => failure.message,
      _ => '요청을 처리하지 못했어요.',
    };
  }

  static void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _FolderList extends StatelessWidget {
  const _FolderList({
    required this.state,
    required this.onOpen,
    required this.onRename,
    required this.onMove,
    required this.onDelete,
  });

  final FolderBrowserState state;
  final ValueChanged<Folder> onOpen;
  final ValueChanged<Folder> onRename;
  final ValueChanged<Folder> onMove;
  final ValueChanged<Folder> onDelete;

  @override
  Widget build(BuildContext context) {
    if (state.visibleFolders.isEmpty && state.currentFolder == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_open_rounded,
                size: 64,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                '아직 폴더가 없어요.',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('새 폴더를 만들어 문제를 정리해 보세요.'),
            ],
          ),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: CustomScrollView(
          slivers: [
            if (state.visibleFolders.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    '폴더',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final node = state.visibleFolders[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        child: ListTile(
                          leading: const Icon(Icons.folder_rounded),
                          title: Text(node.folder.name),
                          subtitle: Text('하위 폴더 ${node.children.length}개'),
                          onTap: () => onOpen(node.folder),
                          trailing: PopupMenuButton<_FolderAction>(
                            tooltip: '폴더 메뉴',
                            onSelected: (action) {
                              switch (action) {
                                case _FolderAction.rename:
                                  onRename(node.folder);
                                case _FolderAction.move:
                                  onMove(node.folder);
                                case _FolderAction.delete:
                                  onDelete(node.folder);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: _FolderAction.rename,
                                child: Text('이름 변경'),
                              ),
                              PopupMenuItem(
                                value: _FolderAction.move,
                                child: Text('옮기기'),
                              ),
                              PopupMenuItem(
                                value: _FolderAction.delete,
                                child: Text('삭제'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }, childCount: state.visibleFolders.length),
                ),
              ),
            ],
            if (state.currentFolder != null)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: QuestionListView(folderId: state.currentFolder!.id),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 48),
          const SizedBox(height: 12),
          Text(message),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}

enum _FolderAction { rename, move, delete }
