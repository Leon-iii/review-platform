/// Formats page references as sorted, distinct numbers and consecutive ranges.
/// Only listed pages are included; gaps are never filled and input is unchanged.
/// The caller supplies a prefix such as `p.` when needed.
String formatPageNumbers(Iterable<int> pageNumbers) {
  final pages = pageNumbers.toSet().toList()..sort();
  if (pages.isEmpty) return '';

  final ranges = <String>[];
  var start = pages.first;
  var end = start;
  void addRange() {
    ranges.add(start == end ? '$start' : '$start - $end');
  }

  for (final page in pages.skip(1)) {
    if (page == end + 1) {
      end = page;
    } else {
      addRange();
      start = end = page;
    }
  }
  addRange();
  return ranges.join(', ');
}
