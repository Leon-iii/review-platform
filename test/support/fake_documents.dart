import 'package:review_platform/core/documents/remote_document_api.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

class FakeConceptRevisionApi implements RemoteDocumentApi {
  StudySource? lastSource;
  List<StudyConcept>? lastConcepts;
  int deleteCount = 0;
  bool lastAllowAdditions = false;
  bool lastAllowDeletions = false;
  List<ConceptRevision>? changes;

  @override
  Future<void> deletePdf({
    required SyncConfiguration configuration,
    required String sourceId,
  }) async {
    deleteCount++;
  }

  @override
  Future<List<ConceptRevision>> reviseConcepts({
    required SyncConfiguration configuration,
    required StudySource source,
    required List<StudyConcept> concepts,
    required String instruction,
    required Set<String> targetConceptIds,
    bool allowAdditions = false,
    bool allowDeletions = false,
  }) async {
    lastSource = source;
    lastConcepts = List.of(concepts);
    lastAllowAdditions = allowAdditions;
    lastAllowDeletions = allowDeletions;
    return changes ??
        [
          for (final concept in concepts.where(
            (concept) => targetConceptIds.contains(concept.id),
          ))
            ConceptRevision(
              id: concept.id,
              title: concept.title,
              content: '${concept.content} 테스트 추가',
              pageNumbers: concept.pageNumbers,
              importance: concept.importance,
            ),
        ];
  }
}
