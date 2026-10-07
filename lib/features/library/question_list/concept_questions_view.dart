import 'package:flutter/material.dart';
import 'package:review_platform/shared/widgets/study_text.dart';
import 'package:review_platform/shared/widgets/app_page_bar.dart';
import 'package:review_platform/app/design_tokens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/features/library/question_list/question_management_list.dart';
import 'package:review_platform/repositories/repository_providers.dart';
import 'package:review_platform/shared/widgets/app_error.dart';

final conceptQuestionsProvider = StreamProvider.autoDispose
    .family<List<Question>, String>((ref, id) {
      return ref.watch(questionRepositoryProvider).watchQuestionsForConcept(id);
    });

/// This is a relationship lookup, not an expanded folder search: moved questions
/// remain reachable from their original concept, including unapproved questions.
class ConceptQuestionsView extends ConsumerWidget {
  const ConceptQuestionsView({
    required this.conceptId,
    required this.conceptTitle,
    super.key,
  });
  final String conceptId;
  final String conceptTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = conceptQuestionsProvider(conceptId);
    final questions = ref.watch(provider);
    return Scaffold(
      key: const Key('concept-questions-view'),
      appBar: AppPageBar(title: const Text('연결된 문제')),
      body: questions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => AppErrorNotice(
          error: error,
          onRetry: () => ref.invalidate(provider),
        ),
        data: (items) => SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.managementWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StudyText(
                      conceptTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('다른 폴더로 이동한 문제도 포함됩니다.'),
                    const SizedBox(height: 16),
                    QuestionManagementList(
                      key: ValueKey(conceptId),
                      questions: items,
                      scopeLabel: '이 개념에 연결된 문제',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
