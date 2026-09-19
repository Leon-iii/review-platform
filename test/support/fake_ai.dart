import 'dart:async';

import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

class FakeRemoteAiApi implements RemoteAiApi {
  int callCount = 0;
  Completer<void>? gate;

  @override
  Future<AiQuestionGenerationResult> generateQuestions({
    required SyncConfiguration configuration,
    required AiQuestionGenerationRequest request,
  }) async {
    callCount++;
    await gate?.future;
    final types = request.questionTypes.toList(growable: false);
    final questionCount =
        request.questionCount ??
        switch (request.automaticDensity ?? AiQuestionDensity.medium) {
          AiQuestionDensity.low => 2,
          AiQuestionDensity.medium => 4,
          AiQuestionDensity.high => 6,
        };
    return AiQuestionGenerationResult(
      metadata: AiGenerationMetadata(
        generationId: 'generation-1',
        provider: 'fake',
        model: 'fake-model',
        promptVersion: 'question-generation-v1',
        requestedAt: DateTime.utc(2026, 9, 17),
        inputHash: List.filled(64, 'a').join(),
        sourceLabel: request.sourceLabel,
      ),
      questions: [
        for (var index = 0; index < questionCount; index++)
          _question(types[index % types.length], index),
      ],
    );
  }

  AiGeneratedQuestion _question(QuestionType type, int index) {
    if (type == QuestionType.multipleChoice) {
      return AiGeneratedQuestion(
        type: type,
        prompt: '생성된 객관식 문제 ${index + 1}',
        choices: const [
          AiGeneratedChoice(text: '정답', isCorrect: true),
          AiGeneratedChoice(text: '오답', isCorrect: false),
        ],
        acceptableAnswers: const [],
        sourceIds: const [],
        explanation: '생성된 해설',
        difficulty: 2,
      );
    }
    if (type == QuestionType.trueFalse) {
      return AiGeneratedQuestion(
        type: type,
        prompt: '생성된 O/X 문제 ${index + 1}',
        choices: const [
          AiGeneratedChoice(text: 'O', isCorrect: true),
          AiGeneratedChoice(text: 'X', isCorrect: false),
        ],
        acceptableAnswers: const [],
        sourceIds: const [],
        explanation: '생성된 해설',
        difficulty: 1,
      );
    }
    return AiGeneratedQuestion(
      type: QuestionType.shortAnswer,
      prompt: '생성된 단답형 문제 ${index + 1}',
      choices: const [],
      acceptableAnswers: const ['정답'],
      sourceIds: const [],
      explanation: '생성된 해설',
      difficulty: 1,
    );
  }
}
