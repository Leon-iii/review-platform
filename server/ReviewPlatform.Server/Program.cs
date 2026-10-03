using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Auth;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;

var builder = WebApplication.CreateBuilder(args);
var documentLimits = builder.Configuration.GetSection("Documents").Get<DocumentLimits>() ?? new();
if (documentLimits.MaximumFileSizeMb is < 1 or > 2048 ||
    documentLimits.MaximumPages is < 1 or > 10000 ||
    documentLimits.MaximumExtractedCharacters is < 20 or > 10000000 ||
    documentLimits.MinimumFreeDiskSpaceMb < 0 || documentLimits.MaximumPendingJobs is < 1 or > 100)
    throw new InvalidOperationException("Documents safety limits are invalid.");

// The Windows app captures stdout/stderr. Avoid the default Windows Event Log
// provider, which may require elevated permissions when writing warnings.
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.AddDebug();

var connectionString = builder.Configuration.GetConnectionString("SyncDatabase")
    ?? "Data Source=review-platform-sync.db";
builder.Services.AddDbContext<SyncDbContext>(options =>
    options.UseSqlite(connectionString));
builder.Services.Configure<SyncAuthOptions>(builder.Configuration.GetSection("Sync"));
builder.Services.AddDataProtection()
    .SetApplicationName("ReviewPlatform.Server");
builder.Services.AddOptions<LlmOptions>()
    .Bind(builder.Configuration.GetSection("Llm"))
    .Validate(
        options => options.Provider.Equals(
                "openai",
                StringComparison.OrdinalIgnoreCase) ||
            options.Provider.Equals(
                "ollama",
                StringComparison.OrdinalIgnoreCase),
        "Llm:Provider must be 'openai' or 'ollama'.")
    .ValidateOnStart();
builder.Services.PostConfigure<LlmOptions>(options =>
{
    if (string.IsNullOrWhiteSpace(options.ApiKey))
    {
        options.ApiKey = builder.Configuration["OPENAI_API_KEY"] ?? string.Empty;
    }
});
builder.Services.AddScoped<SyncService>();
builder.Services.AddScoped<QuestionGenerationService>();
builder.Services.AddScoped<DocumentProcessingService>();
builder.Services.AddScoped<DocumentJobService>();
builder.Services.AddSingleton<DocumentJobSignals>();
builder.Services.AddHostedService<DocumentJobWorker>();
builder.Services.AddScoped<ConceptRevisionService>();
builder.Services.AddScoped<LlmProfileService>();
builder.Services.AddScoped<ILlmApiKeyStore, LlmApiKeyStore>();
builder.Services.AddScoped<LlmModelCatalogService>();
builder.Services.AddScoped<OllamaModelMetadataService>();
builder.Services.AddScoped<ILlmProviderResolver, RuntimeLlmProviderResolver>();
builder.Services.AddSingleton<IPdfTextExtractor, PdfPigTextExtractor>();
builder.Services.AddSingleton<IPdfPageRenderer, PdfiumPageRenderer>();
builder.Services.AddSingleton<IDocumentPageTextCache, FileDocumentPageTextCache>();
builder.Services.AddHttpClient("openai", client =>
{
    client.Timeout = TimeSpan.FromSeconds(90);
});
builder.Services.AddHttpClient("ollama", client =>
{
    client.Timeout = TimeSpan.FromMinutes(10);
});

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var database = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
    await ServerDatabaseInitializer.InitializeAsync(database);
    await scope.ServiceProvider.GetRequiredService<LlmProfileService>()
        .EnsureInitializedAsync();
}

