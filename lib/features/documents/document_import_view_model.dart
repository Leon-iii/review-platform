import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'document_import_view_model.g.dart';

@riverpod
Stream<List<StudySource>> documentSources(Ref ref, String folderId) {
  return ref.watch(sourceRepositoryProvider).watchSources(folderId);
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

  Future<void> approve(String conceptId) =>
      _changeStatus(conceptId, ConceptStatus.approved);

  Future<void> hold(String conceptId) =>
      _changeStatus(conceptId, ConceptStatus.held);

  Future<void> reject(String conceptId) =>
      _changeStatus(conceptId, ConceptStatus.rejected);

  Future<void> updateAndApprove({
    required String conceptId,
    required String title,
    required String summary,
    required String details,
  }) async {
    await ref
        .read(sourceRepositoryProvider)
        .updateAndApproveConcept(
          id: conceptId,
          title: title,
          summary: summary,
          details: details,
        );
    _updateConcept(
      conceptId,
      (concept) => concept.copyWith(
        title: title.trim(),
        summary: summary.trim(),
        details: details.trim(),
        status: ConceptStatus.approved,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  void showSourceList() => state = const AsyncData(null);

  Future<void> _changeStatus(String conceptId, ConceptStatus status) async {
    final repository = ref.read(sourceRepositoryProvider);
    switch (status) {
      case ConceptStatus.approved:
        await repository.approveConcept(conceptId);
      case ConceptStatus.held:
        await repository.holdConcept(conceptId);
      case ConceptStatus.rejected:
        await repository.rejectConcept(conceptId);
      case ConceptStatus.draft:
        throw StateError('Draft is not an action status.');
    }
    _updateConcept(
      conceptId,
      (concept) =>
          concept.copyWith(status: status, updatedAt: DateTime.now().toUtc()),
    );
  }

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
