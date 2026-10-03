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
    'sourceText': sourceText,
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
  });

  final AiGenerationMetadata metadata;
  final List<AiGeneratedQuestion> questions;
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
  });

  final QuestionType type;
  final String prompt;
  final List<AiGeneratedChoice> choices;
  final List<String> acceptableAnswers;
  final String? explanation;
  final int difficulty;
  final List<String> sourceIds;
  final String? primaryConceptId;
}

class AiGeneratedChoice {
  const AiGeneratedChoice({required this.text, required this.isCorrect});

  final String text;
  final bool isCorrect;
}
