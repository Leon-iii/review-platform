/// A lossless split of prose and explicitly delimited LaTeX. No script inference.
class StudyNotationPart {
  const StudyNotationPart(this.source, {this.expression, this.display = false});
  final String source;
  final String? expression;
  final bool display;
  bool get isMath => expression != null;
}

List<StudyNotationPart> splitStudyNotation(String value) {
  if (!value.contains(r'\(') &&
      !value.contains(r'\[') &&
      !value.contains(r'$')) {
    return [StudyNotationPart(value)];
  }
  final parts = <StudyNotationPart>[];
  var plainStart = 0;
  var index = 0;
  while (index < value.length) {
    // Code remains literal, including math-looking delimiters inside it.
    if (value[index] == '`' && !_escaped(value, index)) {
      final fence = value.startsWith('```', index) ? '```' : '`';
      final end = value.indexOf(fence, index + fence.length);
      index = end < 0 ? value.length : end + fence.length;
      continue;
    }
    if (_escaped(value, index)) {
      index++;
      continue;
    }
    final (String open, String close, bool display)? delimiter =
        value.startsWith(r'\(', index)
        ? (r'\(', r'\)', false)
        : value.startsWith(r'\[', index)
        ? (r'\[', r'\]', true)
        : value.startsWith(r'$$', index)
        ? (r'$$', r'$$', true)
        : value[index] == r'$'
        ? (r'$', r'$', false)
        : null;
    if (delimiter == null) {
      index++;
      continue;
    }
    final (open, close, display) = delimiter;
    final start = index + open.length;
    var end = value.indexOf(close, start);
    while (end >= 0 &&
        (_escaped(value, end) ||
            (open == r'$' && value.startsWith(r'$$', end)))) {
      end = value.indexOf(close, end + close.length);
    }
    if (end < 0) {
      index += open.length;
      continue;
    }
    final expression = value.substring(start, end);
    // Dollar amounts and incomplete/empty markup must not silently disappear.
    if (expression.trim().isEmpty ||
        (open == r'$' &&
            (expression.trim() != expression ||
                expression.contains('\n') ||
                RegExp(r'^\d+(?:[.,]\d+)*$').hasMatch(expression)))) {
      index += open.length;
      continue;
    }
    if (plainStart < index) {
      parts.add(StudyNotationPart(value.substring(plainStart, index)));
    }
    index = end + close.length;
    parts.add(
      StudyNotationPart(
        value.substring(start - open.length, index),
        expression: expression,
        display: display,
      ),
    );
    plainStart = index;
  }
  if (plainStart < value.length || parts.isEmpty) {
    parts.add(StudyNotationPart(value.substring(plainStart)));
  }
  return parts;
}

bool _escaped(String value, int index) {
  var slashes = 0;
  for (
    var previous = index - 1;
    previous >= 0 && value[previous] == r'\';
    previous--
  ) {
    slashes++;
  }
  return slashes.isOdd;
}
