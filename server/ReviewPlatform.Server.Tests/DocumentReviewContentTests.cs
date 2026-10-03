using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DocumentReviewContentTests
{
    [Fact]
    public void HybridRegions_HaveOneCanonicalCopy_AndKeepOriginalUntouched()
    {
        const string original = "원문 중복\n\n[페이지 시각 정보]\n연표 앞\n[VISUAL_REGION_START]\n박스 내용\n[VISUAL_REGION_END]\n연표 뒤";
        var page = new ExtractedDocumentPage(1, original, "hybrid");
        var blocks = DocumentReviewContent.DefaultBlocks(page);
        Assert.Equal(["연표 앞", "박스 내용", "연표 뒤"], blocks.Select(block => block.Text));
        Assert.True(blocks[1].VisualRegion);
        Assert.False(blocks[1].Independent); // Visual boundary is a clue, not user intent.
        Assert.Equal(original, page.Text);
    }

    [Fact]
    public void UserBoundaryAndExclusions_AreAppliedWithoutChangingOriginalCheckpointPages()
    {
        var checkpoint = new DocumentCheckpoint {
            Pages = [new ExtractedDocumentPage(1, "원래 내용")],
            ReviewPages = new() { [1] = [new("독립 원칙", true, Kind: "text"), new("삭제할 내용", Excluded: true)] }
        };
        var reviewed = DocumentReviewContent.ConfirmedPages(checkpoint);
        Assert.Equal("원래 내용", Assert.Single(checkpoint.Pages).Text);
        Assert.Equal("[USER_INDEPENDENT_REGION_START]\n독립 원칙\n[USER_INDEPENDENT_REGION_END]", Assert.Single(reviewed).Text);
    }

    [Fact]
    public void BrokenMarkers_DoNotDiscardText()
    {
        const string text = "앞부분\n[VISUAL_REGION_START]\n닫는 표시가 없는 원문";
        Assert.Equal(text, Assert.Single(DocumentReviewContent.DefaultBlocks(new(1, text))).Text);
    }

    [Fact]
    public void TypedRegions_RemainSeparateFromUserIndependence_AndReachExtraction()
    {
        var page = new ExtractedDocumentPage(1, "텍스트 레이어\n\n[페이지 시각 정보]\nOCR 원문", "hybrid", Regions: [
            new("text", "본문"), new("diagram", "A → B", true), new("table", "|A|B|"), new("uncertain", "읽기 어려운 연결")
        ]);
        var blocks = DocumentReviewContent.DefaultBlocks(page);
        Assert.Equal(["text", "diagram", "table", "uncertain"], blocks.Select(block => block.Kind));
        Assert.All(blocks, block => Assert.False(block.Independent));
        var automatic = Assert.Single(DocumentReviewContent.AnnotatedPages([page])).Text;
        Assert.Contains("텍스트 레이어", automatic);
        Assert.Contains("[CONTENT_KIND:diagram]", automatic);
        var reviewed = DocumentReviewContent.BuildText(blocks.Select(block => block with {
            Independent = block.Kind == "diagram", Excluded = block.Kind == "uncertain" }));
        Assert.Contains("[USER_INDEPENDENT_REGION_START]\n[CONTENT_KIND:diagram]", reviewed);
        Assert.DoesNotContain("읽기 어려운", reviewed);
        Assert.Equal("OCR 원문", page.Text.Split("[페이지 시각 정보]")[1].Trim());
    }

    [Fact]
    public void HistoricalVisionIsUnclassified_WhereasTextLayerIsOrdinaryText()
    {
        Assert.Equal("uncertain", Assert.Single(DocumentReviewContent.DefaultBlocks(new(1, "옛 OCR", "visionOcr"))).Kind);
        Assert.Equal("text", Assert.Single(DocumentReviewContent.DefaultBlocks(new(1, "텍스트 레이어"))).Kind);
    }
}
