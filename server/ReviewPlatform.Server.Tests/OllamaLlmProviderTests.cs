using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using ReviewPlatform.Server.AI;
using ReviewPlatform.Server.Contracts;
using Xunit;

namespace ReviewPlatform.Server.Tests;

public sealed class OllamaLlmProviderTests
{
    [Fact]
    public async Task GenerateQuestions_UsesNativeChatSchemaAndIgnoresThinking()
    {
        var generatedJson = JsonSerializer.Serialize(new
        {
            questions = new[]
            {
                new
                {
                    type = "shortAnswer",
                    prompt = "가우스 법칙이 연결하는 두 물리량은?",
                    choices = Array.Empty<object>(),
                    acceptableAnswers = new[] { "전기선속과 내부 전하" },
                    explanation = "SOURCE에 명시된 두 물리량이다.",
                    difficulty = 2,
                    sourceIds = new[] { "전자기학" }
                }
            }
        });
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[]
                    {
                        new { name = "qwen3:8b", model = "qwen3:8b" }
                    }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    model = "qwen3:8b",
                    message = new
                    {
                        role = "assistant",
                        thinking = "저장하거나 노출하면 안 되는 추론",
                        content = generatedJson
                    },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var questions = await provider.GenerateQuestionsAsync(
            Input(),
            TestContext.Current.CancellationToken);

        var question = Assert.Single(questions);
        Assert.Equal("shortAnswer", question.Type);
        Assert.Equal("전기선속과 내부 전하", Assert.Single(
            question.AcceptableAnswers));
        Assert.Equal(2, handler.Requests.Count);
        Assert.All(handler.Requests, request => Assert.Null(request.Authorization));

        var chatRequest = Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
        using var body = JsonDocument.Parse(chatRequest.Body!);
        var root = body.RootElement;
        Assert.Equal("qwen3:8b", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("stream").GetBoolean());
        Assert.Equal("object", root.GetProperty("format")
            .GetProperty("type").GetString());
        Assert.Equal(1, root.GetProperty("format")
            .GetProperty("properties")
            .GetProperty("questions")
            .GetProperty("minItems").GetInt32());
        var questionSchema = root.GetProperty("format")
            .GetProperty("properties")
            .GetProperty("questions")
            .GetProperty("items")
            .GetProperty("properties");
        Assert.Equal("integer", questionSchema.GetProperty("difficulty")
            .GetProperty("type").GetString());
        Assert.Contains("After drafting each question", root.GetProperty("messages")[0]
            .GetProperty("content").GetString());
        Assert.Contains("가우스 법칙", root.GetProperty("messages")[1]
            .GetProperty("content").GetString());
        Assert.DoesNotContain("추론", JsonSerializer.Serialize(questions));
    }

    [Fact]
    public async Task ExtractConcepts_ReturnsPageGroundedDrafts()
    {
        var generatedJson = JsonSerializer.Serialize(new
        {
            concepts = new[]
            {
                new
                {
                    title = "가우스 법칙",
                    content = "전기선속과 내부 전하의 관계를 폐곡면을 기준으로 설명한다.",
                    pageNumbers = new[] { 2, 3 },
                    importance = "high"
                }
            }
        });
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = generatedJson,
                        thinking = "노출하지 않을 추론"
                    },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var concepts = await provider.ExtractConceptsAsync(
            new ConceptExtractionInput(
                "source-1",
                "전자기학.pdf",
                [
                    new ExtractedDocumentPage(2, "가우스 법칙 설명"),
                    new ExtractedDocumentPage(3, "전기선속과 전하")
                ],
                ConceptExtractionPrompt.Version),
            TestContext.Current.CancellationToken);

