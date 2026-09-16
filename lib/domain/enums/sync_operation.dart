enum SyncOperation {
  upsert,
  delete;

  static SyncOperation fromStorage(String value) {
    return SyncOperation.values.byName(value);
  }
}
