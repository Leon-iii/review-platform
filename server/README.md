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
현재 지원 용도는 `questionGeneration`, `conceptExtraction`, `conceptRevision`,
`documentVision`입니다. `PUT /api/llm/settings`에서는 OpenAI, Gemini, Claude API Key를
선택적으로 저장할 수 있습니다. 서버는 키를 Data Protection으로 암호화하며,
`GET`과 `PUT` 응답에는 원문 대신 Provider별 설정 여부만 반환합니다.

프로필의 `contextWindowTokens`가 `null`이면 자동 모드입니다. 기존 프로필은
데이터를 보존하면서 자동 모드로 업그레이드합니다. Ollama의 수동 크기는
`/api/show`의 모델 최대 컨텍스트 정보로 검증하고 모든 작업의 `num_ctx`에
적용합니다. 작은 수동 창에서는 출력 예산을 창의 절반 이하로 제한합니다.
클라우드 Provider는 자동 모드를 사용하며 로컬 `num_ctx` 튜닝과
8,000자·8페이지 PDF 배치 제한을 적용하지 않습니다. 출력 토큰 예산과
파일·페이지·텍스트 크기 등 앱의 입력 검증은 별도로 유지합니다.

OpenAI 프로필의 `reasoningEffort`는 `null`(자동) 또는 해당 모델이 지원하는 값입니다.
자동이면 Responses API의 `reasoning` 필드를 생략합니다. 지원 값은
`AI/openai-model-capabilities.json`의 공식 문서 기반 내장 레지스트리에서 관리합니다.
별칭과 스냅샷 ID를 정확히 대조하며 새 모델의 능력을 이름으로 추측하지 않습니다.
`GET /api/llm/models?provider=openai` 응답의 `modelCapabilities`에는 각 모델의
등록 여부와 추론 선택지를 포함합니다. 미등록 모델은 UI에서 주황색으로 표시하고
자동만 허용합니다. 모델 목록 API는 능력 정보를 제공하지 않으므로 이 레지스트리는
개발자가 공식 문서를 검토해 갱신해야 합니다.
2026-10-01 검토 기준 79개 모델 ID(별칭·스냅샷 포함)를 등록했습니다.
`supportsReasoning: true`이면서 추론 선택지가 비어 있으면 공식 문서에서 수동 값이
명확하게 확인되지 않아 자동만 제공하는 정책입니다. 비추론 모델로 간주하지 않습니다.
`supportsStructuredOutputs: false`인 모델과 Chat Completions 전용 검색 모델은
목록에서 제외합니다. 저장·실행 시에도 등록된 비호환 모델을 거부합니다.
모델 목록의 `modelMetadata`는 Provider 공통의 `lifecycle`과 `isSnapshot`을 제공합니다.
`AI/llm-model-metadata.json`은 정확한 Provider·모델 ID별로 `current`, `legacy`,
`deprecated`, `retired`를 관리하며, 미등록 모델은 `unknown`으로 반환합니다.
`legacy`는 후속 모델이 있는 이전 세대에 대한 앱의 표시 분류이지, 사용 불가 판정이나
OpenAI의 공식 legacy 지정과 동일한 뜻은 아닙니다. 지원 중단 예정과 종료는 별도로
구분합니다. 구형/스냅샷 필터는 클라이언트 표시만 바꾸며 서버 원본 목록이나 프로필을
삭제하지 않습니다. 다른 Provider는 JSON에 분류를 추가해 같은 필터를 재사용할 수
있습니다. 기기별 설정은 앱 지원 디렉터리의 `llm_model_filters.json`에 Provider ID별로
저장하며, 추후 지원할 Provider의 설정도 보존합니다.
추론 모델은 내부 추론과 JSON 출력이 공유하는 `max_output_tokens`를 고려해 예산을
확보하고, 지원하지 않는 수동 값은 API 호출 전에 거부합니다.

Ollama Provider는 `/api/tags`로 연결 및 모델 설치 상태를 확인한 뒤 `/api/chat`에
`stream: false`와 JSON Schema를 전달합니다. 최종 결과는 `message.content`만
역직렬화하며 Qwen의 `message.thinking`은 저장하거나 노출하지 않습니다. Ollama와
모델은 자동으로 실행하거나 설치하지 않습니다.

PDF OCR 기본 모델은 `qwen3-vl:8b-instruct`입니다. `qwen3-vl:8b`가 구조화 결과를
`message.thinking`에만 반환하는 경우에도 해당 내용을 결과로 사용하지 않고, 설정을
수정할 수 있는 명확한 오류를 반환합니다.

OpenAI Provider를 사용하려면 앱의 `설정 → 용도별 AI 설정 → API Key`에서 키를
저장합니다. 환경 변수는 DB에 해당 Provider 키가 아직 없을 때만 가져오는
부트스트랩 수단입니다. 키를 `appsettings.json`이나 Git 저장소에 넣지 마세요.

```powershell
$env:Llm__Provider = 'openai'
$env:Llm__Model = 'gpt-4o-mini'
$env:OPENAI_API_KEY = '<openai-api-key>'
$env:GEMINI_API_KEY = '<gemini-api-key>'
$env:ANTHROPIC_API_KEY = '<claude-api-key>'
```

Claude 키는 `CLAUDE_API_KEY` 환경 변수 이름도 인식합니다. Gemini와 Claude는 현재
키 보관만 지원하며 Provider 호출 연동은 후속 범위입니다. OpenAI 요청은 Responses
API의 strict JSON Schema Structured Outputs를 사용하며 API 응답 저장을
비활성화합니다. Provider가 미설정이면 AI API는 503을 반환합니다.

PDF Import API는 최대 25MB, 300페이지의 PDF를 받고 PdfPig로 페이지별 텍스트
레이어를 우선 추출합니다. 텍스트가 부족한 페이지는 PDFium으로 JPEG 렌더링한 뒤
`documentVision` 프로필의 LLM에 전달합니다. Qwen3-VL을 사용하는 것이 기본이며
Ollama 요청의 `messages[].images`에 Base64 이미지가 포함됩니다. 원본은 기본적으로
`App_Data/sources`에 저장하며 `Documents__StoragePath`로 위치를 변경할 수 있습니다.
OCR 캐시는 기본적으로 `App_Data/document-page-cache`에 저장하고
`Documents__PageCachePath`로 변경할 수 있습니다. 한 요청에서 이미지 분석이 필요한
페이지는 현재 최대 50페이지입니다. 추출 내용은 페이지 번호와 함께 구조화 Concept
추출로 전달되고 결과는 항상 Draft입니다.
