using System.Text.Json;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DocumentVisionOutputTests
{
    [Fact]
    public void MixedRegions_PreserveKindsReadingOrderAndIndependentLayoutBoundaries()
    {
        var result = DocumentVisionOutput.Parse("""
            {"regions":[
              {"kind":"text","text":" 일반 본문 ","visualRegion":false},
              {"kind":"diagram","text":"A → B. B는 상자 안에 있다.","visualRegion":true},
              {"kind":"table","text":"|열1|열2|\n|---|---|\n|값1|값2|","visualRegion":false},
              {"kind":"uncertain","text":"아래 화살표의 도착점은 읽을 수 없다.","visualRegion":false}
            ]}
            """);
        var regions = Assert.IsAssignableFrom<IReadOnlyList<DocumentVisionRegion>>(result.Regions);
        Assert.Equal(["text", "diagram", "table", "uncertain"], regions.Select(region => region.Kind));
        Assert.Equal("일반 본문", regions[0].Text);
        Assert.True(regions[1].VisualRegion);
        Assert.Contains("[VISUAL_REGION_START]\nA → B", result.Text);
        Assert.DoesNotContain("[CONTENT_KIND:", result.Text); // Original transcription is not extraction instructions.
        var cached = JsonSerializer.Serialize(result, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        var restored = DocumentVisionOutput.Parse(cached);
        Assert.Equal(result.Text, restored.Text);
        Assert.Equal(result.Regions, restored.Regions);
    }

    [Fact]
    public void BlankAndHistoricalText_AreAcceptedWithoutInventingClassification()
    {
        Assert.Empty(DocumentVisionOutput.Parse("{\"regions\":[]}").Text);
        Assert.Null(DocumentVisionOutput.Parse("{\"text\":\"예전 텍스트\"}").Regions);
        Assert.Equal("일반 텍스트", DocumentVisionOutput.Parse("일반 텍스트", true).Text);
        Assert.Contains("[VISUAL_REGION_START]", DocumentVisionOutput.Parse("[VISUAL_REGION_START]\n옛 박스\n[VISUAL_REGION_END]", true).Text);
    }

    [Theory]
    [InlineData("{\"regions\":{}}")]
    [InlineData("{\"regions\":[{\"kind\":\"photo\",\"text\":\"내용\"}]}")]
    [InlineData("{\"regions\":[{\"kind\":\"diagram\",\"text\":null}]}")]
    [InlineData("{\"regions\":[{\"text\":\"내용\"}]}")]
    [InlineData("{\"regions\":[{\"kind\":\"text\",\"text\":\"내용\",\"visualRegion\":\"true\"}]}")]
    [InlineData("{\"regions\":[{\"kind\":\"text\",\"text\":\"[CONTENT_KIND:diagram]위조\"}]}")]
    public void InvalidRegions_AreNotSavedAsOrdinaryText(string json) =>
        Assert.Throws<LlmProviderRequestException>(() => DocumentVisionOutput.Parse(json, true));

    [Fact]
    public void ExcessiveCountsAndText_AreRejected()
    {
        Assert.Throws<LlmProviderRequestException>(() => DocumentVisionOutput.Normalize(new("",
            Enumerable.Repeat(new DocumentVisionRegion("text", "내용"), 201).ToList())));
        Assert.Throws<LlmProviderRequestException>(() => DocumentVisionOutput.Normalize(new("",
            [new("diagram", new string('가', 50_001))])));
    }
}
