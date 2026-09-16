enum SyncEntityType {
  folder,
  question,
  quizSession,
  attempt;

  static SyncEntityType fromStorage(String value) {
    return SyncEntityType.values.byName(value);
  }
}
