import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'question_editor_view_model.g.dart';

class QuestionConceptOption {
  const QuestionConceptOption({
    required this.source,
    required this.concept,
    required this.folderPath,
  });
  final StudySource source;
  final StudyConcept concept;
  final String folderPath;
  String get label => '${source.fileName} · ${concept.title}';
}

@riverpod
class QuestionEditorViewModel extends _$QuestionEditorViewModel {
  @override
  Future<Question?> build(String? questionId) async {
    if (questionId == null) return null;

    final question = await ref
        .watch(questionRepositoryProvider)
        .getQuestion(questionId);
    if (question == null) {
      throw const ValidationFailure('문제를 찾을 수 없어요.');
    }
    return question;
  }

  Future<void> save(
    QuestionDraft draft, {
    String? primaryConceptId,
    bool replacePrimaryConcept = false,
    ConceptImportance? detachedImportance,
  }) async {
    final repository = ref.read(questionRepositoryProvider);
    if (questionId == null) {
      await repository.createQuestion(
        draft,
        primaryConceptId: primaryConceptId,
      );
    } else {
      await repository.updateQuestion(
        questionId!,
        draft,
        primaryConceptId: primaryConceptId,
        replacePrimaryConcept: replacePrimaryConcept,
        detachedImportance: detachedImportance,
      );
    }
  }

  Future<List<QuestionConceptOption>> loadConceptOptions() async {
    final folders = ref.read(folderRepositoryProvider);
    final repository = ref.read(sourceRepositoryProvider);
    final roots = await folders.watchFolderTree().first;
    final paths = <String, String>{};
    void visit(FolderNode node, String parent) {
      final path = parent.isEmpty
          ? node.folder.name
          : '$parent / ${node.folder.name}';
      paths[node.folder.id] = path;
      for (final child in node.children) {
        visit(child, path);
      }
    }

    for (final root in roots) {
      visit(root, '');
    }
    final options = <QuestionConceptOption>[];
    for (final entry in paths.entries) {
      for (final source in await repository.getSources(entry.key)) {
        final contents = await repository.getSourceWithConcepts(source.id);
        for (final concept in contents.concepts) {
          options.add(
            QuestionConceptOption(
              source: source,
              concept: concept,
              folderPath: entry.value,
            ),
          );
        }
      }
    }
    return List.unmodifiable(options);
  }
}
