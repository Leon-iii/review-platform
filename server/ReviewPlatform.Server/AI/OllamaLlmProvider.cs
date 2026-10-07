using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.Contracts;
using ReviewPlatform.Server.Services;

namespace ReviewPlatform.Server.AI;

public sealed class OllamaLlmProvider(
    HttpClient httpClient,
    IOptions<LlmOptions> options,
    ILogger<OllamaLlmProvider> logger) : ILLMProvider
{
    private static readonly JsonSerializerOptions JsonOptions = new(
        JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };
    private readonly LlmOptions settings = options.Value;
    private int visionRequestCount;

    public string ProviderName => "ollama";

    public string ModelName => settings.Model;

    public int MaximumQuestionsPerRequest => settings.MaximumQuestionsPerRequest;

    public int? ContextWindowTokens => settings.ContextWindowTokens;

    public async Task<IReadOnlyList<GeneratedQuestionDraft>> GenerateQuestionsAsync(
        QuestionGenerationInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        var stopwatch = Stopwatch.StartNew();
        logger.LogInformation(
            "LLM operation started. Provider={Provider} Model={Model} Operation={Operation}",
            ProviderName,
            ModelName,
            "question-generation");

        try
        {
            await EnsureModelInstalledAsync(cancellationToken);
            var schema = QuestionGenerationPrompt.BuildQuestionSchema(input);
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                BuildEndpoint("api/chat"));
            request.Content = new StringContent(
                JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["model"] = settings.Model,
                    ["messages"] = new object[]
                    {
                        new
                        {
                            role = "system",
                            content = QuestionGenerationPrompt.GetSystemPrompt(input)
                        },
                        new
                        {
                            role = "user",
                            content = $"""
                                {QuestionGenerationPrompt.BuildUserPrompt(input)}

                                Return JSON matching this schema exactly:
                                {schema.ToJsonString()}
                                """
                        }
                    },
                    ["stream"] = false,
                    ["format"] = schema,
                    ["options"] = BuildGenerationOptions(Math.Min(
                            16_000,
                            800 + input.QuestionBudgetForTokenLimit * 700))
                }, JsonOptions),
                Encoding.UTF8,
                "application/json");

            using var response = await SendAsync(request, cancellationToken);
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode));
            }

            var questions = ParseResponse(responseBody);
            logger.LogInformation(
                "LLM response received and parsed. Provider={Provider} Model={Model} " +
                "Operation={Operation} OutputCount={OutputCount} DurationMs={DurationMs}",
                ProviderName,
                ModelName,
                "question-generation",
                questions.Count,
                stopwatch.ElapsedMilliseconds);
            return questions;
        }
        catch (Exception exception) when (
            exception is LlmProviderUnavailableException or
            LlmProviderRequestException)
        {
            logger.LogWarning(
                "LLM operation failed. Provider={Provider} Model={Model} Operation={Operation} DurationMs={DurationMs} Failure={Failure}",
                ProviderName,
                ModelName,
                "question-generation",
                stopwatch.ElapsedMilliseconds,
                exception.GetType().Name);
            throw;
        }
    }

    public async Task<IReadOnlyList<GeneratedConceptDraft>> ExtractConceptsAsync(
        ConceptExtractionInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        var stopwatch = Stopwatch.StartNew();
        logger.LogInformation(
            "LLM operation started. Provider={Provider} Model={Model} Operation={Operation}",
            ProviderName,
            ModelName,
            "concept-extraction");

        try
        {
            await EnsureModelInstalledAsync(cancellationToken);
            var concepts = await ExtractConceptsWithRecoveryAsync(
                input,
                splitDepth: 0,
                cancellationToken);
            logger.LogInformation(
                "LLM response received and parsed. Provider={Provider} Model={Model} " +
                "Operation={Operation} OutputCount={OutputCount} DurationMs={DurationMs}",
                ProviderName,
                ModelName,
                "concept-extraction",
                concepts.Count,
                stopwatch.ElapsedMilliseconds);
            return concepts;
        }
        catch (Exception exception) when (
            exception is LlmProviderUnavailableException or
            LlmProviderRequestException)
        {
            logger.LogWarning(
                "LLM operation failed. Provider={Provider} Model={Model} " +
                "Operation={Operation} DurationMs={DurationMs} Failure={Failure}",
                ProviderName,
                ModelName,
                "concept-extraction",
                stopwatch.ElapsedMilliseconds,
                exception.GetType().Name);
            throw;
        }
    }

    public async Task<IReadOnlyList<GeneratedConceptRevision>> ReviseConceptsAsync(
        ConceptRevisionInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        var stopwatch = Stopwatch.StartNew();
        logger.LogInformation(
            "LLM operation started. Provider={Provider} Model={Model} Operation={Operation}",
            ProviderName,
            ModelName,
            "concept-revision");
        try
        {
            await EnsureModelInstalledAsync(cancellationToken);
            var schema = ConceptRevisionPrompt.BuildSchema(input);
            var userPrompt = ConceptRevisionPrompt.BuildUserPrompt(input);
            var outputTokenBudget = Math.Min(
                6_000,
                2_048 + (input.EditableConceptIds.Count + (input.AllowAdditions ? 4 : 0)) * 384);
            var contextWindow = SelectRevisionContextWindow(
                ConceptRevisionPrompt.SystemPrompt.Length + userPrompt.Length,
                outputTokenBudget);
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                BuildEndpoint("api/chat"));
            request.Content = new StringContent(
                JsonSerializer.Serialize(new Dictionary<string, object?>
                {
                    ["model"] = settings.Model,
                    ["messages"] = new object[]
                    {
                        new
                        {
                            role = "system",
                            content = ConceptRevisionPrompt.SystemPrompt
                        },
                        new
                        {
                            role = "user",
                            content = userPrompt
                        }
                    },
                    ["stream"] = false,
                    ["think"] = false,
                    ["format"] = schema,
                    ["keep_alive"] = "10m",
                    ["options"] = BuildGenerationOptions(
                        outputTokenBudget, contextWindow)
                }, JsonOptions),
                Encoding.UTF8,
                "application/json");

            using var response = await SendAsync(request, cancellationToken);
            var responseBody = await response.Content.ReadAsStringAsync(
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                LogOllamaApiFailure(
                    response.StatusCode,
                    responseBody,
                    "concept-revision",
                    0);
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode, responseBody));
            }
            var revisions = ParseConceptRevisionResponse(responseBody);
            logger.LogInformation(
                "LLM response received and parsed. Provider={Provider} Model={Model} " +
                "Operation={Operation} OutputCount={OutputCount} DurationMs={DurationMs}",
                ProviderName,
                ModelName,
                "concept-revision",
                revisions.Count,
                stopwatch.ElapsedMilliseconds);
            return revisions;
        }
        catch (Exception exception) when (
            exception is LlmProviderUnavailableException or
            LlmProviderRequestException)
        {
            logger.LogWarning(
                "LLM operation failed. Provider={Provider} Model={Model} " +
                "Operation={Operation} DurationMs={DurationMs} Failure={Failure}",
                ProviderName,
                ModelName,
                "concept-revision",
                stopwatch.ElapsedMilliseconds,
                exception.GetType().Name);
            throw;
        }
    }

    private async Task<IReadOnlyList<GeneratedConceptDraft>>
        ExtractConceptsWithRecoveryAsync(
            ConceptExtractionInput input,
            int splitDepth,
            CancellationToken cancellationToken)
    {
        try
        {
            return await SendConceptRequestAsync(input, cancellationToken);
        }
        catch (LlmProviderRequestException exception) when (
            splitDepth < 6 &&
            IsRecoverableConceptOutputFailure(exception) &&
            TrySplitConceptInput(input, out var left, out var right))
        {
            logger.LogWarning(
                "Ollama concept output was truncated or malformed. " +
                "Splitting page batch and retrying. Provider={Provider} Model={Model} " +
                "PageCount={PageCount} SplitDepth={SplitDepth}",
                ProviderName,
                ModelName,
                input.Pages.Count,
                splitDepth + 1);
            var leftConcepts = await ExtractConceptsWithRecoveryAsync(
                left,
                splitDepth + 1,
                cancellationToken);
            var rightConcepts = await ExtractConceptsWithRecoveryAsync(
                right,
                splitDepth + 1,
                cancellationToken);
            return leftConcepts.Concat(rightConcepts).ToList();
        }
    }

    private async Task<IReadOnlyList<GeneratedConceptDraft>> SendConceptRequestAsync(
        ConceptExtractionInput input,
        CancellationToken cancellationToken)
    {
        var schema = ConceptExtractionPrompt.BuildOllamaSchema(input);
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            BuildEndpoint("api/chat"));
        request.Content = new StringContent(
            JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["model"] = settings.Model,
                ["messages"] = new object[]
                {
                    new
                    {
                        role = "system",
                        content = ConceptExtractionPrompt.OllamaSystemPrompt
                    },
                    new
                    {
                        role = "user",
                        content = $"""
                            {ConceptExtractionPrompt.BuildUserPrompt(input)}

                            Return JSON matching this schema exactly:
                            {schema.ToJsonString()}
                            """
                    }
                },
                ["stream"] = false,
                ["format"] = schema,
                ["keep_alive"] = 0,
                ["options"] = BuildGenerationOptions(3_500, 8_192)
            }, JsonOptions),
            Encoding.UTF8,
            "application/json");

        using var response = await SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            LogOllamaApiFailure(
                response.StatusCode,
                responseBody,
                "concept-extraction",
                input.Pages.FirstOrDefault()?.PageNumber ?? 0);
            throw new LlmProviderRequestException(
                ToSafeApiError(response.StatusCode, responseBody));
        }
        return ParseConceptResponse(responseBody);
    }

    private static bool IsRecoverableConceptOutputFailure(
        LlmProviderRequestException exception) =>
        exception.InnerException is JsonException or ConceptOutputTruncatedException;

    private static bool TrySplitConceptInput(
        ConceptExtractionInput input,
        out ConceptExtractionInput left,
        out ConceptExtractionInput right)
    {
        if (input.Pages.Count > 1)
        {
            var middle = input.Pages.Count / 2;
            left = input with { Pages = input.Pages.Take(middle).ToList() };
            right = input with { Pages = input.Pages.Skip(middle).ToList() };
            return true;
        }

        var page = input.Pages.SingleOrDefault();
        if (page is not null && page.Text.Length > 2_000)
        {
            var segments = DocumentExtractionSegments.Split(page.Text, page.Text.Length / 2);
            var middle = segments.Count / 2;
            left = input with
            {
                Pages = segments.Take(middle).Select(text => page with { Text = text }).ToList()
            };
            right = input with
            {
                Pages = segments.Skip(middle).Select(text => page with { Text = text }).ToList()
            };
            return true;
        }

        left = input;
        right = input;
        return false;
    }

    public async Task<DocumentVisionResult> ExtractPageContentAsync(
        DocumentVisionInput input,
        CancellationToken cancellationToken = default)
    {
        ValidateConfiguration();
        if (input.ImageBytes.Length is < 1 or > 12 * 1024 * 1024)
        {
            throw new LlmProviderRequestException(
                "문서 OCR 이미지의 크기가 올바르지 않습니다.");
        }
        var stopwatch = Stopwatch.StartNew();
        logger.LogInformation(
            "LLM operation started. Provider={Provider} Model={Model} " +
            "Operation={Operation} PageNumber={PageNumber}",
            ProviderName,
            ModelName,
            "document-vision",
            input.PageNumber);

        try
        {
            await EnsureModelInstalledAsync(cancellationToken);
            var requestNumber = Interlocked.Increment(ref visionRequestCount);
            var unloadAfterResponse = requestNumber == 1 || requestNumber % 8 == 0;
            var response = await SendVisionRequestAsync(
                input,
                unloadAfterResponse,
                cancellationToken);
            if (!response.IsSuccessStatusCode &&
                response.StatusCode == HttpStatusCode.InternalServerError)
            {
                LogOllamaApiFailure(
                    response.StatusCode,
                    response.Body,
                    "document-vision-first-attempt",
                    input.PageNumber);
                logger.LogWarning(
                    "Retrying document vision after an Ollama internal error. " +
                    "Provider={Provider} Model={Model} PageNumber={PageNumber}",
                    ProviderName,
                    ModelName,
                    input.PageNumber);
                response = await SendVisionRequestAsync(
                    input,
                    unloadAfterResponse: true,
                    cancellationToken);
            }
            if (!response.IsSuccessStatusCode)
            {
                LogOllamaApiFailure(
                    response.StatusCode,
                    response.Body,
                    "document-vision",
                    input.PageNumber);
                throw new LlmProviderRequestException(
                    ToSafeApiError(response.StatusCode, response.Body));
            }

            var result = ParseVisionResponse(response.Body);
            logger.LogInformation(
                "LLM response received and parsed. Provider={Provider} " +
                "Model={Model} Operation={Operation} PageNumber={PageNumber} " +
                "ExtractedCharacters={ExtractedCharacters} DurationMs={DurationMs}",
                ProviderName,
                ModelName,
                "document-vision",
                input.PageNumber,
                result.Text.Length,
                stopwatch.ElapsedMilliseconds);
            return result;
        }
        catch (Exception exception) when (
            exception is LlmProviderUnavailableException or
            LlmProviderRequestException)
        {
            logger.LogWarning(
                "LLM operation failed. Provider={Provider} Model={Model} " +
                "Operation={Operation} PageNumber={PageNumber} " +
                "DurationMs={DurationMs} Failure={Failure}",
                ProviderName,
                ModelName,
                "document-vision",
                input.PageNumber,
                stopwatch.ElapsedMilliseconds,
                exception.GetType().Name);
            throw;
        }
    }

    private async Task<VisionHttpResponse> SendVisionRequestAsync(
        DocumentVisionInput input,
        bool unloadAfterResponse,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            BuildEndpoint("api/chat"));
        request.Content = new StringContent(
            JsonSerializer.Serialize(new Dictionary<string, object?>
            {
                ["model"] = settings.Model,
                ["messages"] = new object[]
                {
                    new
                    {
                        role = "system",
                        content = DocumentVisionPrompt.SystemPrompt
                    },
                    new Dictionary<string, object?>
                    {
                        ["role"] = "user",
                        ["content"] = DocumentVisionPrompt.BuildUserPrompt(input),
                        ["images"] = new[]
                        {
                            Convert.ToBase64String(input.ImageBytes)
                        }
                    }
                },
                ["stream"] = false,
                ["think"] = false,
                ["keep_alive"] = unloadAfterResponse ? (object)0 : "5m",
                ["options"] = BuildGenerationOptions(8_000)
            }, JsonOptions),
            Encoding.UTF8,
            "application/json");
        using var response = await SendAsync(request, cancellationToken);
        return new VisionHttpResponse(
            response.StatusCode,
            await response.Content.ReadAsStringAsync(cancellationToken));
    }

    private void LogOllamaApiFailure(
        HttpStatusCode statusCode,
        string responseBody,
        string operation,
        int pageNumber)
    {
        logger.LogWarning(
            "Ollama API returned an error. Provider={Provider} Model={Model} " +
            "Operation={Operation} PageNumber={PageNumber} StatusCode={StatusCode} " +
            "ResponseError={ResponseError}",
            ProviderName,
            ModelName,
            operation,
            pageNumber,
            (int)statusCode,
            ExtractResponseError(responseBody) ?? "unavailable");
    }

    public async Task<OllamaStatus> CheckStatusAsync(
        CancellationToken cancellationToken = default)
    {
        try
        {
            ValidateConfiguration();
            var models = await GetInstalledModelsAsync(cancellationToken);
            return new OllamaStatus(
                true,
                models.Contains(settings.Model),
                settings.Model);
        }
        catch (LlmProviderUnavailableException)
        {
            return new OllamaStatus(false, false, settings.Model);
        }
        catch (LlmProviderRequestException)
        {
            return new OllamaStatus(false, false, settings.Model);
        }
    }

    private async Task EnsureModelInstalledAsync(
        CancellationToken cancellationToken)
    {
        var models = await GetInstalledModelsAsync(cancellationToken);
        if (!models.Contains(settings.Model))
        {
            throw new LlmProviderUnavailableException(
                $"Configured Ollama model '{settings.Model}' is not installed.");
        }
    }

    private async Task<HashSet<string>> GetInstalledModelsAsync(
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            BuildEndpoint("api/tags"));
        using var response = await SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(
            cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new LlmProviderRequestException(
                $"Ollama 모델 목록 요청이 실패했습니다: {(int)response.StatusCode}");
        }

        try
        {
            var envelope = JsonSerializer.Deserialize<OllamaTagsResponse>(
                responseBody,
                JsonOptions);
            if (envelope?.Models is null)
            {
                throw new JsonException("Missing models array.");
            }
            return envelope.Models
                .Select(model => model.Name ?? model.Model)
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Select(name => name!)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama 모델 목록 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        try
        {
            return await httpClient.SendAsync(request, cancellationToken);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LlmProviderRequestException(
                "Ollama 요청 시간이 초과되었습니다.");
        }
        catch (HttpRequestException exception)
        {
            throw new LlmProviderUnavailableException(
                "Ollama에 연결하지 못했습니다. Ollama가 실행 중인지 확인해 주세요.",
                exception);
        }
    }

    private IReadOnlyList<GeneratedQuestionDraft> ParseResponse(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("done", out var done) &&
                done.ValueKind == JsonValueKind.False)
            {
                throw new LlmProviderRequestException(
                    "Ollama가 문제 생성을 완료하지 못했습니다.");
            }
            if (!root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(content.GetString()))
            {
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 문제가 없습니다.");
            }

            var envelope = JsonSerializer.Deserialize<QuestionEnvelope>(
                content.GetString()!,
                JsonOptions);
            return envelope?.Questions ?? throw new LlmProviderRequestException(
                "Ollama의 구조화 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama의 구조화 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private IReadOnlyList<GeneratedConceptDraft> ParseConceptResponse(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("done_reason", out var doneReason) &&
                doneReason.ValueKind == JsonValueKind.String &&
                string.Equals(
                    doneReason.GetString(),
                    "length",
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new LlmProviderRequestException(
                    "Ollama의 개념 추출 응답이 출력 한도에서 잘렸습니다.",
                    new ConceptOutputTruncatedException());
            }
            if (root.TryGetProperty("done", out var done) &&
                done.ValueKind == JsonValueKind.False)
            {
                throw new LlmProviderRequestException(
                    "Ollama가 개념 추출을 완료하지 못했습니다.");
            }
            if (!root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(content.GetString()))
            {
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 개념이 없습니다.");
            }

            var envelope = JsonSerializer.Deserialize<ConceptEnvelope>(
                content.GetString()!,
                JsonOptions);
            return envelope?.Concepts ?? throw new LlmProviderRequestException(
                "Ollama의 구조화된 개념 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama의 구조화된 개념 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private IReadOnlyList<GeneratedConceptRevision> ParseConceptRevisionResponse(
        string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("done", out var done) &&
                done.ValueKind == JsonValueKind.False)
            {
                throw new LlmProviderRequestException(
                    "Ollama가 개념 수정을 완료하지 못했습니다.");
            }
            if (!root.TryGetProperty("message", out var message) ||
                !message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String ||
                string.IsNullOrWhiteSpace(content.GetString()))
            {
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 개념 수정안이 없습니다.");
            }
            var envelope = JsonSerializer.Deserialize<ConceptChangeEnvelope>(
                content.GetString()!,
                JsonOptions);
            return envelope?.Flatten() ?? throw new LlmProviderRequestException(
                "Ollama의 구조화된 개념 수정 응답을 해석하지 못했습니다.");
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama의 구조화된 개념 수정 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private DocumentVisionResult ParseVisionResponse(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.TryGetProperty("done_reason", out var reason) && reason.ValueKind == JsonValueKind.String &&
                reason.GetString() == "length")
                throw new LlmProviderRequestException("Ollama의 문서 이미지 응답이 출력 한도에서 잘렸습니다. 부분 결과는 저장하지 않습니다.");
            if (root.TryGetProperty("done", out var done) &&
                done.ValueKind == JsonValueKind.False)
            {
                throw new LlmProviderRequestException(
                    "Ollama가 문서 이미지 분석을 완료하지 못했습니다.");
            }
            if (!root.TryGetProperty("message", out var message))
            {
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 문서 내용이 없습니다.");
            }
            if (!message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String)
            {
                if (message.TryGetProperty("thinking", out var thinking) &&
                    thinking.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(thinking.GetString()))
                {
                    throw new LlmProviderRequestException(
                        "현재 Ollama 모델이 OCR 결과를 thinking 필드에만 반환했습니다. " +
                        "PDF 이미지 OCR 프로필의 모델을 " +
                        "'qwen3-vl:8b-instruct'로 변경해 주세요.");
                }
                throw new LlmProviderRequestException(
                    "Ollama 응답에 구조화된 문서 내용이 없습니다.");
            }

            var rawContent = content.GetString()!;
            if (string.IsNullOrWhiteSpace(rawContent))
            {
                if (message.TryGetProperty("thinking", out var thinking) &&
                    thinking.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(thinking.GetString()))
                {
                    throw new LlmProviderRequestException(
                        "현재 Ollama 모델이 OCR 결과를 thinking 필드에만 반환했습니다. " +
                        "PDF 이미지 OCR 프로필의 모델을 " +
                        "'qwen3-vl:8b-instruct'로 변경해 주세요.");
                }
                return new DocumentVisionResult(string.Empty);
            }

            try
            {
                return DocumentVisionOutput.Parse(rawContent, allowPlainText: true);
            }
            catch (JsonException)
            {
                // Preserve the existing compatibility repair for unescaped newlines.
                return DocumentVisionOutput.Parse(
                    EscapeUnescapedJsonControlCharacters(StripMarkdownCodeFence(rawContent.Trim())), allowPlainText: true);
            }
        }
        catch (LlmProviderRequestException)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new LlmProviderRequestException(
                "Ollama의 문서 이미지 응답을 해석하지 못했습니다.",
                exception);
        }
    }

    private static string StripMarkdownCodeFence(string value)
    {
        if (!value.StartsWith("```", StringComparison.Ordinal)) return value;
        var firstLineEnd = value.IndexOf('\n');
        var closingFence = value.LastIndexOf("```", StringComparison.Ordinal);
        if (firstLineEnd < 0 || closingFence <= firstLineEnd) return value;
        return value[(firstLineEnd + 1)..closingFence].Trim();
    }

    private static string EscapeUnescapedJsonControlCharacters(string value)
    {
        var builder = new StringBuilder(value.Length);
        var insideString = false;
        var escaped = false;
        foreach (var character in value)
        {
            if (!insideString)
            {
                builder.Append(character);
                if (character == '"') insideString = true;
                continue;
            }
            if (escaped)
            {
                builder.Append(character);
                escaped = false;
                continue;
            }
            if (character == '\\')
            {
                builder.Append(character);
                escaped = true;
                continue;
            }
            if (character == '"')
            {
                builder.Append(character);
                insideString = false;
                continue;
            }
            switch (character)
            {
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                default:
                    if (character < ' ')
                    {
                        builder.Append($"\\u{(int)character:x4}");
                    }
                    else
                    {
                        builder.Append(character);
                    }
                    break;
            }
        }
        return builder.ToString();
    }

    private static bool LooksLikeJson(string value) =>
        value.StartsWith('{') ||
        value.StartsWith('[') ||
        value.StartsWith('"') ||
        value.StartsWith("```", StringComparison.Ordinal);

    private void ValidateConfiguration()
    {
        if (string.IsNullOrWhiteSpace(settings.Model))
        {
            throw new LlmProviderUnavailableException(
                "Ollama 모델이 설정되지 않았습니다.");
        }
        if (!Uri.TryCreate(settings.BaseUrl, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            throw new LlmProviderUnavailableException(
                "Llm__BaseUrl에 올바른 Ollama HTTP 주소를 설정해 주세요.");
        }
    }

    private Uri BuildEndpoint(string path)
    {
        var baseUri = new Uri(settings.BaseUrl.Trim().TrimEnd('/') + "/");
        return new Uri(baseUri, path);
    }

    private Dictionary<string, object> BuildGenerationOptions(
        int outputTokenBudget,
        int? automaticContextWindow = null)
    {
        var contextWindow = settings.ContextWindowTokens ?? automaticContextWindow;
        var options = new Dictionary<string, object>
        {
            ["temperature"] = 0,
            // Reserve room for input when a small manual window is selected.
            ["num_predict"] = settings.ContextWindowTokens is int manualWindow
                ? Math.Min(outputTokenBudget, manualWindow / 2)
                : outputTokenBudget
        };
        if (contextWindow is not null) options["num_ctx"] = contextWindow.Value;
        return options;
    }

    private static int SelectRevisionContextWindow(
        int inputCharacterCount,
        int outputTokenBudget)
    {
        // Korean and JSON commonly use more tokens per character than plain
        // English. This intentionally conservative estimate still avoids the
        // large KV-cache cost of forcing 32K for every small edit request.
        var estimatedInputTokens = (inputCharacterCount + 1) / 2;
        var requiredTokens = estimatedInputTokens + outputTokenBudget;
        if (requiredTokens <= 8_192) return 8_192;
        if (requiredTokens <= 16_384) return 16_384;
        return 32_768;
    }

    private static string ToSafeApiError(HttpStatusCode statusCode) =>
        ToSafeApiError(statusCode, string.Empty);

    private static string ToSafeApiError(
        HttpStatusCode statusCode,
        string responseBody)
    {
        var error = ExtractResponseError(responseBody);
        if (error?.Contains("memory", StringComparison.OrdinalIgnoreCase) == true ||
            error?.Contains("CUDA", StringComparison.OrdinalIgnoreCase) == true)
        {
            return "Ollama가 모델을 실행할 메모리가 부족합니다. " +
                "다른 GPU 작업을 종료한 뒤 다시 시도해 주세요.";
        }
        if (statusCode == HttpStatusCode.InternalServerError)
        {
            return "Ollama가 문서 분석 중 내부 오류를 반환했습니다. " +
                "요청을 한 번 재시도했지만 실패했습니다. 서버 로그를 확인해 주세요. (500)";
        }
        return $"Ollama API 요청이 실패했습니다: {(int)statusCode}";
    }

    private static string? ExtractResponseError(string responseBody)
    {
        try
        {
            using var document = JsonDocument.Parse(responseBody);
            if (!document.RootElement.TryGetProperty("error", out var error) ||
                error.ValueKind != JsonValueKind.String)
            {
                return null;
            }
            var value = error.GetString()?.Replace('\r', ' ').Replace('\n', ' ').Trim();
            if (string.IsNullOrWhiteSpace(value)) return null;
            return value.Length <= 1_000 ? value : value[..1_000];
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private sealed record OllamaTagsResponse(
        IReadOnlyList<OllamaModelInfo>? Models);

    private sealed record OllamaModelInfo(string? Name, string? Model);

    private sealed record QuestionEnvelope(
        IReadOnlyList<GeneratedQuestionDraft>? Questions);

    private sealed record ConceptEnvelope(
        IReadOnlyList<GeneratedConceptDraft>? Concepts);

    private sealed record DocumentVisionEnvelope(string? Text);

    private sealed class ConceptOutputTruncatedException : Exception;

    private sealed record VisionHttpResponse(
        HttpStatusCode StatusCode,
        string Body)
    {
        public bool IsSuccessStatusCode =>
            (int)StatusCode is >= 200 and <= 299;
    }
}

public sealed record OllamaStatus(
    bool Reachable,
    bool ModelInstalled,
    string Model);
