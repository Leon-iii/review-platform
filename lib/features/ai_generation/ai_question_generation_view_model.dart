import 'package:review_platform/core/ai/ai_providers.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/core/sync/sync_providers.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/ai_question_generation.dart';
import 'package:review_platform/domain/models/folder.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ai_question_generation_view_model.g.dart';

enum AiReviewStatus { pending, approved, rejected }

class AiQuestionReviewItem {
  const AiQuestionReviewItem({
    required this.questionId,
    required this.question,
    this.status = AiReviewStatus.pending,
  });

  final String questionId;
  final AiGeneratedQuestion question;
  final AiReviewStatus status;

  AiQuestionReviewItem copyWith({AiReviewStatus? status}) {
    return AiQuestionReviewItem(
      questionId: questionId,
      question: question,
      status: status ?? this.status,
    );
  }
}

class AiQuestionReviewState {
  const AiQuestionReviewState({
    required this.folderId,
    required this.metadata,
    required this.items,
  });

  final String folderId;
  final AiGenerationMetadata metadata;
  final List<AiQuestionReviewItem> items;

  int get pendingCount =>
      items.where((item) => item.status == AiReviewStatus.pending).length;

  AiQuestionReviewState update(
    Iterable<String> questionIds,
    AiReviewStatus status,
  ) {
    final ids = questionIds.toSet();
    return AiQuestionReviewState(
      folderId: folderId,
      metadata: metadata,
      items: [
        for (final item in items)
          ids.contains(item.questionId) ? item.copyWith(status: status) : item,
      ],
    );
  }
}

@riverpod
Stream<List<Folder>> aiGenerationFolders(Ref ref) {
  return ref.watch(folderRepositoryProvider).watchFolderTree().map((roots) {
    final folders = <Folder>[];
    void visit(FolderNode node) {
      folders.add(node.folder);
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }
    return List.unmodifiable(folders);
  });
}

@riverpod
class AiQuestionGenerationController extends _$AiQuestionGenerationController {
  @override
  FutureOr<AiQuestionReviewState?> build(String? initialFolderId) => null;

  Future<void> generate({
    required String folderId,
    required String sourceText,
    required Set<QuestionType> questionTypes,
    String? sourceLabel,
    AiQuestionGenerationMode generationMode = AiQuestionGenerationMode.manual,
    AiQuestionDensity? automaticDensity,
    int? questionCount = 10,
  }) async {
    state = const AsyncLoading();
    try {
      final configuration = await ref
          .read(syncCredentialsStoreProvider)
          .readConfiguration();
      if (configuration == null) {
        throw const ValidationFailure('설정에서 개인 서버 주소와 접근 토큰을 먼저 저장해 주세요.');
      }
      final result = await ref
          .read(remoteAiApiProvider)
          .generateQuestions(
            configuration: configuration,
            request: AiQuestionGenerationRequest(
              sourceText: sourceText,
              questionCount: questionCount,
              questionTypes: questionTypes,
              sourceLabel: sourceLabel,
              generationMode: generationMode,
              automaticDensity: automaticDensity,
            ),
          );
      final drafts = [
        for (final question in result.questions)
          QuestionDraft(
            folderId: folderId,
            type: question.type,
            status: QuestionStatus.draft,
            prompt: question.prompt,
            choices: [
              for (final choice in question.choices)
                QuestionChoiceDraft(
                  text: choice.text,
                  isCorrect: choice.isCorrect,
                ),
            ],
            acceptableAnswers: question.acceptableAnswers,
            explanation: question.explanation,
            difficulty: question.difficulty,
          ),
      ];
      final ids = await ref
          .read(questionRepositoryProvider)
          .createQuestions(drafts);
      state = AsyncData(
        AiQuestionReviewState(
          folderId: folderId,
          metadata: result.metadata,
          items: [
            for (var index = 0; index < ids.length; index++)
              AiQuestionReviewItem(
                questionId: ids[index],
                question: result.questions[index],
              ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> approve(String questionId) async {
    final current = state.requireValue!;
    await ref.read(questionRepositoryProvider).approveQuestion(questionId);
    state = AsyncData(current.update([questionId], AiReviewStatus.approved));
  }

  Future<void> approveAll() async {
    final current = state.requireValue!;
    final ids = [
      for (final item in current.items)
        if (item.status == AiReviewStatus.pending) item.questionId,
    ];
    if (ids.isEmpty) return;
    await ref.read(questionRepositoryProvider).approveQuestions(ids);
    state = AsyncData(current.update(ids, AiReviewStatus.approved));
  }

  Future<void> reject(String questionId) async {
    final current = state.requireValue!;
    await ref.read(questionRepositoryProvider).deleteQuestion(questionId);
    state = AsyncData(current.update([questionId], AiReviewStatus.rejected));
  }

  void markEditedAndApproved(String questionId) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.update([questionId], AiReviewStatus.approved));
  }
}
