// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'statistics_dao.dart';

// ignore_for_file: type=lint
mixin _$StatisticsDaoMixin on DatabaseAccessor<AppDatabase> {
  $FoldersTable get folders => attachedDatabase.folders;
  $QuestionsTable get questions => attachedDatabase.questions;
  $QuizSessionsTable get quizSessions => attachedDatabase.quizSessions;
  $AttemptsTable get attempts => attachedDatabase.attempts;
  StatisticsDaoManager get managers => StatisticsDaoManager(this);
}

class StatisticsDaoManager {
  final _$StatisticsDaoMixin _db;
  StatisticsDaoManager(this._db);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db.attachedDatabase, _db.folders);
  $$QuestionsTableTableManager get questions =>
      $$QuestionsTableTableManager(_db.attachedDatabase, _db.questions);
  $$QuizSessionsTableTableManager get quizSessions =>
      $$QuizSessionsTableTableManager(_db.attachedDatabase, _db.quizSessions);
  $$AttemptsTableTableManager get attempts =>
      $$AttemptsTableTableManager(_db.attachedDatabase, _db.attempts);
}
