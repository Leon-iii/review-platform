import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';

class StudySource {
  const StudySource({
    required this.id,
    required this.folderId,
    required this.fileName,
    required this.contentHash,
    required this.pageCount,
    required this.extractionMethod,
    required this.importedAt,
  });

  final String id;
  final String folderId;
  final String fileName;
  final String contentHash;
  final int pageCount;
  final String extractionMethod;
  final DateTime importedAt;

  bool get isManual => extractionMethod == 'manual';
}

class StudyConcept {
  const StudyConcept({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.content,
    required this.pageNumbers,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.importance = ConceptImportance.medium,
  });

  final String id;
  final String sourceId;
  final String title;
  final String content;
  final List<int> pageNumbers;
  final ConceptStatus status;
  final ConceptImportance importance;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Empty pages mean content without PDF provenance, whether manual or AI-added.
  bool get hasPageSource => pageNumbers.isNotEmpty;

  StudyConcept copyWith({
    String? title,
    String? content,
    List<int>? pageNumbers,
    ConceptStatus? status,
    ConceptImportance? importance,
    DateTime? updatedAt,
  }) {
    return StudyConcept(
      id: id,
      sourceId: sourceId,
      title: title ?? this.title,
      content: content ?? this.content,
      pageNumbers: pageNumbers ?? this.pageNumbers,
      status: status ?? this.status,
      importance: importance ?? this.importance,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class StudySourceWithConcepts {
  const StudySourceWithConcepts({required this.source, required this.concepts});

  final StudySource source;
  final List<StudyConcept> concepts;
}

enum ConceptChangeKind { update, add, delete }

class ConceptRevision {
  const ConceptRevision({
    required this.id,
    required this.title,
    required this.content,
    required this.pageNumbers,
    required this.importance,
    this.kind = ConceptChangeKind.update,
    this.groupId = '',
    this.reason = '',
  });

  final String id;
  final String title;
  final String content;
  final List<int> pageNumbers;
  final ConceptImportance importance;
  final ConceptChangeKind kind;
  final String groupId;
  final String reason;
}

class ConceptRevisionProposal {
  const ConceptRevisionProposal({
    required this.original,
    required this.changes,
    required this.targetConceptIds,
    required this.allowAdditions,
    required this.allowDeletions,
  });

  final StudySourceWithConcepts original;
  final List<ConceptRevision> changes;
  final Set<String> targetConceptIds;
  final bool allowAdditions;
  final bool allowDeletions;
}

class ConceptRevisionApplyResult {
  const ConceptRevisionApplyResult({
    required this.review,
    required this.changedCount,
  });

  final StudySourceWithConcepts review;
  final int changedCount;
}

class ConceptGenerationSeed {
  const ConceptGenerationSeed({
    required this.folderId,
    required this.source,
    required this.concept,
  });

  final String folderId;
  final StudySource source;
  final StudyConcept concept;

  String get sourceLabel {
    final pages = concept.pageNumbers.join(', ');
    final label =
        '${source.fileName}'
        '${concept.hasPageSource ? ' · p.$pages' : ''} · ${concept.title}';
    return label.length <= 200 ? label : label.substring(0, 200);
  }

  String get sourceText => [
    concept.title,
    concept.content,
  ].where((value) => value.trim().isNotEmpty).join('\n\n');
}

class SourceGenerationSeed {
  const SourceGenerationSeed({required this.source, required this.concepts});

  final StudySource source;
  final List<StudyConcept> concepts;

  String get folderId => source.folderId;
  String get sourceLabel => source.fileName.length <= 200
      ? source.fileName
      : source.fileName.substring(0, 200);
  String get sourceText => [
    for (var index = 0; index < concepts.length; index++)
      '${index + 1}. ${concepts[index].title}\n'
          '${concepts[index].hasPageSource ? '페이지: ${concepts[index].pageNumbers.join(', ')}\n' : ''}'
          '${concepts[index].content}',
  ].join('\n\n');

  // Request-level provenance only. Structured generation maps each returned
  // question to its validated primary concept and that concept's own pages.
  // Legacy/free-text responses must not be assigned an arbitrary concept.
  QuestionSourceDraft get sourceReference => QuestionSourceDraft(
    sourceId: source.id,
    pageNumbers: {
      for (final concept in concepts) ...concept.pageNumbers,
    }.toList()..sort(),
  );
}

class QuestionSourceDraft {
  const QuestionSourceDraft({
    required this.sourceId,
    required this.pageNumbers,
    this.conceptId,
  });

  final String sourceId;
  final String? conceptId;
  final List<int> pageNumbers;
}

class QuestionSourceReference {
  const QuestionSourceReference({
    required this.sourceId,
    required this.fileName,
    required this.pageNumbers,
    this.conceptId,
    this.conceptTitle,
  });

  final String sourceId;
  final String fileName;
  final String? conceptId;
  final String? conceptTitle;
  final List<int> pageNumbers;
}

class DocumentImportResult {
  const DocumentImportResult({required this.source, required this.concepts});

  final ImportedSource source;
  final List<ImportedConcept> concepts;
}

class ImportedSource {
  const ImportedSource({
    required this.id,
    required this.fileName,
    required this.contentHash,
    required this.pageCount,
    required this.extractionMethod,
    required this.importedAt,
  });

  final String id;
  final String fileName;
  final String contentHash;
  final int pageCount;
  final String extractionMethod;
  final DateTime importedAt;
}

class ImportedConcept {
  const ImportedConcept({
    required this.title,
    required this.content,
    required this.pageNumbers,
    this.importance = ConceptImportance.medium,
  });

  final String title;
  final String content;
  final List<int> pageNumbers;
  final ConceptImportance importance;
}
