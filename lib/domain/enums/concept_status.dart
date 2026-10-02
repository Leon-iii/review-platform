enum ConceptStatus {
  held,
  approved;

  // Keep stored values unchanged for existing databases and sync clients.
  String get label => switch (this) {
    held => '검토 필요',
    approved => '검토 완료',
  };

  static ConceptStatus fromStorage(String value) => switch (value) {
    'held' || 'draft' => held,
    'approved' => approved,
    _ => throw FormatException('Unknown concept status: $value'),
  };
}
