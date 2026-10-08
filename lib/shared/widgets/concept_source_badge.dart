import 'package:flutter/material.dart';
import 'package:review_platform/domain/formatters/page_number_formatter.dart';
import 'package:review_platform/shared/widgets/concept_badge.dart';
import 'package:review_platform/shared/widgets/concept_badge_action.dart';
import 'package:review_platform/shared/widgets/source_snapshot_dialog.dart';

class ConceptSourceBadge extends StatefulWidget {
  const ConceptSourceBadge({
    required this.sourceId,
    required this.pages,
    this.compact = false,
    super.key,
  });
  final String sourceId;
  final List<int> pages;
  final bool compact;

  @override
  State<ConceptSourceBadge> createState() => _ConceptSourceBadgeState();
}

class _ConceptSourceBadgeState extends State<ConceptSourceBadge> {
  bool _open = false;

  Future<void> _show() async {
    if (_open) return;
    setState(() => _open = true);
    try {
      await showSourceSnapshots(
        context,
        sourceId: widget.sourceId,
        pages: widget.pages,
      );
    } finally {
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();
    final label = 'p.${formatPageNumbers(widget.pages)}';
    return ConceptBadgeAction(
      label: '$label 출처 슬라이드 보기',
      tooltip: '출처 슬라이드 보기 · $label',
      onTap: _open ? null : _show,
      child: ConceptBadge(label: label, compact: widget.compact),
    );
  }
}
