import 'package:flutter/material.dart';
import 'package:review_platform/domain/enums/question_type.dart';

/// Presentation order, labels and icons do not change the stored enum values.
const questionTypeOptions = <ButtonSegment<QuestionType>>[
  ButtonSegment(
    value: QuestionType.trueFalse,
    icon: Icon(Icons.rule_rounded),
    label: Text('O/X'),
  ),
  ButtonSegment(
    value: QuestionType.multipleChoice,
    icon: Icon(Icons.format_list_numbered_rounded),
    label: Text('객관식'),
  ),
  ButtonSegment(
    value: QuestionType.shortAnswer,
    icon: Icon(Icons.short_text_rounded),
    label: Text('단답형'),
  ),
  ButtonSegment(
    value: QuestionType.essay,
    icon: Icon(Icons.notes_rounded),
    label: Text('서술형'),
  ),
];
