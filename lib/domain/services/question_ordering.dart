abstract final class QuestionOrdering {
  static bool isPermutation<T>(Iterable<T> order, Iterable<T> choices) {
    final values = order.toList();
    final options = choices.toList();
    return options.length >= 3 &&
        options.length <= 6 &&
        options.toSet().length == options.length &&
        values.length == options.length &&
        values.toSet().length == values.length &&
        values.toSet().containsAll(options);
  }
}
