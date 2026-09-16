import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'folder_browser_view_model.g.dart';

class FolderBrowserState {
  const FolderBrowserState({
    required this.currentFolder,
    required this.visibleFolders,
    required this.allFolders,
  });

  factory FolderBrowserState.fromTree(
    List<FolderNode> roots,
    String? currentFolderId,
  ) {
    final flattened = <Folder>[];
    FolderNode? currentNode;

    void visit(FolderNode node) {
      flattened.add(node.folder);
      if (node.folder.id == currentFolderId) currentNode = node;
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }

    if (currentFolderId != null && currentNode == null) {
      throw const ValidationFailure('폴더를 찾을 수 없어요.');
    }

    return FolderBrowserState(
      currentFolder: currentNode?.folder,
      visibleFolders: currentNode?.children ?? roots,
      allFolders: List.unmodifiable(flattened),
    );
  }

  final Folder? currentFolder;
  final List<FolderNode> visibleFolders;
  final List<Folder> allFolders;

  List<Folder> moveTargetsFor(String folderId) {
    final excludedIds = <String>{folderId};

    void collectDescendants(FolderNode node) {
      if (node.folder.id == folderId ||
          excludedIds.contains(node.folder.parentId)) {
        excludedIds.add(node.folder.id);
      }
      for (final child in node.children) {
        collectDescendants(child);
      }
    }

    for (final node in visibleFolders) {
      collectDescendants(node);
    }

    return allFolders
        .where((folder) => !excludedIds.contains(folder.id))
        .toList(growable: false);
  }
}

@riverpod
class FolderBrowserViewModel extends _$FolderBrowserViewModel {
  @override
  Stream<FolderBrowserState> build(String? folderId) {
    return ref
        .watch(folderRepositoryProvider)
        .watchFolderTree()
        .map((tree) => FolderBrowserState.fromTree(tree, folderId));
  }

  Future<void> createFolder(String name) {
    return ref
        .read(folderRepositoryProvider)
        .createFolder(name: name, parentId: folderId);
  }

  Future<void> renameFolder({required String id, required String name}) {
    return ref.read(folderRepositoryProvider).renameFolder(id: id, name: name);
  }

  Future<void> moveFolder({required String id, String? parentId}) {
    return ref
        .read(folderRepositoryProvider)
        .moveFolder(id: id, parentId: parentId);
  }

  Future<FolderDeletionImpact> getDeletionImpact(String id) {
    return ref.read(folderRepositoryProvider).getDeletionImpact(id);
  }

  Future<void> deleteFolder(String id) {
    return ref.read(folderRepositoryProvider).deleteFolder(id);
  }
}
