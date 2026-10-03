enum OcrContentKind {
  text('text', '일반 텍스트'),
  diagram('diagram', '도식'),
  table('table', '표'),
  uncertain('uncertain', '불명확');

  const OcrContentKind(this.id, this.label);
  final String id;
  final String label;
  static OcrContentKind parse(Object? value) =>
      values.firstWhere((kind) => kind.id == value, orElse: () => uncertain);
}

class OcrReviewBlock {
  const OcrReviewBlock({
    required this.text,
    this.independent = false,
    this.excluded = false,
    this.visualRegion = false,
    this.kind = OcrContentKind.text,
  });
  final String text;
  final bool independent;
  final bool excluded;
  final bool visualRegion;
  final OcrContentKind kind;

  factory OcrReviewBlock.fromJson(Map<String, Object?> json) => OcrReviewBlock(
    text: json['text']! as String,
    independent: json['independent']! as bool,
    excluded: json['excluded']! as bool,
    visualRegion: json['visualRegion']! as bool,
    kind: OcrContentKind.parse(json['kind']),
  );
  Map<String, Object?> toJson() => {
    'text': text,
    'independent': independent,
    'excluded': excluded,
    'visualRegion': visualRegion,
    'kind': kind.id,
  };
}

class OcrReviewPage {
  const OcrReviewPage({
    required this.pageNumber,
    required this.totalPages,
    required this.originalText,
    required this.blocks,
    required this.originalBlocks,
    required this.revision,
    required this.edited,
    this.readOnly = false,
  });
  final int pageNumber;
  final int totalPages;
  final String originalText;
  final List<OcrReviewBlock> blocks;
  final List<OcrReviewBlock> originalBlocks;
  final int revision;
  final bool edited;
  final bool readOnly;
  factory OcrReviewPage.fromJson(Map<String, Object?> json) => OcrReviewPage(
    pageNumber: (json['pageNumber']! as num).toInt(),
    totalPages: (json['totalPages']! as num).toInt(),
    originalText: json['originalText']! as String,
    blocks: _blocks(json['blocks']),
    originalBlocks: _blocks(json['originalBlocks']),
    revision: (json['revision']! as num).toInt(),
    edited: json['edited']! as bool,
    readOnly: json['readOnly'] as bool? ?? false,
  );
  static List<OcrReviewBlock> _blocks(Object? raw) => [
    for (final item in raw! as List)
      OcrReviewBlock.fromJson(Map<String, Object?>.from(item as Map)),
  ];
}
