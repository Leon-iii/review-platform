using Microsoft.EntityFrameworkCore;
using ReviewPlatform.Server.Auth;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Data;
using ReviewPlatform.Server.Services;

var builder = WebApplication.CreateBuilder(args);

var connectionString = builder.Configuration.GetConnectionString("SyncDatabase")
    ?? "Data Source=review-platform-sync.db";
builder.Services.AddDbContext<SyncDbContext>(options =>
    options.UseSqlite(connectionString));
builder.Services.Configure<SyncAuthOptions>(builder.Configuration.GetSection("Sync"));
builder.Services.AddScoped<SyncService>();

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var database = scope.ServiceProvider.GetRequiredService<SyncDbContext>();
    await database.Database.EnsureCreatedAsync();
}

app.UseMiddleware<SyncTokenMiddleware>();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

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

app.Run();

public partial class Program;
