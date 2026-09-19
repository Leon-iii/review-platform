import 'package:review_platform/domain/enums/question_type.dart';

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
  });

  final String sourceText;
  final int? questionCount;
  final Set<QuestionType> questionTypes;
  final String? sourceLabel;
  final AiQuestionGenerationMode generationMode;
  final AiQuestionDensity? automaticDensity;

  Map<String, Object?> toJson() => {
    'sourceText': sourceText,
    'questionCount': questionCount,
    'questionTypes': [for (final type in questionTypes) type.name],
    'sourceLabel': sourceLabel,
    'generationMode': generationMode.name,
    'automaticDensity': automaticDensity?.name,
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
    this.explanation,
    this.difficulty,
  });

  final QuestionType type;
  final String prompt;
  final List<AiGeneratedChoice> choices;
  final List<String> acceptableAnswers;
  final String? explanation;
  final int? difficulty;
  final List<String> sourceIds;
}

class AiGeneratedChoice {
  const AiGeneratedChoice({required this.text, required this.isCorrect});

  final String text;
  final bool isCorrect;
}
