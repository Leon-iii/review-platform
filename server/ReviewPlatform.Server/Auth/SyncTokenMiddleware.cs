using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;

namespace ReviewPlatform.Server.Auth;

public sealed class SyncTokenMiddleware(
    RequestDelegate next,
    IOptions<SyncAuthOptions> options)
{
    private const string HeaderName = "X-Sync-Token";

    public async Task InvokeAsync(HttpContext context)
    {
        if (context.Request.Path.Equals("/health"))
        {
            await next(context);
            return;
        }

        var configuredToken = options.Value.AccessToken;
        var providedToken = context.Request.Headers[HeaderName].ToString();
        if (string.IsNullOrWhiteSpace(configuredToken) ||
            !TokensMatch(configuredToken, providedToken))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new
            {
                error = "유효한 동기화 토큰이 필요합니다."
            });
            return;
        }

        await next(context);
    }

    private static bool TokensMatch(string expected, string actual)
    {
        var expectedBytes = Encoding.UTF8.GetBytes(expected);
        var actualBytes = Encoding.UTF8.GetBytes(actual);
        return expectedBytes.Length == actualBytes.Length &&
            CryptographicOperations.FixedTimeEquals(expectedBytes, actualBytes);
    }
}
