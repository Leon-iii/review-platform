// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quiz_dao.dart';

// ignore_for_file: type=lint
mixin _$QuizDaoMixin on DatabaseAccessor<AppDatabase> {
  $FoldersTable get folders => attachedDatabase.folders;
  $QuizSessionsTable get quizSessions => attachedDatabase.quizSessions;
  $QuestionsTable get questions => attachedDatabase.questions;
  $QuizSessionItemsTable get quizSessionItems =>
      attachedDatabase.quizSessionItems;
  QuizDaoManager get managers => QuizDaoManager(this);
}

class QuizDaoManager {
  final _$QuizDaoMixin _db;
  QuizDaoManager(this._db);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db.attachedDatabase, _db.folders);
  $$QuizSessionsTableTableManager get quizSessions =>
      $$QuizSessionsTableTableManager(_db.attachedDatabase, _db.quizSessions);
  $$QuestionsTableTableManager get questions =>
      $$QuestionsTableTableManager(_db.attachedDatabase, _db.questions);
  $$QuizSessionItemsTableTableManager get quizSessionItems =>
      $$QuizSessionItemsTableTableManager(
        _db.attachedDatabase,
        _db.quizSessionItems,
      );
}
