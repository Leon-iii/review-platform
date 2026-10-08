import 'dart:async';

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
  final List<List<ConceptRevisionClarification>> histories = [];
  final List<ConceptRevisionResponse> responses = [];
  String? lastInstruction;
  int requestCount = 0;
  Completer<void>? gate;
  Object? error;

  @override
  Future<void> deletePdf({
    required SyncConfiguration configuration,
    required String sourceId,
  }) async {
    deleteCount++;
  }

  @override
  Future<ConceptRevisionResponse> reviseConcepts({
    required SyncConfiguration configuration,
    required StudySource source,
    required List<StudyConcept> concepts,
    required String instruction,
    required Set<String> targetConceptIds,
    bool allowAdditions = false,
    bool allowDeletions = false,
    List<ConceptRevisionClarification> clarifications = const [],
  }) async {
    lastSource = source;
    requestCount++;
    lastInstruction = instruction;
    histories.add(List.of(clarifications));
    lastConcepts = List.of(concepts);
    lastAllowAdditions = allowAdditions;
    lastAllowDeletions = allowDeletions;
    await gate?.future;
    if (error != null) throw error!;
    if (responses.isNotEmpty) return responses.removeAt(0);
    final result =
        changes ??
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
              reason: '요청한 내용을 본문에 반영했습니다.',
            ),
        ];
    return ConceptRevisionResponse(
      status: result.isEmpty
          ? ConceptRevisionStatus.noChanges
          : ConceptRevisionStatus.ready,
      comment: '요청한 범위의 개념을 수정했습니다.',
      clarificationQuestion: '',
      changes: result,
    );
  }
}
