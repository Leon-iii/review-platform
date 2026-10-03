enum ConceptImportance {
  veryLow,
  low,
  medium,
  high,
  veryHigh;

  int get weight => index + 1;

  static ConceptImportance fromStorage(String? value) =>
      switch (value?.trim().toLowerCase()) {
        'verylow' => ConceptImportance.veryLow,
        'low' => ConceptImportance.low,
        'high' => ConceptImportance.high,
        'veryhigh' => ConceptImportance.veryHigh,
        _ => ConceptImportance.medium,
      };

  String get label => switch (this) {
    ConceptImportance.veryLow => '매우 낮음',
    ConceptImportance.low => '낮음',
    ConceptImportance.medium => '보통',
    ConceptImportance.high => '높음',
    ConceptImportance.veryHigh => '매우 높음',
  };
}
