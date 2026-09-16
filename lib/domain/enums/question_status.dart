enum QuestionStatus {
  draft,
  approved,
  archived;

  static QuestionStatus fromStorage(String value) {
    return QuestionStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => throw ArgumentError.value(value, 'value'),
    );
  }
}
