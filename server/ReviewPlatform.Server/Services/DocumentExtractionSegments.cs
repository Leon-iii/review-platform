using System.Text;
using System.Text.RegularExpressions;

namespace ReviewPlatform.Server.Services;

// Repeat metadata boundaries when a large region crosses an LLM batch. Never
// let the second half of a diagram/table lose its kind or user independence.
public static class DocumentExtractionSegments
{
    private static readonly Regex Boundaries = new(
        @"\[(?:CONTENT_KIND:(?:text|diagram|table|uncertain)|/CONTENT_KIND|VISUAL_REGION_(?:START|END)|USER_INDEPENDENT_REGION_(?:START|END))\]",
        RegexOptions.Compiled);

    public static IReadOnlyList<string> Split(string text, int limit)
    {
        if (limit < 256) throw new ArgumentOutOfRangeException(nameof(limit));
        if (text.Length <= limit) return [text];
        var output = new List<string>();
        var open = new List<(string Start, string End)>();
        var current = new StringBuilder();
        var hasBody = false;
        var position = 0;
        foreach (Match marker in Boundaries.Matches(text))
        {
            AppendText(text[position..marker.Index]);
            var token = marker.Value;
            var end = token.StartsWith("[CONTENT_KIND:", StringComparison.Ordinal) ? "[/CONTENT_KIND]"
                : token == "[VISUAL_REGION_START]" ? "[VISUAL_REGION_END]"
                : token == "[USER_INDEPENDENT_REGION_START]" ? "[USER_INDEPENDENT_REGION_END]" : null;
            if (end is not null)
            {
                if (current.Length + token.Length + ClosingLength() + end.Length > limit && hasBody) Flush();
                current.Append(token);
                open.Add((token, end));
                if (current.Length + ClosingLength() >= limit)
                    throw new DocumentImportException("문서 영역 경계가 지나치게 중첩되어 개념 추출을 진행할 수 없습니다.");
            }
            else if (open.Count > 0 && open[^1].End == token)
            {
                current.Append(token);
                open.RemoveAt(open.Count - 1);
            }
            else AppendText(token); // Historical unmatched markers remain source text.
            position = marker.Index + marker.Length;
        }
        AppendText(text[position..]);
        if (current.Length > 0 && hasBody) Flush();
        return output;

        int ClosingLength() => open.Sum(boundary => boundary.End.Length);
        void Flush()
        {
            output.Add(current.ToString() + string.Concat(open.AsEnumerable().Reverse().Select(boundary => boundary.End)));
            current.Clear();
            foreach (var boundary in open) current.Append(boundary.Start);
            hasBody = false;
        }
        void AppendText(string value)
        {
            var offset = 0;
            while (offset < value.Length)
            {
                var count = Math.Min(limit - current.Length - ClosingLength(), value.Length - offset);
                if (count > 0 && offset + count < value.Length && char.IsHighSurrogate(value[offset + count - 1]) &&
                    char.IsLowSurrogate(value[offset + count])) count--;
                if (count <= 0)
                {
                    if (!hasBody) throw new DocumentImportException("문서 영역 경계를 처리하지 못했습니다.");
                    Flush();
                    continue;
                }
                current.Append(value, offset, count);
                hasBody = true;
                offset += count;
            }
        }
    }
}
