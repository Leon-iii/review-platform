using Microsoft.Extensions.Logging.Abstractions;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class ConceptRevisionServiceTests
{
    [Fact]
    public async Task Revise_UnapprovedScopeSendsAllConceptsAndReturnsOnlyActualChanges()
    {
        var provider = new FakeProvider(input =>
        [
            new GeneratedConceptRevision(
                "held-1",
                "가우스 법칙",
                "폐곡면의 전기선속과 내부 전하의 관계를 설명한다.",
                [4, 3]),
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
    }

    [Fact]
    public async Task Revise_RejectsRevisionForApprovedConceptInUnapprovedScope()
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

    private static ConceptRevisionService CreateService(ILLMProvider provider) =>
        new(
            new FixedLlmProviderResolver(provider),
            NullLogger<ConceptRevisionService>.Instance);

    private static ReviseConceptsRequest Request() => new(
        "source-1",
        "전자기학.pdf",
        10,
        "설명을 더 자연스럽게 수정해 줘.",
        ConceptRevisionScopes.Unapproved,
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
