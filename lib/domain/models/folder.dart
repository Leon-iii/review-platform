class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.parentId,
    this.deletedAt,
  });

  final String id;
  final String? parentId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

class FolderNode {
  const FolderNode({required this.folder, required this.children});

  final Folder folder;
  final List<FolderNode> children;
}

class FolderDeletionImpact {
  const FolderDeletionImpact({
    required this.descendantFolderCount,
    required this.questionCount,
  });

  final int descendantFolderCount;
  final int questionCount;
}
