enum QuestionType {
  multipleChoice,
  trueFalse,
  shortAnswer,
  essay,
  ordering;

  static QuestionType fromStorage(String value) {
    return QuestionType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => throw ArgumentError.value(value, 'value'),
    );
  }
}
