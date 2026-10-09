import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/study_source.dart';

enum AiQuestionGenerationMode { automatic, manual }

enum AiQuestionDensity { low, medium, high }

class AiQuestionGenerationRequest {
  const AiQuestionGenerationRequest({
    required this.sourceText,
    required this.questionTypes,
    this.sourceLabel,
    this.generationMode = AiQuestionGenerationMode.manual,
    this.automaticDensity,
    this.questionCount = 10,
    this.minimumDifficulty = 1,
    this.maximumDifficulty = 5,
    this.concepts = const [],
    this.reflectConceptImportance = false,
  });

  final String sourceText;
  final int? questionCount;
  final Set<QuestionType> questionTypes;
  final String? sourceLabel;
  final AiQuestionGenerationMode generationMode;
  final AiQuestionDensity? automaticDensity;
  final int minimumDifficulty;
  final int maximumDifficulty;
  final List<StudyConcept> concepts;
  final bool reflectConceptImportance;

  Map<String, Object?> toJson() => {
    if (concepts.isEmpty) 'sourceText': sourceText,
    'questionCount': questionCount,
    'questionTypes': [for (final type in questionTypes) type.name],
    'sourceLabel': sourceLabel,
    'generationMode': generationMode.name,
    'automaticDensity': automaticDensity?.name,
    'minimumDifficulty': minimumDifficulty,
    'maximumDifficulty': maximumDifficulty,
    'reflectConceptImportance': reflectConceptImportance,
    'concepts': [
      for (final concept in concepts)
        {
          'id': concept.id,
          'title': concept.title,
          'content': concept.content,
          'importance': concept.importance.name,
        },
    ],
  };
}

class AiQuestionGenerationResult {
  const AiQuestionGenerationResult({
    required this.metadata,
    required this.questions,
    this.failures = const [],
    this.warnings = const [],
  });

  final AiGenerationMetadata metadata;
  final List<AiGeneratedQuestion> questions;
  final List<AiConceptGenerationFailure> failures;
  final List<String> warnings;
}

class AiConceptGenerationFailure {
  const AiConceptGenerationFailure({
    required this.conceptId,
    required this.title,
    required this.error,
  });
  final String conceptId;
  final String title;
  final String error;
}

class AiGenerationProgress {
  const AiGenerationProgress({
    required this.completedConcepts,
    required this.totalConcepts,
    required this.generatedQuestions,
    this.conceptTitle,
    required this.failedConcepts,
  });
  final int completedConcepts;
  final int totalConcepts;
  final int generatedQuestions;
  final String? conceptTitle;
  final int failedConcepts;
  int get successfulConcepts => completedConcepts - failedConcepts;
  int get currentConceptNumber =>
      conceptTitle != null && completedConcepts < totalConcepts
      ? completedConcepts + 1
      : completedConcepts;
}

class AiGenerationMetadata {
  const AiGenerationMetadata({
    required this.generationId,
    required this.provider,
    required this.model,
    required this.promptVersion,
    required this.requestedAt,
    required this.inputHash,
    this.sourceLabel,
  });

  final String generationId;
  final String provider;
  final String model;
  final String promptVersion;
  final DateTime requestedAt;
  final String inputHash;
  final String? sourceLabel;
}

class AiGeneratedQuestion {
  const AiGeneratedQuestion({
    required this.type,
    required this.prompt,
    required this.choices,
    required this.acceptableAnswers,
    required this.sourceIds,
    required this.difficulty,
    this.explanation,
    this.primaryConceptId,
    this.correctOrder = const [],
  });

  final QuestionType type;
  final String prompt;
  final List<AiGeneratedChoice> choices;
  final List<String> acceptableAnswers;
  final String? explanation;
  final int difficulty;
  final List<String> sourceIds;
  final String? primaryConceptId;
  final List<int> correctOrder;
}

class AiGeneratedChoice {
  const AiGeneratedChoice({required this.text, required this.isCorrect});

  final String text;
  final bool isCorrect;
}
