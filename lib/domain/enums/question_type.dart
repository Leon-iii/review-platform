enum QuestionType {
  multipleChoice,
  trueFalse,
  shortAnswer,
  essay;

  static QuestionType fromStorage(String value) {
    return QuestionType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => throw ArgumentError.value(value, 'value'),
    );
  }
}
