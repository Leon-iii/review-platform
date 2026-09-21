enum SyncEntityType {
  folder,
  question,
  source,
  concept,
  quizSession,
  attempt;

  static SyncEntityType fromStorage(String value) {
    return SyncEntityType.values.byName(value);
  }
}
