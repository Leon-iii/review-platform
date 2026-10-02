import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
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

  Future<void> approveQuestion(String id) {
    return ref.read(questionRepositoryProvider).approveQuestion(id);
  }

  Future<void> moveQuestion({required String id, required String folderId}) {
    return ref
        .read(questionRepositoryProvider)
        .moveQuestion(id: id, folderId: folderId);
  }

  Future<void> moveSource({required String id, required String folderId}) {
    return ref
        .read(sourceRepositoryProvider)
        .moveSource(id: id, folderId: folderId);
  }

  Future<void> renameSource({required String id, required String fileName}) {
    return ref
        .read(sourceRepositoryProvider)
        .renameSource(id: id, fileName: fileName);
  }

  Future<void> deleteSource(String id) async {
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
    }
    await ref
        .read(remoteDocumentApiProvider)
        .deletePdf(configuration: configuration, sourceId: id);
    await ref.read(sourceRepositoryProvider).deleteSource(id);
  }
}
