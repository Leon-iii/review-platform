namespace ReviewPlatform.Server.Services;

public sealed class DocumentImportException(string message, Exception? inner = null)
    : Exception(message, inner);
