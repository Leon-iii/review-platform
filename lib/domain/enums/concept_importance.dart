enum ConceptImportance {
  low,
  medium,
  high;

  static ConceptImportance fromStorage(String? value) => switch (value) {
    'low' => ConceptImportance.low,
    'high' => ConceptImportance.high,
    _ => ConceptImportance.medium,
  };

  String get label => switch (this) {
    ConceptImportance.low => '낮음',
    ConceptImportance.medium => '보통',
    ConceptImportance.high => '높음',
  };
}
