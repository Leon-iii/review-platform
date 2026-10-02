import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'document_import_view_model.g.dart';

@riverpod
Future<List<StudySource>> documentSources(Ref ref, String folderId) {
  return ref.watch(sourceRepositoryProvider).getSources(folderId);
}

@riverpod
class DocumentImportController extends _$DocumentImportController {
  @override
  FutureOr<StudySourceWithConcepts?> build(String folderId) => null;

  Future<bool> pickAndImport() async {
    try {
      final picked = await ref.read(documentPickerProvider).pickPdf();
      if (picked == null) return false;
      state = const AsyncLoading();
      final configuration = await ref
          .read(syncCredentialsStoreProvider)
          .readConfiguration();
      if (configuration == null) {
        throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
      }
      final result = await ref
          .read(remoteDocumentApiProvider)
          .importPdf(
            configuration: configuration,
            fileName: picked.fileName,
            bytes: picked.bytes,
          );
      final saved = await ref
          .read(sourceRepositoryProvider)
          .saveImport(folderId: folderId, result: result);
      state = AsyncData(saved);
      ref.invalidate(documentSourcesProvider(folderId));
      return true;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      return false;
    }
  }

  Future<void> loadSource(String sourceId) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(sourceRepositoryProvider).getSourceWithConcepts(sourceId),
    );
  }

  Future<void> setApproved(String conceptId, bool approved) async {
    await ref
        .read(sourceRepositoryProvider)
        .setConceptApproval(id: conceptId, approved: approved);
    _updateConcept(
      conceptId,
      (concept) => concept.copyWith(
        status: approved ? ConceptStatus.approved : ConceptStatus.held,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> addConcept({
    required String title,
    required String content,
    required ConceptImportance importance,
    bool reviewed = true,
  }) async {
    final current = state.value;
    if (current == null) {
      throw const ValidationFailure('개념을 추가할 자료를 찾을 수 없어요.');
    }
    final repository = ref.read(sourceRepositoryProvider);
    await repository.addConcept(
      sourceId: current.source.id,
      title: title,
      content: content,
      importance: importance,
      reviewed: reviewed,
    );
    state = AsyncData(
      await repository.getSourceWithConcepts(current.source.id),
    );
  }

  Future<void> updateConcept({
    required String conceptId,
    required String title,
    required String content,
    required ConceptImportance importance,
  }) async {
    await ref
        .read(sourceRepositoryProvider)
        .updateConcept(
          id: conceptId,
          title: title,
          content: content,
          importance: importance,
        );
    _updateConcept(
      conceptId,
      (concept) => concept.copyWith(
        title: title.trim(),
        content: content.trim(),
        importance: importance,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> deleteConcept(String conceptId) async {
    await ref.read(sourceRepositoryProvider).deleteConcept(conceptId);
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      StudySourceWithConcepts(
        source: current.source,
        concepts: current.concepts
            .where((concept) => concept.id != conceptId)
            .toList(growable: false),
      ),
    );
  }

  Future<List<ConceptRevision>> requestConceptRevision({
    required String instruction,
    required Set<String> targetConceptIds,
  }) async {
    final current = state.value;
    if (current == null) {
      throw const ValidationFailure('수정할 자료를 찾을 수 없어요.');
    }
    final normalizedInstruction = instruction.trim();
    if (normalizedInstruction.isEmpty) {
      throw const ValidationFailure('수정 요청사항을 입력해 주세요.');
    }
    if (targetConceptIds.isEmpty) {
      throw const ValidationFailure('수정할 개념을 하나 이상 선택해 주세요.');
    }
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
    }
    return ref
        .read(remoteDocumentApiProvider)
        .reviseConcepts(
          configuration: configuration,
          source: current.source,
          concepts: current.concepts,
          instruction: normalizedInstruction,
          targetConceptIds: targetConceptIds,
        );
  }

  Future<int> applyConceptRevisions(
    List<ConceptRevision> revisions, {
    bool markReviewed = false,
  }) async {
    final current = state.value;
    if (current == null) {
      throw const ValidationFailure('수정할 자료를 찾을 수 없어요.');
    }
    final result = await ref
        .read(sourceRepositoryProvider)
        .applyConceptRevisions(
          sourceId: current.source.id,
          revisions: revisions,
          markReviewed: markReviewed,
        );
    state = AsyncData(result.review);
    return result.changedCount;
  }

  void showImportPrompt() => state = const AsyncData(null);

  void _updateConcept(
    String id,
    StudyConcept Function(StudyConcept concept) update,
  ) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(
      StudySourceWithConcepts(
        source: current.source,
        concepts: [
          for (final concept in current.concepts)
            concept.id == id ? update(concept) : concept,
        ],
      ),
    );
  }
}
