import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';

class QuestionSnapshot {
  const QuestionSnapshot({
    required this.questionId,
    required this.type,
    required this.prompt,
    required this.choices,
    required this.acceptableAnswers,
    this.explanation,
    this.difficulty,
  });

  factory QuestionSnapshot.fromQuestion(Question question) {
    return QuestionSnapshot(
      questionId: question.id,
      type: question.type,
      prompt: question.prompt,
      explanation: question.explanation,
      difficulty: question.difficulty,
      choices: [
        for (final choice in question.choices)
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
  final List<SnapshotChoice> choices;
  final List<String> acceptableAnswers;

  Map<String, Object?> toJson() => {
    'questionId': questionId,
    'type': type.name,
    'prompt': prompt,
    'explanation': explanation,
    'difficulty': difficulty,
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
