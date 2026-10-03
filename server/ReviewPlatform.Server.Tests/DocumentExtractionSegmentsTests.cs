using ReviewPlatform.Server.Services;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class DocumentExtractionSegmentsTests
{
    [Fact]
    public void LongDiagram_RetainsKindAndIndependentBoundariesInEverySegment()
    {
        var content = string.Concat(Enumerable.Repeat("A → B 😀 설명\n", 120));
        var marked = "[USER_INDEPENDENT_REGION_START][CONTENT_KIND:diagram]" + content +
            "[/CONTENT_KIND][USER_INDEPENDENT_REGION_END]";
        var segments = DocumentExtractionSegments.Split(marked, 256);
        Assert.True(segments.Count > 1);
        Assert.All(segments, segment => {
            Assert.InRange(segment.Length, 1, 256);
            Assert.StartsWith("[USER_INDEPENDENT_REGION_START][CONTENT_KIND:diagram]", segment);
            Assert.EndsWith("[/CONTENT_KIND][USER_INDEPENDENT_REGION_END]", segment);
        });
        var restored = string.Concat(segments.Select(segment => segment
            .Replace("[USER_INDEPENDENT_REGION_START]", "").Replace("[USER_INDEPENDENT_REGION_END]", "")
            .Replace("[CONTENT_KIND:diagram]", "").Replace("[/CONTENT_KIND]", "")));
        Assert.Equal(content, restored);
        Assert.All(segments, segment => Assert.DoesNotContain('\uFFFD', segment));
    }

    [Fact]
    public void MixedKindsAndPlainText_DoNotLeakIntoAdjacentRegions()
    {
        var diagram = "[CONTENT_KIND:diagram]" + new string('D', 340) + "[/CONTENT_KIND]";
        var table = "[CONTENT_KIND:table]" + new string('T', 340) + "[/CONTENT_KIND]";
        var segments = DocumentExtractionSegments.Split("前" + diagram + "本文" + table + "後", 256);
        var plain = string.Concat(segments.Select(segment => segment.Replace("[CONTENT_KIND:diagram]", "")
            .Replace("[CONTENT_KIND:table]", "").Replace("[/CONTENT_KIND]", "")));
        Assert.Equal("前" + new string('D', 340) + "本文" + new string('T', 340) + "後", plain);
        Assert.All(segments, segment => Assert.InRange(segment.Length, 1, 256));
    }
}
