import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/services/answer_grader.dart';

void main() {
  group('AnswerGrader', () {
    test('객관식 선택지를 로컬 채점한다', () {
      const question = QuestionSnapshot(
        questionId: 'question-1',
        type: QuestionType.multipleChoice,
        prompt: '정답은?',
        choices: [
          SnapshotChoice(id: 'a', text: 'A', isCorrect: false),
          SnapshotChoice(id: 'b', text: 'B', isCorrect: true),
        ],
        acceptableAnswers: [],
      );

      expect(AnswerGrader.gradeMultipleChoice(question, 'b').isCorrect, isTrue);
      expect(
        AnswerGrader.gradeMultipleChoice(question, 'a').isCorrect,
        isFalse,
      );
    });

    test('단답형은 앞뒤·연속 공백과 대소문자를 정규화한다', () {
      const question = QuestionSnapshot(
        questionId: 'question-2',
        type: QuestionType.shortAnswer,
        prompt: '법칙 이름은?',
        choices: [],
        acceptableAnswers: ['Gauss Law', '가우스 법칙'],
      );

      final result = AnswerGrader.gradeShortAnswer(question, '  GAUSS   law  ');

      expect(result.isCorrect, isTrue);
      expect(result.score, 1);
      expect(result.maxScore, 1);
    });
  });
}
