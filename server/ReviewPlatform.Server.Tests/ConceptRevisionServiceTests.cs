using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptRevisionServiceTests
{
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

    private static ConceptRevisionService CreateService(ILLMProvider provider) =>
        new(
            new FixedLlmProviderResolver(provider),
            NullLogger<ConceptRevisionService>.Instance);

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
        Func<ConceptRevisionInput, IReadOnlyList<GeneratedConceptRevision>> result)
        : ILLMProvider
    {
        public string ProviderName => "fake";

        public string ModelName => "fake-model";

        public ConceptRevisionInput? LastInput { get; private set; }

        public Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
            QuestionGenerationInput input,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<GeneratedQuestionDraft>>([]);

        public Task<IReadOnlyList<GeneratedConceptRevision>> ReviseConceptsAsync(
            ConceptRevisionInput input,
            CancellationToken cancellationToken = default)
        {
            LastInput = input;
            return Task.FromResult(result(input));
        }
    }
}
