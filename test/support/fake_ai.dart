import 'dart:async';

import 'package:review_platform/core/ai/remote_ai_api.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/sync_contract.dart';

class FakeRemoteAiApi implements RemoteAiApi {
  int callCount = 0;
  Completer<void>? gate;
  AiQuestionGenerationRequest? lastRequest;
  bool invalidConceptId = false;
  List<AiConceptGenerationFailure> failures = const [];
  List<String> warnings = const [];
  AiGenerationProgress? progress;
  void Function(AiGenerationProgress)? _onProgress;
  void emitProgress(AiGenerationProgress progress) =>
      _onProgress?.call(progress);

  @override
  Future<AiQuestionGenerationResult> generateQuestions({
    required SyncConfiguration configuration,
    required AiQuestionGenerationRequest request,
    void Function(AiGenerationProgress)? onProgress,
  }) async {
    callCount++;
    lastRequest = request;
    _onProgress = onProgress;
    if (progress != null) onProgress?.call(progress!);
    await gate?.future;
    final types = request.questionTypes.toList(growable: false);
    final successfulConcepts = request.concepts
        .where(
          (concept) =>
              !failures.any((failure) => failure.conceptId == concept.id),
        )
        .toList();
    final questionCount =
        request.questionCount ??
        switch (request.automaticDensity ?? AiQuestionDensity.medium) {
          AiQuestionDensity.low => 2,
          AiQuestionDensity.medium => 4,
          AiQuestionDensity.high => 6,
        };
    return AiQuestionGenerationResult(
      failures: failures,
      warnings: warnings,
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
          _question(
            types[index % types.length],
            index,
            successfulConcepts.isEmpty
                ? null
                : invalidConceptId
                ? 'unknown-concept'
                : successfulConcepts[index % successfulConcepts.length].id,
          ),
      ],
    );
  }

  AiGeneratedQuestion _question(
    QuestionType type,
    int index,
    String? primaryConceptId,
  ) {
    if (type == QuestionType.ordering) {
      return AiGeneratedQuestion(
        type: type,
        prompt: '생성된 순서 배열형 문제 ${index + 1}',
        choices: const [
          AiGeneratedChoice(text: '설정을 완료한다.', isCorrect: true),
          AiGeneratedChoice(text: '정보를 처리한다.', isCorrect: true),
          AiGeneratedChoice(text: '결과를 저장한다.', isCorrect: true),
        ],
        correctOrder: const [1, 2, 3],
        acceptableAnswers: const [],
        sourceIds: const [],
        explanation: '단계 간 선후 관계',
        difficulty: 2,
        primaryConceptId: primaryConceptId,
      );
    }
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
        primaryConceptId: primaryConceptId,
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
        primaryConceptId: primaryConceptId,
      );
    }
    return AiGeneratedQuestion(
      type: type,
      prompt:
          '생성된 ${type == QuestionType.essay ? '서술형' : '단답형'} 문제 ${index + 1}',
      choices: const [],
      acceptableAnswers: type == QuestionType.essay
          ? const ['개념의 원리와 이유를 설명한 모범답안이다.']
          : const ['정답'],
      sourceIds: const [],
      explanation: '생성된 해설',
      difficulty: 1,
      primaryConceptId: primaryConceptId,
    );
  }
}
