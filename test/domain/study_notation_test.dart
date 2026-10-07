import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/formatters/study_notation.dart';

void main() {
  test('첨자의 종류·범위·중첩을 유지하고 원문을 손실 없이 분리한다', () {
    const source =
        r'성능 \(\mathrm{Performance}_{X}\) 및 \[a_{i,j}^{(k)} = x^{2}\]';
    final parts = splitStudyNotation(source);
    expect(parts.map((part) => part.source).join(), source);
    expect(parts.where((part) => part.isMath).map((part) => part.expression), [
      r'\mathrm{Performance}_{X}',
      r'a_{i,j}^{(k)} = x^{2}',
    ]);
    expect(parts.where((part) => part.isMath).last.display, isTrue);
  });

  test('기존 dollar LaTeX도 표시하되 금액·코드·미완성 표기는 그대로 둔다', () {
    const source = r'$x_i$ $$x^{2}$$ 가격 $10, $20 및 \$30, `\(code\)` \(미완성';
    final parts = splitStudyNotation(source);
    expect(parts.map((part) => part.source).join(), source);
    expect(parts.where((part) => part.isMath).map((part) => part.expression), [
      'x_i',
      'x^{2}',
    ]);
  });

  test('명시된 수식만 처리하고 이름에서 첨자를 추측하지 않는다', () {
    for (final source in [
      'PerformanceX Performance_X x² x₂',
      r'\\(escaped\\)',
      r'```\(code\)```',
      r'\(\) \[\] $$ $$',
      r'$10$ and $20$',
      '',
    ]) {
      final parts = splitStudyNotation(source);
      expect(parts.where((part) => part.isMath), isEmpty, reason: source);
      expect(parts.map((part) => part.source).join(), source);
    }
  });
}
