import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:review_platform/core/database/app_database.dart';
import 'package:review_platform/core/errors/app_failure.dart';
import 'package:review_platform/domain/enums/question_status.dart';
import 'package:review_platform/domain/enums/question_type.dart';
import 'package:review_platform/domain/models/question.dart';
import 'package:review_platform/repositories/folder_repository.dart';
import 'package:review_platform/repositories/question_repository.dart';

void main() {
  late AppDatabase database;
  late DriftQuestionRepository repository;
  late String folderId;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    folderId = await DriftFolderRepository(database).createFolder(name: '전자기학');
    repository = DriftQuestionRepository(database);
  });

  tearDown(() => database.close());

  test('객관식 문제와 선택지를 transaction으로 저장한다', () async {
    final id = await repository.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.multipleChoice,
        prompt: ' 전기장의 SI 단위는? ',
        explanation: ' 단위는 V/m이다. ',
        choices: const [
          QuestionChoiceDraft(text: 'V/m', isCorrect: true),
          QuestionChoiceDraft(text: 'A/m', isCorrect: false),
        ],
      ),
    );

    final question = await repository.getQuestion(id);
    expect(question, isNotNull);
    expect(question!.status, QuestionStatus.approved);
    expect(question.prompt, '전기장의 SI 단위는?');
    expect(question.explanation, '단위는 V/m이다.');
    expect(question.choices, hasLength(2));
    expect(
      question.choices.singleWhere((choice) => choice.isCorrect).text,
      'V/m',
    );
    expect(question.acceptableAnswers, isEmpty);
  });

  test('O/X 문제를 기존 선택지 구조로 저장한다', () async {
    final id = await repository.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.trueFalse,
        prompt: '전자는 음전하를 띤다.',
        choices: const [
          QuestionChoiceDraft(text: 'O', isCorrect: true),
          QuestionChoiceDraft(text: 'X', isCorrect: false),
        ],
      ),
    );

    final question = await repository.getQuestion(id);
    expect(question!.type, QuestionType.trueFalse);
    expect(question.choices.map((choice) => choice.text), ['O', 'X']);
    expect(question.choices.first.isCorrect, isTrue);
  });

  test('객관식을 단답형으로 수정하며 상세 데이터를 교체한다', () async {
    final id = await repository.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.multipleChoice,
        prompt: '문제',
        choices: const [
          QuestionChoiceDraft(text: 'A', isCorrect: true),
          QuestionChoiceDraft(text: 'B', isCorrect: false),
        ],
      ),
    );

    await repository.updateQuestion(
      id,
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        prompt: '수정된 문제',
        acceptableAnswers: const ['가우스 법칙', 'Gauss law'],
      ),
    );

    final question = await repository.getQuestion(id);
    expect(question!.type, QuestionType.shortAnswer);
    expect(question.choices, isEmpty);
    expect(
      question.acceptableAnswers.map((answer) => answer.text),
      containsAll(['가우스 법칙', 'Gauss law']),
    );
  });

  test('approved이며 삭제되지 않은 문제만 출제 대상이다', () async {
    final approvedId = await repository.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        prompt: '승인 문제',
        acceptableAnswers: const ['정답'],
      ),
    );
    await repository.createQuestion(
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        status: QuestionStatus.draft,
        prompt: '초안 문제',
        acceptableAnswers: const ['정답'],
      ),
    );

    var eligible = await repository.getEligibleQuestions(
      folderIds: [folderId],
      types: {QuestionType.shortAnswer},
    );
    expect(eligible.map((question) => question.id), [approvedId]);

    await repository.deleteQuestion(approvedId);
    eligible = await repository.getEligibleQuestions(
      folderIds: [folderId],
      types: {QuestionType.shortAnswer},
    );
    expect(eligible, isEmpty);
    expect(await repository.getQuestion(approvedId), isNull);
  });

  test('AI 문제를 한 transaction에서 Draft로 저장하고 일괄 승인한다', () async {
    final ids = await repository.createQuestions([
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        status: QuestionStatus.draft,
        prompt: '초안 1',
        acceptableAnswers: const ['정답 1'],
      ),
      QuestionDraft(
        folderId: folderId,
        type: QuestionType.shortAnswer,
        status: QuestionStatus.draft,
        prompt: '초안 2',
        acceptableAnswers: const ['정답 2'],
      ),
    ]);

    expect(ids, hasLength(2));
    expect(
      (await repository.getQuestion(ids.first))!.status,
      QuestionStatus.draft,
    );
    expect(
      await repository.getEligibleQuestions(
        folderIds: [folderId],
        types: {QuestionType.shortAnswer},
      ),
      isEmpty,
    );

    await repository.approveQuestions(ids);

    final eligible = await repository.getEligibleQuestions(
      folderIds: [folderId],
      types: {QuestionType.shortAnswer},
    );
    expect(eligible.map((question) => question.id), containsAll(ids));
  });

  test('AI 문제 묶음 중 하나가 유효하지 않으면 아무것도 저장하지 않는다', () async {
    await expectLater(
      repository.createQuestions([
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          status: QuestionStatus.draft,
          prompt: '정상 문제',
          acceptableAnswers: const ['정답'],
        ),
        QuestionDraft(
          folderId: folderId,
          type: QuestionType.shortAnswer,
          status: QuestionStatus.draft,
          prompt: '잘못된 문제',
        ),
      ]),
      throwsA(isA<ValidationFailure>()),
    );

    expect(await repository.watchQuestions(folderId).first, isEmpty);
  });
}
