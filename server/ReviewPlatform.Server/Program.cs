using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Auth;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;

var builder = WebApplication.CreateBuilder(args);

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
builder.Services.AddScoped<ConceptRevisionService>();
builder.Services.AddScoped<LlmProfileService>();
builder.Services.AddScoped<LlmModelCatalogService>();
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
    catch (LlmProfileValidationException exception)
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
