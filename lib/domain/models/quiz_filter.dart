import 'package:review_platform/domain/enums/question_type.dart';

enum AnswerFeedbackTiming { immediate, afterCompletion }

class QuizFilter {
  const QuizFilter({
    required this.rootFolderId,
    required this.enabledQuestionTypes,
    required this.questionCount,
    this.excludedFolderIds = const {},
    this.onlyWrongQuestions = false,
    this.maxCorrectRate,
    this.shuffle = true,
    this.enabledDifficulties = const {1, 2, 3, 4, 5},
    this.feedbackTiming = AnswerFeedbackTiming.immediate,
  });

  final String rootFolderId;
  final Set<String> excludedFolderIds;
  final Set<QuestionType> enabledQuestionTypes;
  final int questionCount;
  final bool onlyWrongQuestions;
  final double? maxCorrectRate;
  final bool shuffle;
  final Set<int> enabledDifficulties;
  final AnswerFeedbackTiming feedbackTiming;

  Map<String, Object?> toJson() => {
    'rootFolderId': rootFolderId,
    'excludedFolderIds': excludedFolderIds.toList(),
    'enabledQuestionTypes': [
      for (final type in enabledQuestionTypes) type.name,
    ],
    'questionCount': questionCount,
    'onlyWrongQuestions': onlyWrongQuestions,
    'maxCorrectRate': maxCorrectRate,
    'shuffle': shuffle,
    'enabledDifficulties': enabledDifficulties.toList()..sort(),
    'feedbackTiming': feedbackTiming.name,
  };

  factory QuizFilter.fromJson(Map<String, Object?> json) {
    return QuizFilter(
      rootFolderId: json['rootFolderId']! as String,
      excludedFolderIds: {
        for (final id in json['excludedFolderIds']! as List) id as String,
      },
      enabledQuestionTypes: {
        for (final type in json['enabledQuestionTypes']! as List)
          QuestionType.fromStorage(type as String),
      },
      questionCount: json['questionCount']! as int,
      onlyWrongQuestions: json['onlyWrongQuestions']! as bool,
      maxCorrectRate: (json['maxCorrectRate'] as num?)?.toDouble(),
      shuffle: json['shuffle']! as bool,
      enabledDifficulties: json['enabledDifficulties'] == null
          ? const {1, 2, 3, 4, 5}
          : {
              for (final difficulty in json['enabledDifficulties']! as List)
                difficulty as int,
            },
      feedbackTiming: AnswerFeedbackTiming.values.firstWhere(
        (timing) => timing.name == json['feedbackTiming'],
        orElse: () => AnswerFeedbackTiming.immediate,
      ),
    );
  }
}
