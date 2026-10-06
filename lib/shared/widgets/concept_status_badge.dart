import 'package:flutter/material.dart';
import 'package:review_platform/domain/enums/concept_status.dart';
import 'package:review_platform/shared/widgets/review_status_badge.dart';

class ConceptStatusBadge extends StatelessWidget {
  const ConceptStatusBadge({
    required this.status,
    this.compact = false,
    super.key,
  });

  final ConceptStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) => ReviewStatusBadge(
    reviewed: status == ConceptStatus.approved,
    label: status.label,
    compact: compact,
  );
}
