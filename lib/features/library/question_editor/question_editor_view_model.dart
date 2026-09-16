import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'question_editor_view_model.g.dart';

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

  Future<void> save(QuestionDraft draft) async {
    final repository = ref.read(questionRepositoryProvider);
    if (questionId == null) {
      await repository.createQuestion(draft);
    } else {
      await repository.updateQuestion(questionId!, draft);
    }
  }
}