app.UseMiddleware<SyncTokenMiddleware>();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/api/documents/limits", () => Results.Ok(documentLimits));
app.MapPost("/api/documents/jobs/{id}", async (string id, string fileName,
    HttpRequest request, DocumentJobService service, CancellationToken cancellationToken) =>
{
    try
    {
        var bodyLimit = request.HttpContext.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (bodyLimit is { IsReadOnly: false }) bodyLimit.MaxRequestBodySize = documentLimits.MaximumFileSize;
        if (!bool.TryParse(request.Query["reviewBeforeConcepts"].FirstOrDefault() ?? "false", out var reviewBeforeConcepts))
            return Results.BadRequest(new { error = "OCR 검토 설정이 올바르지 않습니다." });
        return Results.Json(await service.UploadAsync(id, fileName, request.Body,
            request.ContentLength ?? 0, cancellationToken, reviewBeforeConcepts), statusCode: StatusCodes.Status202Accepted);
    }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
    catch (LlmProviderUnavailableException exception)
    {
        return Results.Json(new { error = exception.Message }, statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    catch (IOException) { return Results.BadRequest(new { error = "PDF 파일을 저장하지 못했습니다. 다시 시도해 주세요." }); }
});
app.MapGet("/api/documents/jobs/{id}", async (string id, DocumentJobService service,
    CancellationToken cancellationToken) => await service.GetAsync(id, cancellationToken) is { } result
        ? Results.Ok(result) : Results.NotFound(new { error = "PDF 분석 작업을 찾을 수 없습니다." }));
app.MapGet("/api/documents/jobs/{id}/result", async (string id, DocumentJobService service,
    CancellationToken cancellationToken) => await service.GetResultAsync(id, cancellationToken) is { } json
        ? Results.Content(json, "application/json")
        : Results.NotFound(new { error = "PDF 분석 결과가 아직 준비되지 않았습니다." }));
app.MapDelete("/api/documents/jobs/{id}", async (string id, DocumentJobService service,
    CancellationToken cancellationToken) =>
{
    try
    {
        await service.DeleteAsync(id, cancellationToken);
        return Results.NoContent();
    }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
});

app.MapPost("/api/documents/jobs/{id}/cancel", async (string id, DocumentJobService service,
    CancellationToken cancellationToken) => await service.CancelAsync(id, cancellationToken) is { } result
        ? Results.Ok(result) : Results.NotFound());
app.MapPost("/api/documents/jobs/{id}/retry", async (string id, DocumentJobService service,
    CancellationToken cancellationToken) =>
{
    try
    {
        return await service.RetryAsync(id, cancellationToken) is { } result ? Results.Ok(result) : Results.NotFound();
    }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
});

app.MapGet("/api/documents/jobs/{id}/review/pages/{pageNumber:int}", async (string id, int pageNumber,
    DocumentJobService service, CancellationToken cancellationToken) =>
{
    try { return Results.Ok(await service.GetReviewPageAsync(id, pageNumber, cancellationToken)); }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
});
app.MapPut("/api/documents/jobs/{id}/review/pages/{pageNumber:int}", async (string id, int pageNumber,
    SaveDocumentReviewRequest request, DocumentJobService service, CancellationToken cancellationToken) =>
{
    try { return Results.Ok(await service.SaveReviewPageAsync(id, pageNumber, request, cancellationToken)); }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
});
app.MapGet("/api/documents/jobs/{id}/review/pages/{pageNumber:int}/image", async (string id, int pageNumber,
    DocumentJobService service, CancellationToken cancellationToken) =>
{
    try
    {
        var image = await service.GetReviewImageAsync(id, pageNumber, cancellationToken);
        return Results.File(image.ImageBytes, image.MimeType);
    }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
});
app.MapPost("/api/documents/jobs/{id}/review/confirm", async (string id, ConfirmDocumentReviewRequest request,
    DocumentJobService service, CancellationToken cancellationToken) =>
{
    try { return Results.Ok(await service.ConfirmReviewAsync(id, request, cancellationToken)); }
    catch (DocumentImportException exception) { return Results.BadRequest(new { error = exception.Message }); }
});

app.MapGet("/api/ai/ollama/status", async (
    ILlmProviderResolver resolver,
    CancellationToken cancellationToken) =>
{
    var selected = await resolver.ResolveAsync(
        LlmPurposes.QuestionGeneration,
        cancellationToken);
    if (selected is not OllamaLlmProvider provider)
    {
        return Results.Ok(new
        {
            provider = selected.ProviderName,
            model = selected.ModelName,
            reachable = false,
            modelInstalled = false
        });
    }
    var status = await provider.CheckStatusAsync(cancellationToken);
    return Results.Ok(new
    {
        provider = "ollama",
        model = status.Model,
        reachable = status.Reachable,
        modelInstalled = status.ModelInstalled
    });
});

app.MapGet("/api/llm/settings", async (
    LlmProfileService profileService,
    CancellationToken cancellationToken) =>
    Results.Ok(await profileService.GetSettingsAsync(cancellationToken)));

app.MapPut("/api/llm/settings", async (
    UpdateLlmProfileSettingsRequest request,
    LlmProfileService profileService,
    CancellationToken cancellationToken) =>
{
    try
    {
        return Results.Ok(await profileService.UpdateSettingsAsync(
            request,
            cancellationToken));
    }
    catch (Exception exception) when (
        exception is LlmProfileValidationException or LlmApiKeyStoreException)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
});

app.MapGet("/api/llm/models", async (
    string? provider,
    LlmModelCatalogService catalogService,
    CancellationToken cancellationToken) =>
{
    try
    {
        return Results.Ok(await catalogService.GetModelsAsync(
            provider,
            cancellationToken));
    }
    catch (LlmModelCatalogException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

app.MapPost("/api/sync/push", async (
    PushRequest request,
    SyncService syncService,
    CancellationToken cancellationToken) =>
{
    try
    {
        return Results.Ok(await syncService.PushAsync(request, cancellationToken));
    }
    catch (SyncValidationException exception)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
});

app.MapGet("/api/sync/pull", async (
    long? sinceRevision,
    int? limit,
    SyncService syncService,
    CancellationToken cancellationToken) =>
{
    var response = await syncService.PullAsync(
        sinceRevision ?? 0,
        Math.Clamp(limit ?? 500, 1, 1000),
        cancellationToken);
    return Results.Ok(response);
});

app.MapPost("/api/ai/questions/generate", async (
    GenerateQuestionsRequest request,
    QuestionGenerationService generationService,
    CancellationToken cancellationToken) =>
{
    try
    {
        return Results.Ok(await generationService.GenerateAsync(
            request,
            cancellationToken));
    }
    catch (QuestionGenerationRequestException exception)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
    catch (LlmProviderUnavailableException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    catch (LlmOutputValidationException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status502BadGateway);
    }
    catch (LlmProviderRequestException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status502BadGateway);
    }
});

app.MapPost("/api/documents/import", async (
    HttpRequest request,
    DocumentProcessingService processingService,
    CancellationToken cancellationToken) =>
{
    try
    {
        if (!request.HasFormContentType)
        {
            return Results.BadRequest(new { error = "PDF 파일을 첨부해 주세요." });
        }
        var form = await request.ReadFormAsync(cancellationToken);
        var file = form.Files.GetFile("file");
        if (file is null)
        {
            return Results.BadRequest(new { error = "PDF 파일을 첨부해 주세요." });
        }
        await using var stream = file.OpenReadStream();
        var response = await processingService.ImportPdfAsync(
            stream,
            file.FileName,
            file.Length,
            cancellationToken);
        return Results.Ok(response);
    }
    catch (DocumentImportException exception)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
    catch (LlmProviderUnavailableException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    catch (LlmProviderRequestException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status502BadGateway);
    }
});

app.MapPost("/api/documents/concepts/revise", async (
    ReviseConceptsRequest request,
    ConceptRevisionService revisionService,
    CancellationToken cancellationToken) =>
{
    try
    {
        return Results.Ok(await revisionService.ReviseAsync(
            request,
            cancellationToken));
    }
    catch (ConceptRevisionRequestException exception)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
    catch (LlmProviderUnavailableException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    catch (LlmProviderRequestException exception)
    {
        return Results.Json(
            new { error = exception.Message },
            statusCode: StatusCodes.Status502BadGateway);
    }
});

app.MapDelete("/api/documents/{sourceId}", (
    string sourceId,
    DocumentProcessingService processingService) =>
{
    try
    {
        processingService.DeletePdf(sourceId);
        return Results.NoContent();
    }
    catch (DocumentImportException exception)
    {
        return Results.BadRequest(new { error = exception.Message });
    }
});

app.Run();

public partial class Program;
