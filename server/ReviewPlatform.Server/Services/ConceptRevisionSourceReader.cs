using System.Security.Cryptography;
using ReviewPlatform.Server.Contracts;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;

namespace ReviewPlatform.Server.Services;

public interface IConceptRevisionSourceReader
{
    Task<ConceptRevisionSource> ReadAsync(string sourceId, int pageCount,
        IReadOnlyList<int> pages, string? contentHash, CancellationToken token);
}

public sealed partial class DocumentProcessingService : IConceptRevisionSourceReader
{
    // Independent of extraction checkpoints, active extraction profiles, and import limits.
    public async Task<ConceptRevisionSource> ReadAsync(string sourceId, int pageCount,
        IReadOnlyList<int> pages, string? contentHash, CancellationToken token)
    {
        var path = StoredPdfPath(sourceId);
        if (!File.Exists(path))
            throw new DocumentImportException("서버에 원본 PDF가 없습니다. 원본이 보관된 서버에 연결해 주세요.");
        try
        {
            var bytes = await File.ReadAllBytesAsync(path, token);
            if (!string.IsNullOrWhiteSpace(contentHash) &&
                !Convert.ToHexString(SHA256.HashData(bytes)).Equals(contentHash, StringComparison.OrdinalIgnoreCase))
                throw new DocumentImportException("서버의 원본 PDF가 현재 자료와 일치하지 않습니다. 자료와 서버 연결을 확인해 주세요.");
            using var document = PdfDocument.Open(bytes);
            var selected = pages.Distinct().Order().ToArray();
            if (document.NumberOfPages != pageCount || selected.Length == 0 ||
                selected.Any(page => page < 1 || page > document.NumberOfPages))
                throw new DocumentImportException("개념 출처 페이지와 원본 PDF가 일치하지 않습니다.");
            var builder = new PdfDocumentBuilder();
            foreach (var page in selected)
            {
                token.ThrowIfCancellationRequested();
                builder.AddPage(document, page);
            }
            var excerpt = builder.Build();
            if (excerpt.LongLength >= 50L * 1024 * 1024)
                throw new DocumentImportException("첨부할 원본 페이지가 50MB 이상입니다. 수정할 개념을 줄여 주세요.");
            return new(excerpt, selected);
        }
        catch (DocumentImportException) { throw; }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            throw new DocumentImportException("수정 참고용 원본 PDF를 읽지 못했습니다. 파일 손상 또는 암호화를 확인해 주세요.", exception);
        }
    }
}