        var concept = Assert.Single(concepts);
        Assert.Equal("가우스 법칙", concept.Title);
        Assert.Contains("폐곡면", concept.Content);
        Assert.Equal([2, 3], concept.PageNumbers);
        Assert.Equal("high", concept.Importance);
        var chatRequest = Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
        using var body = JsonDocument.Parse(chatRequest.Body!);
        var systemPrompt = body.RootElement.GetProperty("messages")[0]
            .GetProperty("content").GetString();
        Assert.Contains("natural Korean", systemPrompt);
        Assert.Contains("original technical terms", body.RootElement
            .GetProperty("messages")[1]
            .GetProperty("content").GetString());
        Assert.Contains("[PAGE 2]", body.RootElement.GetProperty("messages")[1]
            .GetProperty("content").GetString());
        Assert.Contains("Memorization load", systemPrompt);
        Assert.Contains("Required recall precision", systemPrompt);
        Assert.Contains("independent memorization elements", systemPrompt);
        Assert.DoesNotContain("MIPS", systemPrompt);
        Assert.Equal("string", body.RootElement.GetProperty("format")
            .GetProperty("properties")
            .GetProperty("concepts")
            .GetProperty("items")
            .GetProperty("properties")
            .GetProperty("importance")
            .GetProperty("type")
            .GetString());
        Assert.DoesNotContain("추론", JsonSerializer.Serialize(concepts));
    }

    [Fact]
    public async Task ReviseConcepts_SendsAllConceptsAndRestrictsEditableIds()
    {
        Assert.DoesNotContain("MIPS", ConceptRevisionPrompt.SystemPrompt);
        Assert.DoesNotContain("differential", ConceptRevisionPrompt.SystemPrompt);
        Assert.Contains("smallest possible change", ConceptRevisionPrompt.SystemPrompt);
        Assert.Contains("Preserve pageNumbers and importance exactly",
            ConceptRevisionPrompt.SystemPrompt);
        Assert.DoesNotContain("MIPS", ConceptExtractionPrompt.SystemPrompt);

        var generatedJson = JsonSerializer.Serialize(new
        {
            revisions = new[]
            {
                new
                {
                    id = "held-1",
                    title = "가우스 법칙",
                    content = "폐곡면을 기준으로 전기선속과 전하의 관계를 설명한다.",
                    pageNumbers = new[] { 2, 3 },
                    importance = "high"
                }
            }
        });
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new { content = generatedJson },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);
        var input = new ConceptRevisionInput(
            "source-1",
            "전자기학.pdf",
            10,
            "설명을 자연스럽게 고쳐 줘.",
            [
                new ConceptRevisionContext(
                    "held-1", "가우스 법칙", "전기선속과 전하의 관계", [2, 3], "held"),
                new ConceptRevisionContext(
                    "approved-1", "쿨롱 법칙", "두 전하 사이의 힘", [5], "approved")
            ],
            ["held-1"],
            ConceptRevisionPrompt.Version);

        var revisions = await provider.ReviseConceptsAsync(
            input,
            TestContext.Current.CancellationToken);

        var revision = Assert.Single(revisions);
        Assert.Equal("held-1", revision.Id);
        Assert.Equal("high", revision.Importance);
        var chatRequest = Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
        using var body = JsonDocument.Parse(chatRequest.Body!);
        var root = body.RootElement;
        var userPrompt = root.GetProperty("messages")[1]
            .GetProperty("content").GetString();
        Assert.Contains("held-1", userPrompt);
        Assert.Contains("approved-1", userPrompt);
        Assert.Contains("\"number\":1", userPrompt);
        Assert.DoesNotContain("두 전하 사이의 힘", userPrompt);
        Assert.DoesNotContain("Return JSON matching this schema", userPrompt);
        Assert.False(root.GetProperty("think").GetBoolean());
        Assert.Equal("10m", root.GetProperty("keep_alive").GetString());
        Assert.Equal(8_192,
            root.GetProperty("options").GetProperty("num_ctx").GetInt32());
        Assert.Equal(2_432,
            root.GetProperty("options").GetProperty("num_predict").GetInt32());
        var idValues = root.GetProperty("format")
            .GetProperty("properties")
            .GetProperty("revisions")
            .GetProperty("items")
            .GetProperty("properties")
            .GetProperty("id")
            .GetProperty("enum")
            .EnumerateArray()
            .Select(value => value.GetString())
            .ToArray();
        Assert.Equal(["held-1"], idValues);
    }

    [Fact]
    public async Task ExtractConcepts_TruncatedOutputSplitsPagesAndRetries()
    {
        var chatRequestCount = 0;
        var handler = new RecordingHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/tags")
            {
                return JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                });
            }

            chatRequestCount++;
            if (chatRequestCount == 1)
            {
                return JsonResponse(HttpStatusCode.OK, new
                {
                    message = new { content = "{\"concepts\":[" },
                    done = true,
                    done_reason = "length"
                });
            }

            var pageNumber = chatRequestCount == 2 ? 1 : 3;
            return JsonResponse(HttpStatusCode.OK, new
            {
                message = new
                {
                    content = JsonSerializer.Serialize(new
                    {
                        concepts = new[]
                        {
                            new
                            {
                                title = $"개념 {pageNumber}",
                                content = "개념의 세부 설명",
                                pageNumbers = new[] { pageNumber }
                            }
                        }
                    })
                },
                done = true,
                done_reason = "stop"
            });
        });
        var provider = CreateProvider(handler);

        var concepts = await provider.ExtractConceptsAsync(
            new ConceptExtractionInput(
                "source-1",
                "자료.pdf",
                [
                    new ExtractedDocumentPage(1, "첫 페이지"),
                    new ExtractedDocumentPage(2, "둘째 페이지"),
                    new ExtractedDocumentPage(3, "셋째 페이지"),
                    new ExtractedDocumentPage(4, "넷째 페이지")
                ],
                ConceptExtractionPrompt.Version),
            TestContext.Current.CancellationToken);

        Assert.Equal(2, concepts.Count);
        var chatRequests = handler.Requests
            .Where(request => request.Path == "/api/chat")
            .ToArray();
        Assert.Equal(3, chatRequests.Length);
        using var retryBody = JsonDocument.Parse(chatRequests[1].Body!);
        var retryRoot = retryBody.RootElement;
        Assert.Equal(0, retryRoot.GetProperty("keep_alive").GetInt32());
        Assert.Equal(8192,
            retryRoot.GetProperty("options").GetProperty("num_ctx").GetInt32());
        Assert.Equal(3500,
            retryRoot.GetProperty("options").GetProperty("num_predict").GetInt32());
        Assert.Equal(ConceptExtractionPrompt.MaximumConceptsPerRequest,
            retryRoot.GetProperty("format")
                .GetProperty("properties")
                .GetProperty("concepts")
                .GetProperty("maxItems")
                .GetInt32());
        Assert.Contains("[PAGE 1]", retryRoot.GetProperty("messages")[1]
            .GetProperty("content").GetString());
        Assert.DoesNotContain("[PAGE 3]", retryRoot.GetProperty("messages")[1]
            .GetProperty("content").GetString());
    }

    [Fact]
    public async Task ExtractConcepts_TruncatedSingleDiagramRetainsMetadataInEveryRetry()
    {
        var calls = 0;
        var handler = new RecordingHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/tags")
                return JsonResponse(HttpStatusCode.OK, new { models = new[] { new { name = "qwen3:8b" } } });
            calls++;
            return JsonResponse(HttpStatusCode.OK, new
            {
                message = new { content = calls == 1 ? "{\"concepts\":[" :
                    """{"concepts":[{"title":"도식 개념","content":"확인된 연결만 사용합니다.","pageNumbers":[1]}]}""" },
                done = true,
                done_reason = calls == 1 ? "length" : "stop"
            });
        });
        await CreateProvider(handler).ExtractConceptsAsync(new ConceptExtractionInput("source", "도식.pdf",
            [new(1, "[USER_INDEPENDENT_REGION_START]\n[CONTENT_KIND:diagram]\n" + new string('가', 6000) +
                "\n[/CONTENT_KIND]\n[USER_INDEPENDENT_REGION_END]")], ConceptExtractionPrompt.Version),
            TestContext.Current.CancellationToken);
        var retries = handler.Requests.Where(request => request.Path == "/api/chat").Skip(1).ToList();
        Assert.Equal(2, retries.Count);
        foreach (var retry in retries)
        {
            using var body = JsonDocument.Parse(retry.Body!);
            var prompt = body.RootElement.GetProperty("messages")[1].GetProperty("content").GetString()!;
            Assert.Contains("[CONTENT_KIND:diagram]", prompt);
            Assert.Contains("[/CONTENT_KIND]", prompt);
            Assert.Contains("[USER_INDEPENDENT_REGION_START]", prompt);
            Assert.Contains("[USER_INDEPENDENT_REGION_END]", prompt);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExtractPageContent_TypedRegionsAreParsedButTruncatedOutputIsRejected(bool truncated)
    {
        var handler = new RecordingHandler(request => request.RequestUri!.AbsolutePath == "/api/tags"
            ? JsonResponse(HttpStatusCode.OK, new { models = new[] { new { name = "qwen3:8b" } } })
            : JsonResponse(HttpStatusCode.OK, new
            {
                message = new { content = """{"regions":[{"kind":"diagram","text":"A → B","visualRegion":true},{"kind":"uncertain","text":"도착점 판독 불가","visualRegion":false}]}""" },
                done = true,
                done_reason = truncated ? "length" : "stop"
            }));
        var provider = CreateProvider(handler);
        var input = new DocumentVisionInput("도식.pdf", 1, "image/jpeg", [1, 2, 3], "hash", DocumentVisionPrompt.Version);
        if (truncated)
            await Assert.ThrowsAsync<LlmProviderRequestException>(() => provider.ExtractPageContentAsync(input, TestContext.Current.CancellationToken));
        else
        {
            var result = await provider.ExtractPageContentAsync(input, TestContext.Current.CancellationToken);
            Assert.Equal(["diagram", "uncertain"], result.Regions!.Select(region => region.Kind));
            Assert.Contains("[VISUAL_REGION_START]\nA → B", result.Text);
        }
    }

    [Fact]
    public async Task ExtractPageContent_SendsImageAndDisablesThinking()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = "사칙연산은 네 가지 기본 연산이다.",
                        thinking = "노출하지 않을 추론"
                    },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var result = await provider.ExtractPageContentAsync(
            new DocumentVisionInput(
                "수학.pdf",
                3,
                "image/jpeg",
                [1, 2, 3, 4],
                new string('a', 64),
                DocumentVisionPrompt.Version),
            TestContext.Current.CancellationToken);

        Assert.Equal("사칙연산은 네 가지 기본 연산이다.", result.Text);
        var chatRequest = Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
        using var body = JsonDocument.Parse(chatRequest.Body!);
        var root = body.RootElement;
        Assert.False(root.GetProperty("think").GetBoolean());
        Assert.Equal(0, root.GetProperty("keep_alive").GetInt32());
        var userMessage = root.GetProperty("messages")[1];
        Assert.Equal(
            Convert.ToBase64String([1, 2, 3, 4]),
            userMessage.GetProperty("images")[0].GetString());
        Assert.Contains("PAGE: 3", userMessage.GetProperty("content").GetString());
        Assert.False(root.TryGetProperty("format", out _));
    }

    [Fact]
    public async Task ExtractPageContent_InternalServerErrorRetriesPlainTextRequest()
    {
        var chatRequestCount = 0;
        var handler = new RecordingHandler(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/tags")
            {
                return JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                });
            }

            if (request.RequestUri.AbsolutePath != "/api/chat")
            {
                throw new InvalidOperationException();
            }

            chatRequestCount++;
            return chatRequestCount == 1
                ? JsonResponse(
                    HttpStatusCode.InternalServerError,
                    new { error = "failed to constrain output" })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = "재시도 성공"
                    },
                    done = true
                });
        });
        var provider = CreateProvider(handler);

        var result = await provider.ExtractPageContentAsync(
            new DocumentVisionInput(
                "자료.pdf",
                4,
                "image/jpeg",
                [1, 2, 3],
                new string('a', 64),
                DocumentVisionPrompt.Version),
            TestContext.Current.CancellationToken);

        Assert.Equal("재시도 성공", result.Text);
        var chatRequests = handler.Requests
            .Where(request => request.Path == "/api/chat")
            .ToArray();
        Assert.Equal(2, chatRequests.Length);
        using var strictBody = JsonDocument.Parse(chatRequests[0].Body!);
        using var fallbackBody = JsonDocument.Parse(chatRequests[1].Body!);
        Assert.False(strictBody.RootElement.TryGetProperty("format", out _));
        Assert.False(fallbackBody.RootElement.TryGetProperty("format", out _));
        Assert.Equal(0,
            fallbackBody.RootElement.GetProperty("keep_alive").GetInt32());
    }

    [Fact]
    public async Task ExtractPageContent_MemoryFailureReturnsActionableError()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(
                    HttpStatusCode.InternalServerError,
                    new { error = "CUDA out of memory: PRIVATE_DETAIL" }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => provider.ExtractPageContentAsync(
                new DocumentVisionInput(
                    "자료.pdf",
                    1,
                    "image/jpeg",
                    [1, 2, 3],
                    new string('a', 64),
                    DocumentVisionPrompt.Version),
                TestContext.Current.CancellationToken));

        Assert.Contains("메모리", exception.Message);
        Assert.DoesNotContain("PRIVATE_DETAIL", exception.Message);
        Assert.Equal(2, handler.Requests.Count(
            request => request.Path == "/api/chat"));
    }

    [Fact]
    public async Task ExtractPageContent_AcceptsFencedJsonWithLiteralLineBreaks()
    {
        const string content = """
            ```json
            {"text":"첫 줄
            둘째 줄"}
            ```
            """;
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new { content },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var result = await provider.ExtractPageContentAsync(
            new DocumentVisionInput(
                "자료.pdf",
                1,
                "image/jpeg",
                [1, 2, 3],
                new string('a', 64),
                DocumentVisionPrompt.Version),
            TestContext.Current.CancellationToken);

        Assert.Equal("첫 줄\n둘째 줄", result.Text);
        Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
    }

    [Fact]
    public async Task ExtractPageContent_RejectsUnrecognizedJsonInsteadOfTreatingItAsOcr()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new { content = "{\"unexpected\":true}" },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        await Assert.ThrowsAsync<LlmProviderRequestException>(() => provider.ExtractPageContentAsync(
            new DocumentVisionInput(
                "자료.pdf",
                2,
                "image/jpeg",
                [1, 2, 3],
                new string('a', 64),
                DocumentVisionPrompt.Version),
            TestContext.Current.CancellationToken));
        Assert.Single(handler.Requests,
            request => request.Path == "/api/chat");
    }

    [Fact]
    public async Task ExtractPageContent_AcceptsEmptyContentForBlankPage()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new { content = string.Empty },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var result = await provider.ExtractPageContentAsync(
            new DocumentVisionInput(
                "빈 페이지.pdf",
                1,
                "image/jpeg",
                [1, 2, 3],
                new string('a', 64),
                DocumentVisionPrompt.Version),
            TestContext.Current.CancellationToken);

        Assert.Empty(result.Text);
    }

    [Fact]
    public async Task ExtractPageContent_ThinkingOnlyResponseRecommendsInstructModel()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath switch
            {
                "/api/tags" => JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                }),
                "/api/chat" => JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = string.Empty,
                        thinking = "{\"text\":\"PRIVATE_RESULT_TEXT\"}"
                    },
                    done = true
                }),
                _ => throw new InvalidOperationException()
            });
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => provider.ExtractPageContentAsync(
                new DocumentVisionInput(
                    "자료.pdf",
                    1,
                    "image/jpeg",
                    [1, 2, 3],
                    new string('a', 64),
                    DocumentVisionPrompt.Version),
                TestContext.Current.CancellationToken));

        Assert.Contains("thinking 필드", exception.Message);
        Assert.Contains("qwen3-vl:8b-instruct", exception.Message);
        Assert.DoesNotContain("PRIVATE_RESULT_TEXT", exception.Message);
    }

    [Fact]
    public async Task MissingModel_ReturnsClearErrorWithoutChatRequest()
    {
        var handler = new RecordingHandler(_ => JsonResponse(
            HttpStatusCode.OK,
            new
            {
                models = new[] { new { name = "other:latest" } }
            }));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderUnavailableException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("qwen3:8b", exception.Message);
        Assert.Contains("not installed", exception.Message);
        Assert.Single(handler.Requests);
        Assert.Equal("/api/tags", handler.Requests[0].Path);
    }

    [Fact]
    public async Task OllamaUnavailable_ReturnsSafeConnectionError()
    {
        var handler = new RecordingHandler(_ =>
            throw new HttpRequestException("private network detail"));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderUnavailableException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("Ollama에 연결", exception.Message);
        Assert.DoesNotContain("private network detail", exception.Message);
    }

    [Fact]
    public async Task RequestTimeout_ReturnsSafeTimeoutError()
    {
        var handler = new RecordingHandler(_ =>
            throw new OperationCanceledException("private timeout detail"));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("시간이 초과", exception.Message);
        Assert.DoesNotContain("private timeout detail", exception.Message);
    }

    [Fact]
    public async Task InvalidMessageContent_ReturnsStructuredResponseError()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/tags"
                ? JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        role = "assistant",
                        content = "not-json",
                        thinking = "ignored"
                    },
                    done = true
                }));
        var provider = CreateProvider(handler);

        var exception = await Assert.ThrowsAsync<LlmProviderRequestException>(
            () => provider.GenerateQuestionsAsync(
                Input(),
                TestContext.Current.CancellationToken));

        Assert.Contains("구조화 응답", exception.Message);
    }

    [Fact]
    public async Task EmptyApiKey_DoesNotBlockOllama()
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/tags"
                ? JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = JsonSerializer.Serialize(new
                        {
                            questions = new[]
                            {
                                new
                                {
                                    type = "shortAnswer",
                                    prompt = "질문",
                                    choices = Array.Empty<object>(),
                                    acceptableAnswers = new[] { "답" },
                                    explanation = (string?)null,
                                    difficulty = 1,
                                    sourceIds = new[] { "전자기학" }
                                }
                            }
                        })
                    },
                    done = true
                }));
        var provider = CreateProvider(handler, apiKey: string.Empty);

        var questions = await provider.GenerateQuestionsAsync(
            Input(),
            TestContext.Current.CancellationToken);

        Assert.Single(questions);
    }

    [Theory]
    [InlineData(4_096)]
    [InlineData(32_768)]
    public async Task ManualContextWindow_IsAppliedToEveryOperation(int tokens)
    {
        var handler = new RecordingHandler(request =>
            request.RequestUri!.AbsolutePath == "/api/tags"
                ? JsonResponse(HttpStatusCode.OK, new
                {
                    models = new[] { new { name = "qwen3:8b" } }
                })
                : JsonResponse(HttpStatusCode.OK, new
                {
                    message = new
                    {
                        content = """{"questions":[],"concepts":[],"revisions":[],"text":"페이지 내용"}"""
                    },
                    done = true
                }));
        var provider = CreateProvider(handler, contextWindowTokens: tokens);
        await provider.GenerateQuestionsAsync(Input(), TestContext.Current.CancellationToken);
        await provider.ExtractConceptsAsync(new ConceptExtractionInput(
            "source", "자료.pdf", [new ExtractedDocumentPage(1, "개념 설명")],
            ConceptExtractionPrompt.Version), TestContext.Current.CancellationToken);
        await provider.ReviseConceptsAsync(new ConceptRevisionInput(
            "source", "자료.pdf", 1, "문장 수정",
            [new ConceptRevisionContext("c1", "제목", "내용", [1], "held")],
            ["c1"], ConceptRevisionPrompt.Version), TestContext.Current.CancellationToken);
        await provider.ExtractPageContentAsync(new DocumentVisionInput(
            "자료.pdf", 1, "image/jpeg", [1, 2], new string('a', 64),
            DocumentVisionPrompt.Version), TestContext.Current.CancellationToken);

        var requests = handler.Requests.Where(request => request.Path == "/api/chat").ToList();
        Assert.Equal(4, requests.Count);
        Assert.All(requests, request =>
        {
            using var json = JsonDocument.Parse(request.Body!);
            var options = json.RootElement.GetProperty("options");
            Assert.Equal(tokens, options.GetProperty("num_ctx").GetInt32());
            Assert.InRange(options.GetProperty("num_predict").GetInt32(), 1, tokens / 2);
        });
    }

    [Fact]
    public async Task ReviseConcepts_ParsesAdditionsAndDeletionsWithGroups()
    {
        var output = JsonSerializer.Serialize(new {
            revisions = Array.Empty<object>(),
            additions = new[] { new { title = "새 개념", content = "내용", pageNumbers = Array.Empty<int>(), importance = "high", groupId = "replace", reason = "교체" } },
            deletions = new[] { new { id = "c1", reason = "교체 요청", groupId = "replace" } }
        });
        var handler = new RecordingHandler(request => request.RequestUri!.AbsolutePath == "/api/tags"
            ? JsonResponse(HttpStatusCode.OK, new { models = new[] { new { name = "qwen3:8b" } } })
            : JsonResponse(HttpStatusCode.OK, new { done = true, message = new { content = output } }));
        var changes = await CreateProvider(handler).ReviseConceptsAsync(new ConceptRevisionInput(
            "source", "자료", 0, "교체", [new ConceptRevisionContext("c1", "제목", "내용", [], "held")],
            ["c1"], ConceptRevisionPrompt.Version, true, true), TestContext.Current.CancellationToken);
        Assert.Equal(["add", "delete"], changes.Select(item => item.Kind));
        Assert.All(changes, item => Assert.Equal("replace", item.GroupId));
        Assert.Equal("교체 요청", changes[1].Reason);
    }

    private static OllamaLlmProvider CreateProvider(
        HttpMessageHandler handler,
        string apiKey = "",
        int? contextWindowTokens = null)
    {
        return new OllamaLlmProvider(
            new HttpClient(handler),
            Options.Create(new LlmOptions
            {
                Provider = "ollama",
                Model = "qwen3:8b",
                BaseUrl = "http://127.0.0.1:11434",
                ApiKey = apiKey,
                ContextWindowTokens = contextWindowTokens
            }),
            NullLogger<OllamaLlmProvider>.Instance);
    }

    private static QuestionGenerationInput Input() => new(
        "가우스 법칙은 폐곡면의 전기선속과 내부 전하를 연결한다.",
        1,
        ["shortAnswer"],
        "전자기학",
        "question-generation-v2-grounded");

    private static HttpResponseMessage JsonResponse(
        HttpStatusCode statusCode,
        object body)
    {
        return new HttpResponseMessage(statusCode)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(body),
                Encoding.UTF8,
                "application/json")
        };
    }

    private sealed class RecordingHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory)
        : HttpMessageHandler
    {
        public List<RecordedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(new RecordedRequest(
                request.RequestUri!.AbsolutePath,
                request.Content is null
                    ? null
                    : await request.Content.ReadAsStringAsync(cancellationToken),
                request.Headers.Authorization?.ToString()));
            return responseFactory(request);
        }
    }

    private sealed record RecordedRequest(
        string Path,
        string? Body,
        string? Authorization);
}
