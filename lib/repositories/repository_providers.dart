import 'package:review_platform/core/database/database_providers.dart';
import 'package:review_platform/repositories/attempt_repository.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';
import 'package:review_platform/repositories/quiz_repository.dart';
import 'package:review_platform/repositories/statistics_repository.dart';
import 'package:review_platform/repositories/sync_repository.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'repository_providers.g.dart';

@Riverpod(keepAlive: true)
FolderRepository folderRepository(Ref ref) {
  return DriftFolderRepository(ref.watch(appDatabaseProvider));
}

@Riverpod(keepAlive: true)
QuestionRepository questionRepository(Ref ref) {
  return DriftQuestionRepository(ref.watch(appDatabaseProvider));
}

@Riverpod(keepAlive: true)
QuizRepository quizRepository(Ref ref) {
  return DriftQuizRepository(ref.watch(appDatabaseProvider));
}

@Riverpod(keepAlive: true)
AttemptRepository attemptRepository(Ref ref) {
  return DriftAttemptRepository(ref.watch(appDatabaseProvider));
}

@Riverpod(keepAlive: true)
StatisticsRepository statisticsRepository(Ref ref) {
  return DriftStatisticsRepository(ref.watch(appDatabaseProvider));
}

@Riverpod(keepAlive: true)
SyncRepository syncRepository(Ref ref) {
  return DriftSyncRepository(ref.watch(appDatabaseProvider));
}
