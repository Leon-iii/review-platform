import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';

void main() {
  test('처리 중 개념은 1부터 표시하되 성공·실패는 완료된 개념으로 집계한다', () {
    const first = AiGenerationProgress(
      completedConcepts: 0,
      totalConcepts: 16,
      generatedQuestions: 0,
      failedConcepts: 0,
      conceptTitle: '첫 개념',
    );
    expect(first.currentConceptNumber, 1);
    expect(first.successfulConcepts, 0);
    const next = AiGenerationProgress(
      completedConcepts: 3,
      totalConcepts: 16,
      generatedQuestions: 10,
      failedConcepts: 1,
      conceptTitle: '다음 개념',
    );
    expect(next.currentConceptNumber, 4);
    expect(next.successfulConcepts, 2);
    const justFinished = AiGenerationProgress(
      completedConcepts: 3,
      totalConcepts: 16,
      generatedQuestions: 10,
      failedConcepts: 1,
    );
    expect(justFinished.currentConceptNumber, 3);
    expect(justFinished.successfulConcepts, 2);
    const allDone = AiGenerationProgress(
      completedConcepts: 16,
      totalConcepts: 16,
      generatedQuestions: 50,
      failedConcepts: 2,
      conceptTitle: '마지막 개념',
    );
    expect(allDone.currentConceptNumber, 16);
    expect(allDone.successfulConcepts, 14);
  });
}
