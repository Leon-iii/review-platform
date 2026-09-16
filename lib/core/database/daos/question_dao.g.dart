// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'question_dao.dart';

// ignore_for_file: type=lint
mixin _$QuestionDaoMixin on DatabaseAccessor<AppDatabase> {
  $FoldersTable get folders => attachedDatabase.folders;
  $QuestionsTable get questions => attachedDatabase.questions;
  $QuestionChoicesTable get questionChoices => attachedDatabase.questionChoices;
  $AcceptableAnswersTable get acceptableAnswers =>
      attachedDatabase.acceptableAnswers;
  QuestionDaoManager get managers => QuestionDaoManager(this);
}

class QuestionDaoManager {
  final _$QuestionDaoMixin _db;
  QuestionDaoManager(this._db);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db.attachedDatabase, _db.folders);
  $$QuestionsTableTableManager get questions =>
      $$QuestionsTableTableManager(_db.attachedDatabase, _db.questions);
  $$QuestionChoicesTableTableManager get questionChoices =>
      $$QuestionChoicesTableTableManager(
        _db.attachedDatabase,
        _db.questionChoices,
      );
  $$AcceptableAnswersTableTableManager get acceptableAnswers =>
      $$AcceptableAnswersTableTableManager(
        _db.attachedDatabase,
        _db.acceptableAnswers,
      );
}
