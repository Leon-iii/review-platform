import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';

abstract final class QuestionValidator {
  static QuestionDraft validate(QuestionDraft draft) {
    final prompt = draft.prompt.trim();
    if (draft.folderId.trim().isEmpty) {
      throw const ValidationFailure('문제를 저장할 폴더가 필요해요.');
    }
    if (prompt.isEmpty) {
      throw const ValidationFailure('문제 내용을 입력해 주세요.');
    }
    final difficulty = draft.difficulty;
    if (difficulty != null && (difficulty < 1 || difficulty > 5)) {
      throw const ValidationFailure('난이도는 1부터 5 사이여야 해요.');
    }

    final explanation = draft.explanation?.trim();

    return switch (draft.type) {
      QuestionType.multipleChoice => _validateMultipleChoice(
        draft,
        prompt,
        explanation,
      ),
      QuestionType.trueFalse => _validateTrueFalse(draft, prompt, explanation),
      QuestionType.shortAnswer => _validateShortAnswer(
        draft,
        prompt,
        explanation,
      ),
      QuestionType.essay => throw const ValidationFailure(
        '서술형 문제는 현재 단계에서 지원하지 않아요.',
      ),
    };
  }

  static QuestionDraft _validateTrueFalse(
    QuestionDraft draft,
    String prompt,
    String? explanation,
  ) {
    final choices = [
      for (final choice in draft.choices)
        QuestionChoiceDraft(
          text: choice.text.trim().toUpperCase(),
          isCorrect: choice.isCorrect,
        ),
    ];
    final choiceTexts = choices.map((choice) => choice.text).toSet();

    if (choices.length != 2 ||
        choiceTexts.length != 2 ||
        !choiceTexts.containsAll(const {'O', 'X'})) {
      throw const ValidationFailure('O/X 문제의 선택지는 O와 X여야 해요.');
    }
    if (choices.where((choice) => choice.isCorrect).length != 1) {
      throw const ValidationFailure('O/X 문제의 정답을 하나만 선택해 주세요.');
    }

    final correctAnswer = choices
        .singleWhere((choice) => choice.isCorrect)
        .text;
    return QuestionDraft(
      folderId: draft.folderId,
      type: draft.type,
      status: draft.status,
      prompt: prompt,
      choices: [
        QuestionChoiceDraft(text: 'O', isCorrect: correctAnswer == 'O'),
        QuestionChoiceDraft(text: 'X', isCorrect: correctAnswer == 'X'),
      ],
      explanation: _nullIfEmpty(explanation),
      difficulty: draft.difficulty,
    );
  }

  static QuestionDraft _validateMultipleChoice(
    QuestionDraft draft,
    String prompt,
    String? explanation,
  ) {
    final choices = [
      for (final choice in draft.choices)
        QuestionChoiceDraft(
          text: choice.text.trim(),
          isCorrect: choice.isCorrect,
        ),
    ];

    if (choices.length < 2) {
      throw const ValidationFailure('객관식 선택지는 2개 이상 필요해요.');
    }
    if (choices.any((choice) => choice.text.isEmpty)) {
      throw const ValidationFailure('빈 선택지가 있어요.');
    }
    if (choices.where((choice) => choice.isCorrect).length != 1) {
      throw const ValidationFailure('정답을 하나만 선택해 주세요.');
    }

    return QuestionDraft(
      folderId: draft.folderId,
      type: draft.type,
      status: draft.status,
      prompt: prompt,
      choices: choices,
      explanation: _nullIfEmpty(explanation),
      difficulty: draft.difficulty,
    );
  }

  static QuestionDraft _validateShortAnswer(
    QuestionDraft draft,
    String prompt,
    String? explanation,
  ) {
    final seen = <String>{};
    final acceptableAnswers = <String>[];
    for (final answer in draft.acceptableAnswers) {
      final trimmed = answer.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed.toLowerCase())) {
        acceptableAnswers.add(trimmed);
      }
    }

    if (acceptableAnswers.isEmpty) {
      throw const ValidationFailure('허용 정답을 하나 이상 입력해 주세요.');
    }

    return QuestionDraft(
      folderId: draft.folderId,
      type: draft.type,
      status: draft.status,
      prompt: prompt,
      acceptableAnswers: acceptableAnswers,
      explanation: _nullIfEmpty(explanation),
      difficulty: draft.difficulty,
    );
  }

  static String? _nullIfEmpty(String? value) {
    return value == null || value.isEmpty ? null : value;
  }
}
