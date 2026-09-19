# 복습 노트

Android와 Windows에서 사용할 수 있는 Flutter 기반 개인용 복습 앱입니다.
MVP 2부터는 .NET 10 개인 서버를 통한 기기 간 동기화를 지원하도록 개발 중입니다.

## 주요 메뉴

- 문제 풀기
- 문제 관리
- 통계
- 설정

## 실행

```bash
flutter pub get
flutter run
```

특정 플랫폼에서 실행하려면 연결된 기기를 확인한 뒤 대상을 지정합니다.

```bash
flutter devices
flutter run -d windows
```

## 검증

```bash
flutter analyze
flutter test
```

## 동기화 서버

Windows 앱에서는 `설정 → Local Server`에서 Provider, Model, API Key, Port를
입력하고 `Start Server`를 누르면 됩니다. 앱은 개발 단계에서 서버 프로젝트를
찾아 `dotnet run`을 실행하고, `/health` 응답을 확인한 뒤에만 Running으로
표시합니다. 서버 로그 확인과 중지도 같은 화면에서 할 수 있습니다. API Key는
Windows 보안 저장소에만 저장되며 일반 설정 파일이나 로그에는 기록되지 않습니다.
기본 Provider는 `Ollama`, 기본 모델은 `qwen3:8b`이며 이 조합에는 API Key가
필요하지 않습니다.

로컬 서버를 처음 사용할 때는 `설정 → 동기화`에
`http://127.0.0.1:5080`과 임의의 접근 토큰을 먼저 저장하세요. Local Server는
이 토큰을 서버에 전달하므로 Android에도 같은 토큰을 설정할 수 있습니다.
Android에는 Local Server 실행 메뉴가 표시되지 않습니다.

PowerShell 수동 실행은 개발 또는 문제 해결 시에만 사용할 수 있습니다.

서버 실행 전 `Sync__AccessToken` 환경 변수를 설정합니다. 토큰은 저장소에 커밋하지 않습니다.

```powershell
$env:Sync__AccessToken = '<private-token>'
dotnet run --project server/ReviewPlatform.Server -- --urls http://0.0.0.0:5080
```

앱의 `설정 → 동기화`에서 PC의 사설 IP 주소(예: `http://192.168.0.10:5080`)와 같은 토큰을 저장합니다. 이후 앱 실행, 포그라운드 복귀, 로컬 데이터 변경 3초 후, 15분 주기로 자동 동기화하며 수동 동기화도 사용할 수 있습니다. HTTP 연결은 신뢰할 수 있는 개인 네트워크나 VPN에서만 사용합니다.

서버 테스트:

```bash
dotnet test server/ReviewPlatform.Server.Tests
```

## AI 문제 생성 서버

기본 설정은 로컬 Ollama와 Qwen3 8B를 사용합니다. Ollama가 실행 중이고 모델이
설치되어 있으면 별도 API Key 없이 사용할 수 있습니다.

```powershell
$env:Llm__Provider = 'ollama'
$env:Llm__Model = 'qwen3:8b'
$env:Llm__BaseUrl = 'http://127.0.0.1:11434'
dotnet run --project server/ReviewPlatform.Server
```

`GET /api/ai/ollama/status`에서 Ollama 연결 여부와 설정된 모델의 설치 여부를
확인할 수 있습니다. 이 API도 다른 AI API와 동일한 `X-Sync-Token` 인증을
사용합니다. 서버는 Ollama를 자동 설치·실행하거나 모델을 자동으로 내려받지 않습니다.

OpenAI Provider를 활성화할 때는 Flutter 앱이 아닌 서버 실행 환경에만 API 키를 설정합니다.

```powershell
$env:Llm__Provider = 'openai'
$env:Llm__Model = 'gpt-4o-mini'
$env:OPENAI_API_KEY = '<openai-api-key>'
```

서버를 재시작한 뒤 `POST /api/ai/questions/generate`를 사용할 수 있습니다. OpenAI 응답은 strict JSON Schema로 제한되며, 서버의 독립적인 문제 규칙 검증을 한 번 더 통과해야 저장됩니다.

앱에서는 `문제 관리 → 폴더 → AI 문제 생성` 순서로 사용합니다. 문제 수는 학습자료의 개념별 생성량을 정하는 자동 모드(적음 1~2개, 보통 3~4개, 많음 5~6개) 또는 총 문제 수를 직접 입력하는 수동 모드로 설정합니다. 생성된 문제는 모두 Draft로 저장되며 개별 승인, 수정 후 승인, 거절, 일괄 승인을 지원합니다. Draft는 승인되기 전에는 퀴즈에 출제되지 않습니다.
