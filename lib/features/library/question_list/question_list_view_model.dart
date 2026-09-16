import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'question_list_view_model.g.dart';

@riverpod
class QuestionListViewModel extends _$QuestionListViewModel {
  @override
  Stream<List<Question>> build(String folderId) {
    return ref.watch(questionRepositoryProvider).watchQuestions(folderId);
  }

  Future<void> deleteQuestion(String id) {
    return ref.read(questionRepositoryProvider).deleteQuestion(id);
  }
}
