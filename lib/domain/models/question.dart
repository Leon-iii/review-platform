import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/study_source.dart';

class Question {
  const Question({
    required this.id,
    required this.folderId,
    required this.type,
    required this.status,
    required this.prompt,
    required this.choices,
    required this.acceptableAnswers,
    required this.createdAt,
    required this.updatedAt,
    this.explanation,
    this.difficulty = 3,
    this.deletedAt,
    this.sourceReferences = const [],
    this.importance = ConceptImportance.medium,
  });

  final String id;
  final String folderId;
  final QuestionType type;
  final QuestionStatus status;
  final String prompt;
  final String? explanation;
  final int difficulty;
  final List<QuestionChoice> choices;
  final List<AcceptableAnswer> acceptableAnswers;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final List<QuestionSourceReference> sourceReferences;
  final ConceptImportance importance;
  String? get primaryConceptId => sourceReferences
      .where((reference) => reference.conceptId != null)
      .firstOrNull
      ?.conceptId;
  bool get inheritsImportance => primaryConceptId != null;
}

class QuestionChoice {
  const QuestionChoice({
    required this.id,
    required this.position,
    required this.text,
    required this.isCorrect,
  });

  final String id;
  final int position;
  final String text;
  final bool isCorrect;
}

class AcceptableAnswer {
  const AcceptableAnswer({required this.id, required this.text});

  final String id;
  final String text;
}

class QuestionDraft {
  const QuestionDraft({
    required this.folderId,
    required this.type,
    required this.prompt,
    this.choices = const [],
    this.acceptableAnswers = const [],
    this.explanation,
    this.difficulty = 3,
    this.status = QuestionStatus.approved,
    this.importance = ConceptImportance.medium,
  });

  final String folderId;
  final QuestionType type;
  final QuestionStatus status;
  final String prompt;
  final String? explanation;
  final int difficulty;
  final List<QuestionChoiceDraft> choices;
  final List<String> acceptableAnswers;
  final ConceptImportance importance;
}

class QuestionChoiceDraft {
  const QuestionChoiceDraft({required this.text, required this.isCorrect});

  final String text;
  final bool isCorrect;
}
