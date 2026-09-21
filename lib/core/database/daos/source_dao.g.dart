// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'source_dao.dart';

// ignore_for_file: type=lint
mixin _$SourceDaoMixin on DatabaseAccessor<AppDatabase> {
  $FoldersTable get folders => attachedDatabase.folders;
  $StudySourcesTable get studySources => attachedDatabase.studySources;
  $ConceptsTable get concepts => attachedDatabase.concepts;
  $QuestionsTable get questions => attachedDatabase.questions;
  $QuestionSourcesTable get questionSources => attachedDatabase.questionSources;
  SourceDaoManager get managers => SourceDaoManager(this);
}

class SourceDaoManager {
  final _$SourceDaoMixin _db;
  SourceDaoManager(this._db);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db.attachedDatabase, _db.folders);
  $$StudySourcesTableTableManager get studySources =>
      $$StudySourcesTableTableManager(_db.attachedDatabase, _db.studySources);
  $$ConceptsTableTableManager get concepts =>
      $$ConceptsTableTableManager(_db.attachedDatabase, _db.concepts);
  $$QuestionsTableTableManager get questions =>
      $$QuestionsTableTableManager(_db.attachedDatabase, _db.questions);
  $$QuestionSourcesTableTableManager get questionSources =>
      $$QuestionSourcesTableTableManager(
        _db.attachedDatabase,
        _db.questionSources,
      );
}
