using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptRevisionServiceTests
{
    [Fact]
    public async Task Revise_IntegratedTerminologyReturnsRewrittenContentWithoutAppendingOriginal()
    {
        const string original = "객체가 캐시에 있으면 캐시가 반환하고, 없으면 원본 서버에서 받아 저장한 뒤 전달한다. 캐시는 응답 시간을 줄인다.";
        const string revised = "캐시에 객체가 있는 캐시 히트(cache hit)에는 캐시가 객체를 반환한다. 객체가 없는 캐시 미스(cache miss)에는 원본 서버에서 받아 저장한 뒤 전달한다. 캐시는 응답 시간을 줄인다.";
        var provider = new FakeProvider(_ =>
            [new GeneratedConceptRevision("cache", "웹 캐시", revised, [1], "medium")]);
        var request = new ReviseConceptsRequest(
            "source", "자료.pdf", 1, "캐시 히트와 캐시 미스에 대한 내용도 포함시켜 줘.", ["cache"],
            [new ConceptRevisionContext("cache", "웹 캐시", original, [1], "approved", "medium")]);

        var response = await CreateService(provider).ReviseAsync(request, TestContext.Current.CancellationToken);

        var revision = Assert.Single(response.Revisions);
        Assert.Equal(revised, revision.Content);
        Assert.Equal("웹 캐시", revision.Title);
        Assert.Equal([1], revision.PageNumbers);
        Assert.Equal("medium", revision.Importance);
        Assert.Equal(original, provider.LastInput!.Concepts.Single().Content);
        Assert.Equal(ConceptRevisionPrompt.Version, provider.LastInput.PromptVersion);
    }

    [Theory]
    [InlineData("veryLow", "veryLow")]
    [InlineData("low", "low")]
    [InlineData("medium", "medium")]
    [InlineData("high", "high")]
    [InlineData("veryHigh", "veryHigh")]
    [InlineData(" VERYLOW ", "veryLow")]
    [InlineData(" VERYHIGH ", "veryHigh")]
    public async Task Revise_FiveImportanceLevelsRoundTrip(string value, string canonical)
    {
        var request = Request() with
        {
            TargetConceptIds = ["held-1"],
            Concepts = [Request().Concepts[0] with { Importance = value }]
        };
        var provider = new FakeProvider(_ =>
        [new GeneratedConceptRevision("held-1", "가우스 법칙", "수정 내용", [3, 4], value)]);
        var response = await CreateService(provider).ReviseAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(canonical, provider.LastInput!.Concepts.Single().Importance);
        Assert.Equal(canonical, Assert.Single(response.Revisions).Importance);
    }

    [Fact]
    public async Task Revise_UnknownImportanceIsRejectedForInputAndOutput()
    {
        var provider = new FakeProvider(_ =>
        [new GeneratedConceptRevision("held-1", "가우스 법칙", "수정 내용", [3, 4], "unknown")]);
        var invalid = Request() with
        {
            Concepts = [Request().Concepts[0] with { Importance = "unknown" }]
        };
        await Assert.ThrowsAsync<ConceptRevisionRequestException>(() =>
            CreateService(provider).ReviseAsync(invalid, TestContext.Current.CancellationToken));
        Assert.Null(provider.LastInput);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateService(provider).ReviseAsync(Request(), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Revise_SelectedTargetsSendAllConceptsAndReturnOnlyActualChanges()
    {
        var provider = new FakeProvider(input =>
        [
            new GeneratedConceptRevision(
                "held-1",
                "가우스 법칙",
                "폐곡면의 전기선속과 내부 전하의 관계를 설명한다.",
                [4, 3],
                "high"),
            new GeneratedConceptRevision(
                "held-2",
                "전위",
                "단위 전하당 위치 에너지",
                [6])
        ]);
        var service = CreateService(provider);

        var response = await service.ReviseAsync(
            Request(),
            TestContext.Current.CancellationToken);

        Assert.NotNull(provider.LastInput);
        Assert.Equal(3, provider.LastInput.Concepts.Count);
        Assert.Equal(["held-1", "held-2"], provider.LastInput.EditableConceptIds);
        var revision = Assert.Single(response.Revisions);
        Assert.Equal("held-1", revision.Id);
        Assert.Equal([3, 4], revision.PageNumbers);
        Assert.Equal("high", revision.Importance);
    }

    [Fact]
    public async Task Revise_RejectsRevisionForUnselectedConcept()
    {
        var provider = new FakeProvider(_ =>
        [
            new GeneratedConceptRevision(
                "approved-1",
                "수정된 쿨롱 법칙",
                "승인된 개념을 임의로 바꾼 내용",
                [5])
        ]);
        var service = CreateService(provider);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => service.ReviseAsync(
                Request(),
                TestContext.Current.CancellationToken));

        Assert.Contains("올바르지 않은 개념 수정안", exception.Message);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(10)]
    public async Task Revise_UserAuthoredConceptsUseSamePipelineWithoutPageProvenance(int pageCount)
    {
        var provider = new FakeProvider(_ =>
        [new GeneratedConceptRevision("manual-1", "직접 쓴 개념", "원본 내용 테스트", [], "high")]);
        var request = new ReviseConceptsRequest(
            "notes-1", "사용자 자료", pageCount, "내용에 테스트를 추가해 줘.", ["manual-1"],
            [new ConceptRevisionContext("manual-1", "직접 쓴 개념", "원본 내용", [], "approved", "high")]);
        var response = await CreateService(provider).ReviseAsync(request, TestContext.Current.CancellationToken);
        var changed = Assert.Single(response.Revisions);
        Assert.Empty(changed.PageNumbers);
        Assert.Equal("원본 내용 테스트", changed.Content);
        Assert.Equal(pageCount, provider.LastInput!.PageCount);
        var schema = ConceptRevisionPrompt.BuildSchema(provider.LastInput);
        var pages = schema["properties"]!["revisions"]!["items"]!["properties"]!["pageNumbers"]!;
        Assert.Equal(0, pages["minItems"]!.GetValue<int>());
        Assert.Equal(pageCount, pages["maxItems"]!.GetValue<int>());
        Assert.Contains("always keep that array empty", ConceptRevisionPrompt.SystemPrompt);
    }

    [Fact]
    public async Task Revise_MixedPdfAndUserConceptsRejectsInventedProvenance()
    {
        var provider = new FakeProvider(_ =>
        [new GeneratedConceptRevision("manual-1", "메모", "수정 메모", [1])]);
        var request = Request() with {
            TargetConceptIds = ["manual-1"],
            Concepts = [.. Request().Concepts, new ConceptRevisionContext("manual-1", "메모", "원본 메모", [], "held")]
        };
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(request, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Revise_RejectsRemovingAllProvenanceFromExtractedConcept()
    {
        var provider = new FakeProvider(_ =>
        [new GeneratedConceptRevision("held-1", "가우스 법칙", "수정 내용", [])]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(Request(), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Revise_NonPdfMaterialRejectsPageNumbersBeforeCallingProvider()
    {
        var provider = new FakeProvider(_ => []);
        await Assert.ThrowsAsync<ConceptRevisionRequestException>(() => CreateService(provider).ReviseAsync(Request() with { PageCount = 0 }, TestContext.Current.CancellationToken));
        Assert.Null(provider.LastInput);
    }

    [Fact]
    public async Task Revise_AdditionsOnlyWorksForEmptyMaterialAndDoesNotInventIdsOrPages()
    {
        var provider = new FakeProvider(_ => [new GeneratedConceptRevision(
            "", "새 개념", "요청한 새로운 주제의 내용", [], "veryHigh", Kind: "add")]);
        var request = Request() with { Concepts = [], TargetConceptIds = [], PageCount = 0, AllowAdditions = true };
        var response = await CreateService(provider).ReviseAsync(request, TestContext.Current.CancellationToken);
        Assert.Empty(response.Revisions);
        Assert.Empty(response.Deletions);
        Assert.Empty(Assert.Single(response.Additions).PageNumbers);
        Assert.True(provider.LastInput!.AllowAdditions);
        var schema = ConceptRevisionPrompt.BuildSchema(provider.LastInput);
        Assert.Equal(0, schema["properties"]!["revisions"]!["maxItems"]!.GetValue<int>());
        Assert.Equal(20, schema["properties"]!["additions"]!["maxItems"]!.GetValue<int>());
    }

    [Theory]
    [InlineData("add")]
    [InlineData("delete")]
    public async Task Revise_RejectsUnpermittedStructuralChanges(string kind)
    {
        var provider = new FakeProvider(_ => [new GeneratedConceptRevision(
            kind == "add" ? "" : "held-1", "새 제목", "새 내용", [], Kind: kind, Reason: "요청한 변경")]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateService(provider).ReviseAsync(Request(), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Revise_ReturnsReplacementGroupAndExplicitDeletionReason()
    {
        var provider = new FakeProvider(_ => [
            new GeneratedConceptRevision("held-1", "", "", [], GroupId: "split", Kind: "delete", Reason: "개념 분할 요청"),
            new GeneratedConceptRevision("", "분할 개념 A", "내용 A", [3], "high", "split", "add", "개념 분할 요청"),
            new GeneratedConceptRevision("", "분할 개념 B", "내용 B", [4], "low", "split", "add", "개념 분할 요청")
        ]);
        var response = await CreateService(provider).ReviseAsync(
            Request() with { AllowAdditions = true, AllowDeletions = true }, TestContext.Current.CancellationToken);
        Assert.Equal(2, response.Additions.Count);
        Assert.All(response.Additions, item => Assert.Equal("split", item.GroupId));
        Assert.Equal("개념 분할 요청", Assert.Single(response.Deletions).Reason);
        Assert.Empty(response.Revisions);
    }

    [Theory]
    [InlineData("approved-1", "요청한 삭제")]
    [InlineData("held-1", "")]
    public async Task Revise_RejectsUnselectedOrUnexplainedDeletion(string id, string reason)
    {
        var provider = new FakeProvider(_ => [new GeneratedConceptRevision(id, "", "", [], Kind: "delete", Reason: reason)]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(
            Request() with { AllowDeletions = true }, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(5)]
    [InlineData(11)]
    public async Task Revise_RejectsAdditionPagesWithoutSelectedEvidence(int page)
    {
        var provider = new FakeProvider(_ => [new GeneratedConceptRevision("", "새 개념", "내용", [page], Kind: "add")]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(
            Request() with { AllowAdditions = true }, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Revise_RejectsDuplicateOperationsAndDuplicateNewTitles()
    {
        var provider = new FakeProvider(_ => [
            new GeneratedConceptRevision("held-1", "새 제목", "새 내용", [3]),
            new GeneratedConceptRevision("held-1", "", "", [], Kind: "delete", Reason: "중복")
        ]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(
            Request() with { AllowDeletions = true }, TestContext.Current.CancellationToken));
        provider = new FakeProvider(_ => [new GeneratedConceptRevision("", "가우스 법칙", "중복", [], Kind: "add")]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(
            Request() with { AllowAdditions = true }, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Revise_EnforcesAdditionLimit()
    {
        var provider = new FakeProvider(_ => Enumerable.Range(0, 21).Select(index =>
            new GeneratedConceptRevision("", $"개념 {index}", "내용", [], Kind: "add")).ToList());
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(provider).ReviseAsync(
            Request() with { AllowAdditions = true }, TestContext.Current.CancellationToken));
    }

    private static ConceptRevisionService CreateService(ILLMProvider provider, IConceptRevisionSourceReader? reader = null) =>
        new(
            new FixedLlmProviderResolver(provider),
            NullLogger<ConceptRevisionService>.Instance,
            reader ?? new FakeSourceReader());

    private sealed class FakeSourceReader(bool missing = false) : IConceptRevisionSourceReader
    {
        public Task<ConceptRevisionSource> ReadAsync(string id, int pageCount, IReadOnlyList<int> pages, string? hash, CancellationToken token) =>
            missing ? throw new DocumentImportException("원본 PDF가 없습니다.") :
                Task.FromResult(new ConceptRevisionSource([1], pages));
    }

    [Fact]
    public async Task Reference_MissingOriginalNeverFallsBackToTextOrCallsProvider()
    {
        var provider = new FakeProvider(_ => []);
        await Assert.ThrowsAsync<DocumentImportException>(() =>
            CreateService(provider, new FakeSourceReader(missing: true))
                .ReviseAsync(Request(), TestContext.Current.CancellationToken));
        Assert.Null(provider.LastInput);
    }

    [Fact]
    public async Task Reference_RejectsUnattachedProvenanceOnUpdatesEvenIfWithinMaterial()
    {
        var provider = new FakeProvider(_ => [new("held-1", "수정 제목", "수정 내용", [5])]);
        await Assert.ThrowsAsync<LlmProviderRequestException>(() =>
            CreateService(provider).ReviseAsync(Request(), TestContext.Current.CancellationToken));
        Assert.Equal([3, 4, 6], provider.LastInput!.Source!.OriginalPages);
    }

    private static ReviseConceptsRequest Request() => new(
        "source-1",
        "전자기학.pdf",
        10,
        "설명을 더 자연스럽게 수정해 줘.",
        ["held-1", "held-2"],
        [
            new ConceptRevisionContext(
                "held-1",
                "가우스 법칙",
                "전기선속과 전하의 관계",
                [3, 4],
                "held"),
            new ConceptRevisionContext(
                "held-2",
                "전위",
                "단위 전하당 위치 에너지",
                [6],
                "held"),
            new ConceptRevisionContext(
                "approved-1",
                "쿨롱 법칙",
                "두 전하 사이의 힘",
                [5],
                "approved")
        ]);

    [Fact]
    public async Task Feedback_ClarificationAndNoChangesPreserveComments_AndHistoryIsForwarded()
    {
        var request = Request() with { Clarifications = [new("어떤 범위인가요?", "  첫 개념의 본문만  ")] };
        foreach (var status in new[] { "needsClarification", "noChanges" })
        {
            var question = status == "needsClarification" ? "어느 부분을 삭제할까요?" : "";
            var fake = new FakeProvider(_ => [], new(status, "원문 확인 후 요청 범위를 확인합니다.", question, []));
            var response = await CreateService(fake).ReviseAsync(request, TestContext.Current.CancellationToken);
            Assert.Equal(status, response.Status);
            Assert.Equal(question, response.ClarificationQuestion);
            Assert.Equal("원문 확인 후 요청 범위를 확인합니다.", response.Comment);
            Assert.Empty(response.Revisions);
            Assert.Empty(response.Additions);
            Assert.Empty(response.Deletions);
            Assert.Equal("첫 개념의 본문만", Assert.Single(fake.LastInput!.Clarifications!).Answer);
            Assert.Equal([3, 4, 6], fake.LastInput.Source!.OriginalPages);
        }
    }

    [Theory]
    [InlineData("needsClarification", "질문", true)]
    [InlineData("needsClarification", "", false)]
    [InlineData("noChanges", "", true)]
    [InlineData("ready", "질문", true)]
    [InlineData("ready", "", false)]
    [InlineData("unknown", "", false)]
    public async Task Feedback_RejectsContradictoryStates(string status, string question, bool changed)
    {
        var changes = changed ? new[] { new GeneratedConceptRevision("held-1", "제목", "수정 내용", [3], Reason: "요청 반영") } : [];
        var fake = new FakeProvider(_ => [], new(status, "처리 결과", question, changes));
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(fake).ReviseAsync(Request(), TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    public async Task Feedback_RejectsMissingCommentOrChangeReason(string empty)
    {
        var change = new GeneratedConceptRevision("held-1", "제목", "수정 내용", [3], Reason: "요청 반영");
        var fake = new FakeProvider(_ => [], new("ready", empty, "", [change]));
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(fake).ReviseAsync(Request(), TestContext.Current.CancellationToken));
        fake = new FakeProvider(_ => [], new("ready", "처리 결과", "", [change with { Reason = empty }]));
        await Assert.ThrowsAsync<LlmProviderRequestException>(() => CreateService(fake).ReviseAsync(Request(), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Feedback_ChangeReasonSurvivesValidation_AndUnsupportedPdfNeverCallsProvider()
    {
        var fake = new FakeProvider(_ => [new("held-1", "제목", "수정 내용", [3], Reason: "원본과 대조하여 표현을 교정했습니다.")]);
        var response = await CreateService(fake).ReviseAsync(Request(), TestContext.Current.CancellationToken);
        Assert.Equal("원본과 대조하여 표현을 교정했습니다.", Assert.Single(response.Revisions).Reason);
        fake = new FakeProvider(_ => [], supportsPdf: false);
        await Assert.ThrowsAsync<LlmProviderUnavailableException>(() => CreateService(fake).ReviseAsync(Request(), TestContext.Current.CancellationToken));
        Assert.Null(fake.LastInput);
        var manual = Request() with { TargetConceptIds = ["held-1"], Concepts = [Request().Concepts[0] with { PageNumbers = [] }] };
        await CreateService(fake).ReviseAsync(manual, TestContext.Current.CancellationToken);
        Assert.Null(fake.LastInput!.Source);
    }

    [Fact]
    public async Task Feedback_RejectsExcessiveOrEmptyClarificationHistoryBeforeCallingProvider()
    {
        var fake = new FakeProvider(_ => []);
        foreach (var history in new IReadOnlyList<ConceptRevisionClarification>[] {
            Enumerable.Repeat(new ConceptRevisionClarification("질문", "답변"), 11).ToArray(), [new("질문", " ")], [new("", "답변")] })
        {
            await Assert.ThrowsAsync<ConceptRevisionRequestException>(() => CreateService(fake).ReviseAsync(Request() with { Clarifications = history }, TestContext.Current.CancellationToken));
            Assert.Null(fake.LastInput);
        }
    }

    [Fact]
    public async Task Revise_RejectsUnknownTargetConcept()
    {
        var provider = new FakeProvider(_ => []);
        var service = CreateService(provider);
        var request = Request() with { TargetConceptIds = ["missing"] };

        var exception = await Assert.ThrowsAsync<ConceptRevisionRequestException>(
            () => service.ReviseAsync(
                request,
                TestContext.Current.CancellationToken));

        Assert.Contains("수정 대상", exception.Message);
    }

    private sealed class FakeProvider(
        Func<ConceptRevisionInput, IReadOnlyList<GeneratedConceptRevision>> result,
        ConceptRevisionResult? feedback = null,
        bool supportsPdf = true)
        : ILLMProvider
    {
        public string ProviderName => "fake";

        public string ModelName => "fake-model";
        public bool SupportsRevisionPdf => supportsPdf;

        public ConceptRevisionInput? LastInput { get; private set; }

        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<GeneratedQuestionDraft>>([]);

        public Task<ConceptRevisionResult> ReviseConceptsAsync(
            ConceptRevisionInput input,
            CancellationToken cancellationToken = default)
        {
            LastInput = input;
            if (feedback is not null) return Task.FromResult(feedback);
            var changes = result(input).Select(item => item with { Reason = item.Reason.Length == 0 && item.Kind != "delete" ? "요청 반영" : item.Reason }).ToList();
            return Task.FromResult(new ConceptRevisionResult(changes.Count == 0 ? "noChanges" : "ready", "요청을 반영했습니다.", "", changes));
        }
    }
}
