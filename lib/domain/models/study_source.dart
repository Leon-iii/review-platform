import 'package:review_platform/domain/enums/concept_status.dart';

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
}

class StudyConcept {
  const StudyConcept({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.summary,
    required this.details,
    required this.pageNumbers,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String sourceId;
  final String title;
  final String summary;
  final String details;
  final List<int> pageNumbers;
  final ConceptStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  StudyConcept copyWith({
    String? title,
    String? summary,
    String? details,
    List<int>? pageNumbers,
    ConceptStatus? status,
    DateTime? updatedAt,
  }) {
    return StudyConcept(
      id: id,
      sourceId: sourceId,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      details: details ?? this.details,
      pageNumbers: pageNumbers ?? this.pageNumbers,
      status: status ?? this.status,
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
    final label = '${source.fileName} · p.$pages · ${concept.title}';
    return label.length <= 200 ? label : label.substring(0, 200);
  }

  String get sourceText => [
    concept.title,
    concept.summary,
    concept.details,
  ].where((value) => value.trim().isNotEmpty).join('\n\n');
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
    required this.summary,
    required this.details,
    required this.pageNumbers,
  });

  final String title;
  final String summary;
  final String details;
  final List<int> pageNumbers;
}
