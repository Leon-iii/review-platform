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
builder.Services.AddHttpClient<OpenAiLlmProvider>(client =>
{
    client.Timeout = TimeSpan.FromSeconds(90);
});
builder.Services.AddHttpClient<OllamaLlmProvider>(client =>
{
    client.Timeout = TimeSpan.FromMinutes(5);
});
builder.Services.AddScoped<LlmProviderSelector>();
builder.Services.AddScoped<ILLMProvider>(services =>
    services.GetRequiredService<LlmProviderSelector>().Select());

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var database = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
    await ServerDatabaseInitializer.InitializeAsync(database);
}

app.UseMiddleware<SyncTokenMiddleware>();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/api/ai/ollama/status", async (
    OllamaLlmProvider provider,
    CancellationToken cancellationToken) =>
{
    var status = await provider.CheckStatusAsync(cancellationToken);
    return Results.Ok(new
    {
        provider = "ollama",
        model = status.Model,
        reachable = status.Reachable,
        modelInstalled = status.ModelInstalled
    });
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

app.Run();

public partial class Program;
