import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/services/question_validator.dart';

void main() {
  group('QuestionValidator', () {
    test('객관식은 선택지를 정리하고 정답 하나를 허용한다', () {
      final result = QuestionValidator.validate(
        const QuestionDraft(
          folderId: 'folder',
          type: QuestionType.multipleChoice,
          prompt: '  가우스 법칙은?  ',
          choices: [
            QuestionChoiceDraft(text: ' 정답 ', isCorrect: true),
            QuestionChoiceDraft(text: ' 오답 ', isCorrect: false),
          ],
        ),
      );

      expect(result.prompt, '가우스 법칙은?');
      expect(result.choices.first.text, '정답');
      expect(result.choices.where((choice) => choice.isCorrect), hasLength(1));
    });

    test('객관식의 정답이 여러 개이면 거부한다', () {
      expect(
        () => QuestionValidator.validate(
          const QuestionDraft(
            folderId: 'folder',
            type: QuestionType.multipleChoice,
            prompt: '문제',
            choices: [
              QuestionChoiceDraft(text: 'A', isCorrect: true),
              QuestionChoiceDraft(text: 'B', isCorrect: true),
            ],
          ),
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('단답형 허용 정답을 trim하고 중복을 제거한다', () {
      final result = QuestionValidator.validate(
        const QuestionDraft(
          folderId: 'folder',
          type: QuestionType.shortAnswer,
          prompt: '법칙 이름은?',
          acceptableAnswers: [' 가우스 법칙 ', '가우스 법칙', 'Gauss law'],
        ),
      );

      expect(result.acceptableAnswers, ['가우스 법칙', 'Gauss law']);
    });

    test('허용 정답이 없는 단답형을 거부한다', () {
      expect(
        () => QuestionValidator.validate(
          const QuestionDraft(
            folderId: 'folder',
            type: QuestionType.shortAnswer,
            prompt: '문제',
          ),
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });
  });
}
