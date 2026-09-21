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
- `GET /api/llm/settings`
- `PUT /api/llm/settings`
- `POST /api/ai/questions/generate`
- `POST /api/documents/import` (`multipart/form-data`, field: `file`)

`/api/sync/*` 요청에는 `X-Sync-Token` 헤더가 필요합니다. 토큰은 소스 코드나 Git에 저장하지 않습니다.

AI API도 동일한 `X-Sync-Token` 헤더로 보호됩니다. AI 문제 생성 요청은 최대 50,000자를 지원하며 유형은 `multipleChoice`, `trueFalse`, `shortAnswer`입니다. 수동 모드는 총 1~20개를 생성하고, 자동 모드는 학습자료의 각 핵심 개념마다 `low` 1~2개, `medium` 3~4개, `high` 5~6개를 생성하도록 지시합니다. 응답은 전체가 구조 검증을 통과해야만 반환되고, provider/model/promptVersion/inputHash 생성 이력이 저장됩니다. 생성 결과는 항상 Draft이며 각 문제에는 학습자료 참조가 필요합니다.

기본 LLM Provider는 로컬 Ollama입니다.

```powershell
$env:Llm__Provider = 'ollama'
$env:Llm__Model = 'qwen3-vl:8b-instruct'
$env:Llm__BaseUrl = 'http://127.0.0.1:11434'
```

위 환경 변수는 프로필 DB가 비어 있을 때 최초 기본 프로필을 만드는 부트스트랩
설정입니다. 이후 Provider, Model, Ollama Base URL과 용도별 할당은
`GET/PUT /api/llm/settings`로 조회·변경하며 서버 재시작 없이 새 요청부터 적용됩니다.
현재 지원 용도는 `questionGeneration`, `conceptExtraction`, `documentVision`입니다. API Key는 이 API의
요청이나 응답에 포함되지 않고 서버 실행 환경에만 남습니다.

Ollama Provider는 `/api/tags`로 연결 및 모델 설치 상태를 확인한 뒤 `/api/chat`에
`stream: false`와 JSON Schema를 전달합니다. 최종 결과는 `message.content`만
역직렬화하며 Qwen의 `message.thinking`은 저장하거나 노출하지 않습니다. Ollama와
모델은 자동으로 실행하거나 설치하지 않습니다.

PDF OCR 기본 모델은 `qwen3-vl:8b-instruct`입니다. `qwen3-vl:8b`가 구조화 결과를
`message.thinking`에만 반환하는 경우에도 해당 내용을 결과로 사용하지 않고, 설정을
수정할 수 있는 명확한 오류를 반환합니다.

OpenAI Provider를 사용하려면 서버를 실행하기 전에 다음 환경 변수를 설정합니다. API 키는 Flutter 앱, `appsettings.json`, Git 저장소에 저장하지 않습니다.

```powershell
$env:Llm__Provider = 'openai'
$env:Llm__Model = 'gpt-4o-mini'
$env:OPENAI_API_KEY = '<openai-api-key>'
```

OpenAI 요청은 Responses API의 strict JSON Schema Structured Outputs를 사용하며 API 응답 저장을 비활성화합니다. Provider가 미설정이면 AI API는 503을 반환합니다.

PDF Import API는 최대 25MB, 300페이지의 PDF를 받고 PdfPig로 페이지별 텍스트
레이어를 우선 추출합니다. 텍스트가 부족한 페이지는 PDFium으로 JPEG 렌더링한 뒤
`documentVision` 프로필의 LLM에 전달합니다. Qwen3-VL을 사용하는 것이 기본이며
Ollama 요청의 `messages[].images`에 Base64 이미지가 포함됩니다. 원본은 기본적으로
`App_Data/sources`에 저장하며 `Documents__StoragePath`로 위치를 변경할 수 있습니다.
OCR 캐시는 기본적으로 `App_Data/document-page-cache`에 저장하고
`Documents__PageCachePath`로 변경할 수 있습니다. 한 요청에서 이미지 분석이 필요한
페이지는 현재 최대 50페이지입니다. 추출 내용은 페이지 번호와 함께 구조화 Concept
추출로 전달되고 결과는 항상 Draft입니다.
