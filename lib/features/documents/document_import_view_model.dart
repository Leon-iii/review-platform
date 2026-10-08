import 'package:review_platform/core/documents/document_picker.dart';
import 'package:review_platform/core/documents/document_providers.dart';
import 'package:review_platform/core/documents/document_job_providers.dart';
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
  bool _importInProgress = false;
  String? activeJobId;
  @override
  FutureOr<StudySourceWithConcepts?> build(String folderId) => null;

  Future<bool> pickAndImport() async {
    if (_importInProgress) return false;
    _importInProgress = true;
    try {
      final picked = await ref.read(documentPickerProvider).pickPdf();
      if (picked == null) return false;
      return await _importDocument(picked);
    } catch (error, stackTrace) {
      if (ref.mounted) state = AsyncError(error, stackTrace);
      return false;
    } finally {
      _importInProgress = false;
    }
  }

  Future<bool> importPdf(PickedPdfDocument document) async {
    if (_importInProgress) return false;
    _importInProgress = true;
    try {
      return await _importDocument(document);
    } catch (error, stackTrace) {
      if (ref.mounted) state = AsyncError(error, stackTrace);
      return false;
    } finally {
      _importInProgress = false;
    }
  }

  Future<bool> _importDocument(PickedPdfDocument picked) async {
    picked.validate();
    state = const AsyncLoading();
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
    }
    if (!ref.mounted) return false;
    final coordinator = ref.read(documentJobCoordinatorProvider);
    if (coordinator != null) {
      final jobId = await coordinator.upload(folderId, picked);
      if (!ref.mounted) return true;
      activeJobId = jobId;
      state = const AsyncData(null);
      return true;
    }
    throw const ValidationFailure('PDF 직접 추출을 지원하는 서버 연결이 필요해요.');
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
    if (!ref.mounted) return;
    _updateConcept(
      conceptId,
      (concept) => concept.copyWith(
        status: approved ? ConceptStatus.approved : ConceptStatus.held,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> setImportance(
    String conceptId,
    ConceptImportance importance,
  ) async {
    await ref
        .read(sourceRepositoryProvider)
        .setConceptImportance(id: conceptId, importance: importance);
    if (!ref.mounted) return;
    _updateConcept(
      conceptId,
      (concept) => concept.copyWith(
        importance: importance,
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

  Future<ConceptRevisionProposal> requestConceptRevision({
    required String instruction,
    required Set<String> targetConceptIds,
    bool allowAdditions = false,
    bool allowDeletions = false,
    List<ConceptRevisionClarification> clarifications = const [],
    StudySourceWithConcepts? expectedSnapshot,
  }) async {
    final current = state.value;
    if (current == null) {
      throw const ValidationFailure('수정할 자료를 찾을 수 없어요.');
    }
    final normalizedInstruction = instruction.trim();
    if (normalizedInstruction.isEmpty) {
      throw const ValidationFailure('수정 요청사항을 입력해 주세요.');
    }
    if (targetConceptIds.isEmpty && !allowAdditions) {
      throw const ValidationFailure('수정할 개념을 하나 이상 선택해 주세요.');
    }
    final configuration = await ref
        .read(syncCredentialsStoreProvider)
        .readConfiguration();
    if (configuration == null) {
      throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
    }
    // Read a database snapshot, not optimistic in-memory timestamps, for the
    // later compare-and-apply check while the provider is running.
    final latest = await ref
        .read(sourceRepositoryProvider)
        .getSourceWithConcepts(current.source.id);
    final original = expectedSnapshot ?? latest;
    if (expectedSnapshot != null &&
        (original.source.id != latest.source.id ||
            original.source.contentHash != latest.source.contentHash ||
            original.concepts.length != latest.concepts.length ||
            original.concepts.any(
              (item) => !latest.concepts.any(
                (other) =>
                    item.id == other.id &&
                    item.title == other.title &&
                    item.content == other.content &&
                    item.updatedAt == other.updatedAt &&
                    item.status == other.status &&
                    item.importance == other.importance &&
                    item.pageNumbers.join(',') == other.pageNumbers.join(','),
              ),
            ))) {
      throw const ValidationFailure('확인 답변 중 개념이 변경됐어요. 요청을 다시 작성해 주세요.');
    }
    if (original.concepts.any(
      (item) => targetConceptIds.contains(item.id) && item.hasPageSource,
    )) {
      final job = await ref
          .read(documentJobRepositoryProvider)
          .get(original.source.id);
      if (job != null &&
          job.serverUrl.replaceFirst(RegExp(r'/+$'), '') !=
              configuration.serverUrl.replaceFirst(RegExp(r'/+$'), '')) {
        throw const ValidationFailure('자료를 업로드한 원본 PDF 서버에 연결해 주세요.');
      }
    }
    final response = await ref
        .read(remoteDocumentApiProvider)
        .reviseConcepts(
          configuration: configuration,
          source: original.source,
          concepts: original.concepts,
          instruction: normalizedInstruction,
          targetConceptIds: targetConceptIds,
          allowAdditions: allowAdditions,
          allowDeletions: allowDeletions,
          clarifications: clarifications,
        );
    return ConceptRevisionProposal(
      original: original,
      changes: response.changes,
      status: response.status,
      comment: response.comment,
      clarificationQuestion: response.clarificationQuestion,
      targetConceptIds: Set.unmodifiable(targetConceptIds),
      allowAdditions: allowAdditions,
      allowDeletions: allowDeletions,
    );
  }

  Future<int> applyConceptRevisions(
    ConceptRevisionProposal proposal,
    List<ConceptRevision> revisions, {
    bool markReviewed = false,
  }) async {
    final current = state.value;
    if (current == null) {
      throw const ValidationFailure('수정할 자료를 찾을 수 없어요.');
    }
    if (proposal.status != ConceptRevisionStatus.ready ||
        current.source.id != proposal.original.source.id ||
        revisions.any((item) => !proposal.changes.contains(item))) {
      throw const ValidationFailure('적용할 개념 변경안이 올바르지 않아요.');
    }
    final result = await ref
        .read(sourceRepositoryProvider)
        .applyConceptRevisions(
          sourceId: current.source.id,
          revisions: revisions,
          markReviewed: markReviewed,
          expectedConcepts: proposal.original.concepts,
          allChanges: proposal.changes,
          editableConceptIds: proposal.targetConceptIds,
          allowAdditions: proposal.allowAdditions,
          allowDeletions: proposal.allowDeletions,
        );
    state = AsyncData(result.review);
    return result.changedCount;
  }

  void showImportPrompt() {
    activeJobId = null;
    state = const AsyncData(null);
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
