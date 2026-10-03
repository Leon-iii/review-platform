import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/quiz_filter.dart';

void main() {
  test('new study options round-trip through the stored session filter', () {
    const filter = QuizFilter(
      rootFolderId: 'folder',
      enabledQuestionTypes: {
        QuestionType.multipleChoice,
        QuestionType.trueFalse,
      },
      questionCount: 10,
      enabledDifficulties: {5, 3},
      feedbackTiming: AnswerFeedbackTiming.afterCompletion,
      prioritizeImportantConcepts: true,
    );
    final restored = QuizFilter.fromJson(filter.toJson());
    expect(restored.enabledDifficulties, {3, 5});
    expect(restored.feedbackTiming, AnswerFeedbackTiming.afterCompletion);
    expect(restored.prioritizeImportantConcepts, true);
    expect(restored.toJson(), filter.toJson());
  });

  test(
    'legacy sessions default to all difficulties and immediate feedback',
    () {
      final legacy =
          const QuizFilter(
              rootFolderId: 'folder',
              enabledQuestionTypes: {QuestionType.shortAnswer},
              questionCount: 5,
            ).toJson()
            ..remove('enabledDifficulties')
            ..remove('feedbackTiming');
      legacy.remove('prioritizeImportantConcepts');
      final restored = QuizFilter.fromJson(legacy);
      expect(restored.enabledDifficulties, {1, 2, 3, 4, 5});
      expect(restored.feedbackTiming, AnswerFeedbackTiming.immediate);
      expect(restored.prioritizeImportantConcepts, false);
    },
  );
}
