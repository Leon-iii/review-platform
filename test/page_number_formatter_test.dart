import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/formatters/page_number_formatter.dart';

void main() {
  final cases = <String, (List<int>, String)>{
    'empty': ([], ''),
    'single page': ([50], '50'),
    'two consecutive pages': ([50, 51], '50 - 51'),
    'long consecutive run': ([50, 51, 52, 53], '50 - 53'),
    'isolated pages': ([47, 56, 61], '47, 56, 61'),
    'mixed singles and runs': (
      [1, 3, 4, 8, 10, 11, 12],
      '1, 3 - 4, 8, 10 - 12',
    ),
    'unsorted with gaps': (
      [47, 56, 57, 48, 49, 60, 61],
      '47 - 49, 56 - 57, 60 - 61',
    ),
    'unsorted but continuous': ([47, 56, 59, 57, 58, 60, 61], '47, 56 - 61'),
    'duplicates within a run': ([3, 1, 2, 2, 3], '1 - 3'),
    'only duplicates': ([50, 50, 50], '50'),
  };
  for (final entry in cases.entries) {
    test('page ranges: ${entry.key}', () {
      final (pages, expected) = entry.value;
      final original = List<int>.of(pages);
      expect(formatPageNumbers(pages), expected);
      expect(pages, original);
    });
  }

  test('accepts immutable and lazy collections', () {
    expect(formatPageNumbers(const [5, 4, 3]), '3 - 5');
    expect(
      formatPageNumbers(Iterable.generate(5, (index) => index + 50)),
      '50 - 54',
    );
  });
}
