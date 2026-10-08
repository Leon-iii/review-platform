import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/study_text.dart';

/// Shared process/answer presentation in management, review, and quiz results.
class OrderingSequence extends StatelessWidget {
  const OrderingSequence({required this.steps, super.key});
  final List<({String label, String text})> steps;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (steps.isEmpty)
        const Text('선택한 단계가 없어요.')
      else ...[
        Text(
          steps.map((step) => step.label).join(' → '),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        for (final step in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: StudyText('${step.label}. ${step.text}'),
          ),
      ],
    ],
  );
}
