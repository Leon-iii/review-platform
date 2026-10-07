class PdfExtractionOverview {
  PdfExtractionOverview(this.data) {
    if (fileName.isEmpty ||
        provider.isEmpty ||
        model.isEmpty ||
        pageCount < 1 ||
        fileSize < 1 ||
        revision < 0 ||
        boundaries.any((page) => page < 1 || page >= pageCount)) {
      throw const FormatException('Invalid PDF overview');
    }
    preflight; // Parse nested checks before rendering the screen.
  }
  final Map<String, Object?> data;
  String get fileName => data['fileName']! as String;
  int get pageCount => (data['pageCount']! as num).toInt();
  int get fileSize => (data['fileSize']! as num).toInt();
  int get revision => (data['revision']! as num).toInt();
  String get provider => data['conceptProvider']! as String;
  String get model => data['conceptModel']! as String;
  List<int> get boundaries => (data['splitAfterPages']! as List)
      .cast<num>()
      .map((n) => n.toInt())
      .toList();
  PdfExtractionPreflight? get preflight => data['preflight'] == null
      ? null
      : PdfExtractionPreflight(
          Map<String, Object?>.from(data['preflight']! as Map),
        );
}

class PdfExtractionPreflight {
  PdfExtractionPreflight(this.data) {
    if (revision < 0 ||
        !{
          'ready',
          'warning',
          'unknown',
          'waiting',
          'blocked',
        }.contains(status)) {
      throw const FormatException('Invalid PDF preflight');
    }
    for (final part in parts) {
      final range = part['range']! as Map;
      final first = (range['firstPage']! as num).toInt();
      final last = (range['lastPage']! as num).toInt();
      if (first < 1 ||
          last < first ||
          (part['outputBudget']! as num) < 1 ||
          (part['estimatedOutputTokens']! as num) < 0 ||
          !{
            'ready',
            'warning',
            'unknown',
            'waiting',
            'blocked',
          }.contains(part['status']) ||
          (part['messages']! as List).any((message) => message is! String) ||
          (part['inputTokens'] != null && (part['inputTokens']! as num) < 1)) {
        throw const FormatException('Invalid PDF preflight part');
      }
    }
  }
  final Map<String, Object?> data;
  int get revision => (data['revision']! as num).toInt();
  String get status => data['status']! as String;
  List<Map<String, Object?>> get parts => (data['parts']! as List)
      .map((p) => Map<String, Object?>.from(p as Map))
      .toList();
  bool get canStart =>
      parts.isNotEmpty &&
      status != 'blocked' &&
      !parts.any(
        (p) =>
            p['status'] == 'blocked' ||
            (p['status'] == 'waiting' && p['inputTokens'] == null),
      );
}
