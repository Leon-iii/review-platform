enum ConceptStatus {
  held,
  approved;

  static ConceptStatus fromStorage(String value) => switch (value) {
    'held' || 'draft' => held,
    'approved' => approved,
    _ => throw FormatException('Unknown concept status: $value'),
  };
}
