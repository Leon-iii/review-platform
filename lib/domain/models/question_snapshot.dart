import 'dart:math';

import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_answer_format.dart';

class QuestionSnapshot {
  const QuestionSnapshot({
    required this.questionId,
    required this.type,
    required this.prompt,
    required this.choices,
    required this.acceptableAnswers,
    this.explanation,
    this.difficulty,
    this.caseSensitive = false,
    this.whitespaceSensitive = false,
    this.correctChoiceIds = const [],
  });

  factory QuestionSnapshot.fromQuestion(Question question, {Random? random}) {
    final displayChoices = [...question.choices];
    if (question.type == QuestionType.ordering) {
      displayChoices.shuffle(random ?? Random());
      // Do not begin with the answer already laid out in its correct sequence.
      if (displayChoices.length > 1 &&
          displayChoices.map((c) => c.id).join(',') ==
              question.correctChoiceIds.join(',')) {
        displayChoices.add(displayChoices.removeAt(0));
      }
    }
    return QuestionSnapshot(
      questionId: question.id,
      type: question.type,
      prompt: question.prompt,
      explanation: question.explanation,
      difficulty: question.difficulty,
      caseSensitive: question.caseSensitive,
      whitespaceSensitive: question.whitespaceSensitive,
      correctChoiceIds: List.unmodifiable(question.correctChoiceIds),
      choices: [
        for (final choice in displayChoices)
          SnapshotChoice(
            id: choice.id,
            text: choice.text,
            isCorrect: choice.isCorrect,
          ),
      ],
      acceptableAnswers: [
        for (final answer in question.acceptableAnswers) answer.text,
      ],
    );
  }

  factory QuestionSnapshot.fromJson(Map<String, Object?> json) {
    return QuestionSnapshot(
      questionId: json['questionId']! as String,
      type: QuestionType.fromStorage(json['type']! as String),
      prompt: json['prompt']! as String,
      explanation: json['explanation'] as String?,
      difficulty: json['difficulty'] as int?,
      caseSensitive: json['caseSensitive'] as bool? ?? false,
      whitespaceSensitive: json['whitespaceSensitive'] as bool? ?? false,
      correctChoiceIds: List.unmodifiable(
        (json['correctChoiceIds'] as List? ?? const []).cast<String>(),
      ),
      choices: [
        for (final choice in json['choices']! as List)
          SnapshotChoice.fromJson(Map<String, Object?>.from(choice as Map)),
      ],
      acceptableAnswers: [
        for (final answer in json['acceptableAnswers']! as List)
          answer as String,
      ],
    );
  }

  final String questionId;
  final QuestionType type;
  final String prompt;
  final String? explanation;
  final int? difficulty;
  final bool caseSensitive;
  final bool whitespaceSensitive;
  final List<String> correctChoiceIds;
  final List<SnapshotChoice> choices;
  final List<String> acceptableAnswers;

  Map<String, Object?> toJson() => {
    'questionId': questionId,
    'type': type.name,
    'correctChoiceIds': correctChoiceIds,
    'answerFormatVersion': QuestionAnswerFormat.version,
    'prompt': prompt,
    'explanation': explanation,
    'difficulty': difficulty,
    'caseSensitive': caseSensitive,
    'whitespaceSensitive': whitespaceSensitive,
    'choices': [for (final choice in choices) choice.toJson()],
    'acceptableAnswers': acceptableAnswers,
  };
}

class SnapshotChoice {
  const SnapshotChoice({
    required this.id,
    required this.text,
    required this.isCorrect,
  });

  factory SnapshotChoice.fromJson(Map<String, Object?> json) {
    return SnapshotChoice(
      id: json['id']! as String,
      text: json['text']! as String,
      isCorrect: json['isCorrect']! as bool,
    );
  }

  final String id;
  final String text;
  final bool isCorrect;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'isCorrect': isCorrect,
  };
}
