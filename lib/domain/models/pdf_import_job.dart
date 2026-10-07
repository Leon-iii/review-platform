class TrackedPdfImportJob {
  const TrackedPdfImportJob({required this.job, required this.applied});
  final PdfImportJob job;
  final bool applied;
  String get id => job.id;
}

class PdfImportJob {
  const PdfImportJob(this.data);
  final Map<String, Object?> data;
  String get id => data['id']! as String;
  String get fileName => data['fileName']! as String;
  String get status => data['status']! as String;
  String get stage => data['stage'] as String? ?? 'queued';
  // Older clients persisted status-query connection failures as job errors.
  // A waiting review has no running LLM task that could have failed. Ignore
  // those stale errors, even before the first successful server refresh.
  String? get error => isAwaitingReview ? null : data['error'] as String?;
  int get completedPages => (data['completedPages'] as num?)?.toInt() ?? 0;
  int get totalPages => (data['totalPages'] as num?)?.toInt() ?? 0;
  int get completedChunks => (data['completedChunks'] as num?)?.toInt() ?? 0;
  int get totalChunks => (data['totalChunks'] as num?)?.toInt() ?? 0;
  bool get canRetry => status == 'failed' || status == 'cancelled';
  bool get isActive => status == 'queued' || status == 'running';
  bool get isAwaitingReview => status == 'awaiting_review';
  bool get isAwaitingSelection => status == 'awaiting_selection';
  bool get isDirect => data['extractionMode'] == 'direct';
  double? get progress => totalPages == 0
      ? null
      : isDirect
      ? (totalChunks > 0 ? (completedChunks / totalChunks).clamp(0, 1) : null)
      : stage == 'concepts' && totalChunks > 0
      ? (0.7 + 0.3 * completedChunks / totalChunks).clamp(0, 1)
      : (0.7 * completedPages / totalPages).clamp(0, 1);
  String get statusLabel => switch (status) {
    'uploading' => '업로드 중',
    'uploadFailed' => '업로드 미완료',
    'queued' => '분석 대기 중',
    'awaiting_review' => 'OCR 검토 대기',
    'awaiting_selection' => '추출 방식 선택 대기',
    'running' =>
      stage == 'rate_wait'
          ? 'API 한도 회복 대기 중'
          : stage == 'preflight'
          ? '입력량 점검 중'
          : stage == 'direct_concepts'
          ? 'PDF 직접 개념 추출 중'
          : stage == 'reading'
          ? 'PDF 구조 확인 중'
          : stage == 'concepts'
          ? '개념 추출 중'
          : '페이지 분석 중',
    'failed' => '분석 실패',
    'cancelled' => '취소됨',
    'completed' => '분석 완료',
    _ => '서버 확인 중',
  };
  String get progressLabel => isAwaitingReview
      ? '페이지 분석 완료 · 사용자 검토 대기'
      : isDirect || stage == 'concepts'
      ? '개념 추출 $completedChunks / $totalChunks 묶음'
      : '페이지 분석 $completedPages / $totalPages 페이지';
}
