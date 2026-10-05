import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';

enum QuestionManagementSort { updated, created, difficulty, importance }

class QuestionManagementFilter {
  const QuestionManagementFilter({
    this.type,
    this.status,
    this.importance,
    this.sourceId,
    this.minDifficulty = 1,
    this.maxDifficulty = 5,
  });

  final QuestionType? type;
  final QuestionStatus? status;
  final ConceptImportance? importance;
  final String? sourceId;
  final int minDifficulty;
  final int maxDifficulty;

  bool get isActive =>
      type != null ||
      status != null ||
      importance != null ||
      sourceId != null ||
      minDifficulty != 1 ||
      maxDifficulty != 5;

  List<Question> apply(
    List<Question> questions, {
    String query = '',
    QuestionManagementSort sort = QuestionManagementSort.updated,
  }) {
    final words = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final result = questions.where((question) {
      if (type != null && question.type != type) return false;
      if (status != null && question.status != status) return false;
      if (importance != null && question.importance != importance) return false;
      if (question.difficulty < minDifficulty ||
          question.difficulty > maxDifficulty) {
        return false;
      }
      if (sourceId != null &&
          !question.sourceReferences.any(
            (reference) => reference.sourceId == sourceId,
          )) {
        return false;
      }
      final text = [
        question.prompt,
        question.explanation ?? '',
        ...question.choices.map((choice) => choice.text),
        ...question.acceptableAnswers.map((answer) => answer.text),
        ...question.sourceReferences.expand(
          (reference) => [reference.fileName, reference.conceptTitle ?? ''],
        ),
      ].join('\n').toLowerCase();
      return words.every(text.contains);
    }).toList();
    result.sort((a, b) {
      final order = switch (sort) {
        QuestionManagementSort.updated => b.updatedAt.compareTo(a.updatedAt),
        QuestionManagementSort.created => b.createdAt.compareTo(a.createdAt),
        QuestionManagementSort.difficulty => b.difficulty.compareTo(
          a.difficulty,
        ),
        QuestionManagementSort.importance => b.importance.weight.compareTo(
          a.importance.weight,
        ),
      };
      if (order != 0) return order;
      final recent = b.updatedAt.compareTo(a.updatedAt);
      return recent != 0 ? recent : a.id.compareTo(b.id);
    });
    return result;
  }
}
