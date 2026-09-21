enum ConceptStatus {
  draft,
  approved,
  held,
  rejected;

  static ConceptStatus fromStorage(String value) => values.firstWhere(
    (status) => status.name == value,
    orElse: () => throw FormatException('Unknown concept status: $value'),
  );
}
