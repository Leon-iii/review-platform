import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/question_snapshot.dart';
import 'package:review_platform/domain/services/answer_grader.dart';
import 'package:review_platform/domain/services/question_validator.dart';

void main() {
  for (final caseSensitive in [false, true]) {
    for (final whitespaceSensitive in [false, true]) {
      test('대소문자=$caseSensitive 공백=$whitespaceSensitive를 독립 적용한다', () {
        final question = QuestionSnapshot(
          questionId: 'q',
          type: QuestionType.shortAnswer,
          prompt: '용어는?',
          choices: const [],
          acceptableAnswers: const ['Cache Hit'],
          caseSensitive: caseSensitive,
          whitespaceSensitive: whitespaceSensitive,
        );
        bool correct(String answer) =>
            AnswerGrader.gradeShortAnswer(question, answer).isCorrect;
        expect(correct('  Cache Hit  '), true);
        expect(correct('cache hit'), !caseSensitive);
        expect(correct('CacheHit'), !whitespaceSensitive);
        expect(correct('cachehit'), !caseSensitive && !whitespaceSensitive);
        expect(correct('Cache  Hit'), !whitespaceSensitive);
        expect(correct('Cache\t\nHit'), !whitespaceSensitive);
        expect(correct('Cache\u00a0Hit'), !whitespaceSensitive);
        expect(correct('Cache Miss'), false);
        expect(correct(''), false);
      });

      test('허용 정답 중복 처리도 채점 옵션을 따른다: $caseSensitive/$whitespaceSensitive', () {
        final draft = QuestionValidator.validate(
          QuestionDraft(
            folderId: 'f',
            type: QuestionType.shortAnswer,
            prompt: '용어',
            acceptableAnswers: const ['Cache Hit', 'cache hit', 'CacheHit'],
            caseSensitive: caseSensitive,
            whitespaceSensitive: whitespaceSensitive,
          ),
        );
        expect(draft.caseSensitive, caseSensitive);
        expect(draft.whitespaceSensitive, whitespaceSensitive);
        expect(
          draft.acceptableAnswers.length,
          1 + (caseSensitive ? 1 : 0) + (whitespaceSensitive ? 1 : 0),
        );
      });
    }
  }

  test('기존 풀이 JSON에 옵션이 없으면 모두 false로 읽는다', () {
    final snapshot = QuestionSnapshot.fromJson({
      'questionId': 'old',
      'type': 'shortAnswer',
      'prompt': '용어',
      'choices': <Object>[],
      'acceptableAnswers': ['가우스 법칙'],
    });
    expect(snapshot.caseSensitive, false);
    expect(snapshot.whitespaceSensitive, false);
    expect(AnswerGrader.gradeShortAnswer(snapshot, '가우스법칙').isCorrect, true);
  });

  test('스냅샷 JSON 왕복에서 옵션을 보존한다', () {
    const snapshot = QuestionSnapshot(
      questionId: 'q',
      type: QuestionType.shortAnswer,
      prompt: '용어',
      choices: [],
      acceptableAnswers: ['US', 'us'],
      caseSensitive: true,
      whitespaceSensitive: true,
    );
    final restored = QuestionSnapshot.fromJson(snapshot.toJson());
    expect(restored.caseSensitive, true);
    expect(restored.whitespaceSensitive, true);
    expect(AnswerGrader.gradeShortAnswer(restored, 'US').isCorrect, true);
    expect(AnswerGrader.gradeShortAnswer(restored, 'us').isCorrect, true);
    expect(AnswerGrader.gradeShortAnswer(restored, 'Us').isCorrect, false);
  });
}
