import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';
import 'package:review_platform/domain/services/quiz_builder.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'study_setup_view_model.g.dart';

class StudyFolderOption {
  const StudyFolderOption({required this.folder, required this.depth});

  final Folder folder;
  final int depth;
}

@riverpod
Stream<List<StudyFolderOption>> studyFolderOptions(Ref ref) {
  return ref.watch(folderRepositoryProvider).watchFolderTree().map((roots) {
    final options = <StudyFolderOption>[];

    void visit(FolderNode node, int depth) {
      options.add(StudyFolderOption(folder: node.folder, depth: depth));
      for (final child in node.children) {
        visit(child, depth + 1);
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return List.unmodifiable(options);
  });
}

@riverpod
class StudySetupViewModel extends _$StudySetupViewModel {
  @override
  FutureOr<void> build() {}

  Future<QuizBuildResult> start(QuizFilter filter) async {
    state = const AsyncLoading();
    try {
      final builder = QuizBuilder(
        ref.read(folderRepositoryProvider),
        ref.read(questionRepositoryProvider),
        ref.read(quizRepositoryProvider),
        ref.read(attemptRepositoryProvider),
      );
      final result = await builder.build(filter);
      state = const AsyncData(null);
      return result;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }
}
