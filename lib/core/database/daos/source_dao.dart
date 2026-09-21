import 'package:drift/drift.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/database/tables/concepts.dart';
import 'package:review_platform/core/database/tables/question_sources.dart';
import 'package:review_platform/core/database/tables/study_sources.dart';

part 'source_dao.g.dart';

@DriftAccessor(tables: [StudySources, Concepts, QuestionSources])
class SourceDao extends DatabaseAccessor<AppDatabase> with _$SourceDaoMixin {
  SourceDao(super.attachedDatabase);

  Stream<List<StudySourceRow>> watchSources(String folderId) {
    return (select(studySources)
          ..where((source) => source.folderId.equals(folderId))
          ..orderBy([(source) => OrderingTerm.desc(source.importedAt)]))
        .watch();
  }

  Future<StudySourceRow?> getSource(String id) {
    return (select(
      studySources,
    )..where((source) => source.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertSource(StudySourcesCompanion source) {
    return into(studySources).insert(source);
  }

  Future<void> upsertSource(StudySourcesCompanion source) {
    return into(studySources).insertOnConflictUpdate(source);
  }

  Stream<List<ConceptRow>> watchConcepts(String sourceId) {
    return (select(concepts)
          ..where((concept) => concept.sourceId.equals(sourceId))
          ..orderBy([(concept) => OrderingTerm.asc(concept.createdAt)]))
        .watch();
  }

  Future<List<ConceptRow>> getConcepts(String sourceId) {
    return (select(concepts)
          ..where((concept) => concept.sourceId.equals(sourceId))
          ..orderBy([(concept) => OrderingTerm.asc(concept.createdAt)]))
        .get();
  }

  Future<ConceptRow?> getConcept(String id) {
    return (select(
      concepts,
    )..where((concept) => concept.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertConcepts(List<ConceptsCompanion> values) {
    return batch((batch) => batch.insertAll(concepts, values));
  }

  Future<void> upsertConcept(ConceptsCompanion value) {
    return into(concepts).insertOnConflictUpdate(value);
  }

  Future<void> updateConcept(String id, ConceptsCompanion value) {
    return (update(
      concepts,
    )..where((concept) => concept.id.equals(id))).write(value);
  }

  Future<void> insertQuestionSource(QuestionSourcesCompanion value) {
    return into(questionSources).insert(value);
  }

  Future<List<QuestionSourceRow>> getQuestionSources(String questionId) {
    return (select(
      questionSources,
    )..where((source) => source.questionId.equals(questionId))).get();
  }

  Future<void> replaceQuestionSources(
    String questionId,
    List<QuestionSourcesCompanion> values,
  ) async {
    await (delete(
      questionSources,
    )..where((source) => source.questionId.equals(questionId))).go();
    await batch((batch) => batch.insertAll(questionSources, values));
  }
}
