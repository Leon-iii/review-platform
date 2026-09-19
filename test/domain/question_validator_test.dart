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

    test('O/X 문제를 고정된 선택지 순서로 정리한다', () {
      final result = QuestionValidator.validate(
        const QuestionDraft(
          folderId: 'folder',
          type: QuestionType.trueFalse,
          prompt: '빛의 속도는 진공에서 일정하다.',
          choices: [
            QuestionChoiceDraft(text: ' x ', isCorrect: false),
            QuestionChoiceDraft(text: ' o ', isCorrect: true),
          ],
        ),
      );

      expect(result.choices.map((choice) => choice.text), ['O', 'X']);
      expect(result.choices.first.isCorrect, isTrue);
      expect(result.acceptableAnswers, isEmpty);
    });

    test('O와 X가 아닌 선택지를 가진 O/X 문제를 거부한다', () {
      expect(
        () => QuestionValidator.validate(
          const QuestionDraft(
            folderId: 'folder',
            type: QuestionType.trueFalse,
            prompt: '문제',
            choices: [
              QuestionChoiceDraft(text: '참', isCorrect: true),
              QuestionChoiceDraft(text: '거짓', isCorrect: false),
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
