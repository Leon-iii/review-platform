# Review Platform Sync Server

.NET 10과 SQLite를 사용하는 개인용 동기화 서버입니다.

환경 변수 `Sync__AccessToken`에 충분히 긴 임의 토큰을 설정한 뒤 실행합니다.

```powershell
$env:Sync__AccessToken = '<private-token>'
dotnet run --project server/ReviewPlatform.Server -- --urls http://0.0.0.0:5080
```

API:

- `GET /health`
- `POST /api/sync/push`
- `GET /api/sync/pull?sinceRevision=0`
- `GET /api/ai/ollama/status`
- `POST /api/ai/questions/generate`

`/api/sync/*` 요청에는 `X-Sync-Token` 헤더가 필요합니다. 토큰은 소스 코드나 Git에 저장하지 않습니다.

AI API도 동일한 `X-Sync-Token` 헤더로 보호됩니다. AI 문제 생성 요청은 최대 50,000자를 지원하며 유형은 `multipleChoice`, `trueFalse`, `shortAnswer`입니다. 수동 모드는 총 1~20개를 생성하고, 자동 모드는 학습자료의 각 핵심 개념마다 `low` 1~2개, `medium` 3~4개, `high` 5~6개를 생성하도록 지시합니다. 응답은 전체가 구조 검증을 통과해야만 반환되고, provider/model/promptVersion/inputHash 생성 이력이 저장됩니다. 생성 결과는 항상 Draft이며 각 문제에는 학습자료 참조가 필요합니다.

기본 LLM Provider는 로컬 Ollama입니다.

```powershell
$env:Llm__Provider = 'ollama'
$env:Llm__Model = 'qwen3:8b'
$env:Llm__BaseUrl = 'http://127.0.0.1:11434'
```

Ollama Provider는 `/api/tags`로 연결 및 모델 설치 상태를 확인한 뒤 `/api/chat`에
`stream: false`와 JSON Schema를 전달합니다. 최종 결과는 `message.content`만
역직렬화하며 Qwen의 `message.thinking`은 저장하거나 노출하지 않습니다. Ollama와
모델은 자동으로 실행하거나 설치하지 않습니다.

OpenAI Provider를 사용하려면 서버를 실행하기 전에 다음 환경 변수를 설정합니다. API 키는 Flutter 앱, `appsettings.json`, Git 저장소에 저장하지 않습니다.

```powershell
$env:Llm__Provider = 'openai'
$env:Llm__Model = 'gpt-4o-mini'
$env:OPENAI_API_KEY = '<openai-api-key>'
```

OpenAI 요청은 Responses API의 strict JSON Schema Structured Outputs를 사용하며 API 응답 저장을 비활성화합니다. Provider가 미설정이면 AI API는 503을 반환합니다.
