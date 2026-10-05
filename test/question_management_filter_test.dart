import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/domain/enums/concept_importance.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/domain/models/study_source.dart';
import 'package:review_platform/features/library/question_list/question_management_filter.dart';

Question sample(
  String id, {
  QuestionType type = QuestionType.shortAnswer,
  QuestionStatus status = QuestionStatus.approved,
  int difficulty = 3,
  ConceptImportance importance = ConceptImportance.medium,
  int day = 1,
  List<QuestionSourceReference> sources = const [],
}) => Question(
  id: id,
  folderId: 'folder',
  type: type,
  status: status,
  prompt: 'Cache 문제 $id',
  explanation: '히트와 미스 설명',
  choices: const [],
  acceptableAnswers: const [AcceptableAnswer(id: 'answer', text: '정답 내용')],
  difficulty: difficulty,
  importance: importance,
  sourceReferences: sources,
  createdAt: DateTime.utc(2026, 1, day),
  updatedAt: DateTime.utc(2026, 2, day),
);

void main() {
  test('검색은 공백·대소문자를 정규화하고 본문·정답·해설·자료·개념을 찾는다', () {
    final items = [
      sample(
        'linked',
        sources: const [
          QuestionSourceReference(
            sourceId: 's',
            fileName: '네트워크.pdf',
            conceptId: 'c',
            conceptTitle: '웹 캐시',
            pageNumbers: [1],
          ),
        ],
      ),
      sample('other'),
    ];
    const filter = QuestionManagementFilter();
    expect(filter.apply(items, query: ' CACHE   히트 ').length, 2);
    expect(filter.apply(items, query: '정답 내용').length, 2);
    expect(filter.apply(items, query: '네트워크 캐시').single.id, 'linked');
    expect(filter.apply(items, query: '없는 검색어'), isEmpty);
    expect(filter.isActive, isFalse);
  });

  test('유형·승인·중요도·자료·난이도 필터를 AND로 적용한다', () {
    final wanted = sample(
      'wanted',
      type: QuestionType.trueFalse,
      status: QuestionStatus.draft,
      difficulty: 4,
      importance: ConceptImportance.high,
      sources: const [
        QuestionSourceReference(sourceId: 's', fileName: '자료', pageNumbers: []),
      ],
    );
    final items = [wanted, sample('tooEasy', difficulty: 1), sample('other')];
    const filter = QuestionManagementFilter(
      type: QuestionType.trueFalse,
      status: QuestionStatus.draft,
      importance: ConceptImportance.high,
      sourceId: 's',
      minDifficulty: 3,
      maxDifficulty: 4,
    );
    expect(filter.isActive, isTrue);
    expect(filter.apply(items).single.id, 'wanted');
    expect(
      const QuestionManagementFilter(
        minDifficulty: 4,
        maxDifficulty: 4,
      ).apply(items).single.id,
      'wanted',
    );
    expect(
      const QuestionManagementFilter(status: QuestionStatus.archived)
          .apply(items),
      isEmpty,
    );
  });

  test('정렬은 입력 목록을 변경하지 않고 최신·난이도·중요도 순으로 안정적으로 정렬한다', () {
    final items = [
      sample('old', difficulty: 5, importance: ConceptImportance.veryHigh),
      sample('new', day: 3),
      sample('middle', day: 2),
    ];
    const filter = QuestionManagementFilter();
    expect(filter.apply(items).map((q) => q.id), ['new', 'middle', 'old']);
    expect(
      filter.apply(items, sort: QuestionManagementSort.created).first.id,
      'new',
    );
    expect(
      filter.apply(items, sort: QuestionManagementSort.difficulty).first.id,
      'old',
    );
    expect(
      filter.apply(items, sort: QuestionManagementSort.importance).first.id,
      'old',
    );
    expect(items.first.id, 'old');
  });
}
