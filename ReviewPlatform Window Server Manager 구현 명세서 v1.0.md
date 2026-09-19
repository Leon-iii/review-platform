# ReviewPlatform Windows Server Manager 구현 명세서 v1.0

## 1. 목적

기존 ASP.NET Core 서버를 PowerShell에서 수동으로 실행하던 절차를 Windows용 Flutter GUI에서 제어할 수 있도록 한다.

현재 수동 실행 방식은 다음과 같다.

```powershell
cd C:\Users\Leon\review_platform\server\ReviewPlatform.Server

$env:Llm__Provider = "openai"
$env:Llm__Model = "gpt-4o-mini"
$env:OPENAI_API_KEY = "<API KEY>"

dotnet run
```

최종 목표는 사용자가 Windows용 ReviewPlatform 앱에서 설정을 입력하고 버튼 하나로 서버를 시작/중지할 수 있도록 만드는 것이다.

---

# 2. 핵심 결정사항

별도의 Server Manager 애플리케이션을 새로 만들지 않는다.

기존 Flutter Windows ReviewPlatform 클라이언트 내부의:

```text
Settings
└─ Local Server
```

화면으로 구현한다.

Android에서는 Local Server 관리 기능을 노출하지 않는다.

Windows에서만 사용할 수 있는 기능이다.

개념적으로:

```text
ReviewPlatform Flutter App

Android
└─ Client only

Windows
├─ Client
└─ Local Server Manager
```

---

# 3. 목표 사용자 흐름

사용자는 Windows ReviewPlatform 앱에서:

```text
Settings
→ Local Server
```

로 이동한다.

화면에는 다음 항목이 존재한다.

```text
LLM Provider
LLM Model
API Key
Server Port

Server Status

Start Server
Stop Server

Server Logs
```

예상 UI:

```text
Review Platform Server

LLM Provider
[ OpenAI                    ▼ ]

Model
[ gpt-4o-mini                 ]

API Key
[ •••••••••••••••••••••     ]

Server Port
[ 5080                        ]

Status
● Running

Address
http://localhost:5080

[ Start Server ]
[ Stop Server  ]

────────────────────────

Server Logs

info: Application started
info: Now listening on ...
...
```

---

# 4. 구현 단계

Server Manager는 단계적으로 구현한다.

## Phase 1

개발 중에는 Flutter에서 다음 명령을 실행한다.

```text
dotnet run
```

Working Directory:

```text
server/ReviewPlatform.Server
```

환경변수는 Flutter의 `Process.start()`에서 직접 전달한다.

---

## Phase 2

서버가 안정화되면 `dotnet run`을 제거한다.

ASP.NET Server를 publish하여:

```text
ReviewPlatform.Server.exe
```

를 생성한다.

Flutter는 publish된 executable을 직접 실행한다.

최종적으로 .NET SDK가 설치되어 있지 않은 환경에서도 서버가 실행될 수 있도록 self-contained publish를 고려한다.

예:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true
```

---

## Phase 3

필요할 경우 추후 Windows Service로 전환한다.

현재 구현 범위에는 포함하지 않는다.

향후 가능한 기능:

```text
Windows 로그인 시 서버 자동 시작

Tray 실행

Flutter 앱 종료 후에도 서버 유지

Windows Service 등록
```

---

# 5. 플랫폼 제한

Server Manager 관련 코드는 Windows에서만 동작해야 한다.

Windows가 아닌 플랫폼에서 `dart:io`의 Process 실행 기능을 호출하지 않는다.

UI 역시 Windows에서만 표시한다.

예:

```dart
if (Platform.isWindows) {
  // Local Server Settings
}
```

Android에서는 서버 실행 메뉴 자체를 숨긴다.

---

# 6. Flutter 구조

기존 프로젝트 architecture를 유지한다.

Server Manager 기능은 다음과 같이 구성한다.

```text
lib/
└─ features/
   └─ settings/
      └─ local_server/
         ├─ local_server_view.dart
         ├─ local_server_view_model.dart
         ├─ local_server_state.dart
         └─ widgets/
```

프로세스 실행 자체는 UI에 직접 구현하지 않는다.

별도 Service를 만든다.

```text
lib/
└─ core/
   └─ server/
      ├─ local_server_service.dart
      └─ local_server_config.dart
```

의존성 흐름:

```text
View
↓
ViewModel
↓
LocalServerService
↓
Process
```

View에서 `Process.start()`를 직접 호출하지 않는다.

---

# 7. LocalServerConfig

서버 실행 설정을 표현하는 모델을 만든다.

개념 구조:

```dart
class LocalServerConfig {
  final String provider;
  final String model;
  final int port;

  const LocalServerConfig({
    required this.provider,
    required this.model,
    required this.port,
  });
}
```

API Key는 일반 Config object에 영구 저장하지 않는다.

실행 직전에 Secure Storage에서 읽는다.

---

# 8. 서버 환경변수

Phase 1에서는 서버를 실행할 때 다음 환경변수를 전달한다.

필수:

```text
Llm__Provider
Llm__Model
OPENAI_API_KEY
ASPNETCORE_URLS
```

예:

```text
Llm__Provider=openai

Llm__Model=gpt-4o-mini

OPENAI_API_KEY=<secret>

ASPNETCORE_URLS=http://0.0.0.0:5080
```

Process 실행 시 기존 환경변수를 유지해야 한다.

개념 코드:

```dart
final environment = {
  ...Platform.environment,
  'Llm__Provider': config.provider,
  'Llm__Model': config.model,
  'OPENAI_API_KEY': apiKey,
  'ASPNETCORE_URLS': 'http://0.0.0.0:${config.port}',
};
```

---

# 9. Provider 확장성

현재 첫 Provider는:

```text
OpenAI
```

이다.

향후 다음 Provider 추가 가능성을 고려한다.

```text
Gemini
Local Model
기타 Provider
```

Provider enum 또는 이에 준하는 구조를 사용한다.

예:

```text
openai
gemini
local
```

Provider에 따라 API Key 환경변수 이름이 달라질 수 있다.

예:

```text
OpenAI
→ OPENAI_API_KEY

Gemini
→ GEMINI_API_KEY
```

Provider별 실행 environment 생성 책임을 UI에 넣지 않는다.

Service 또는 별도 mapper에서 처리한다.

---

# 10. Model 입력

초기 버전에서는 Model을 Dropdown으로 하드코딩하지 않는다.

단순 TextField를 사용한다.

예:

```text
gpt-4o-mini
```

이유:

모델 이름은 향후 변경될 수 있기 때문이다.

추후 서버에서 model list를 반환할 수 있게 되면 동적 Dropdown으로 변경 가능하다.

---

# 11. 일반 설정 저장

다음 값은 일반 local settings에 저장할 수 있다.

```text
provider
model
port
```

예:

```json
{
  "provider": "openai",
  "model": "gpt-4o-mini",
  "port": 5080
}
```

API Key는 여기에 저장하지 않는다.

---

# 12. API Key 저장

API Key는 평문 JSON, SharedPreferences, source code, Git repository 등에 저장하지 않는다.

Flutter secure storage 또는 이에 준하는 Windows secure storage 방식을 사용한다.

저장 대상 예:

```text
review_platform.openai_api_key
```

API Key 필드는 기본적으로 obscured 상태로 표시한다.

필요하다면:

```text
Show / Hide
```

토글을 제공한다.

---

# 13. API Key 로그 금지

다음 정보는 절대 로그에 출력하지 않는다.

```text
OPENAI_API_KEY

GEMINI_API_KEY

Authorization header

전체 Process environment
```

Error 발생 시에도 secret을 포함한 환경 전체 dump를 하지 않는다.

---

# 14. LocalServerService

Server process lifecycle을 관리하는 Service를 만든다.

책임:

```text
start()

stop()

healthCheck()

stdout 수집

stderr 수집

exit code 감시

현재 process 상태 관리
```

개념적으로 내부에:

```dart
Process? _process;
```

를 가진다.

---

# 15. 서버 시작

`start()` 호출 시 다음 순서로 동작한다.

```text
현재 서버 실행 여부 확인
↓
Config validation
↓
API Key 읽기
↓
Process.start()
↓
stdout/stderr listener 연결
↓
Starting 상태
↓
Health Check
↓
Running 상태
```

이미 실행 중일 경우 두 번째 process를 시작하지 않는다.

---

# 16. Phase 1 Process 실행

Phase 1:

```text
Executable:
dotnet

Arguments:
run

Working Directory:
server/ReviewPlatform.Server
```

개념 코드:

```dart
Process.start(
  'dotnet',
  ['run'],
  workingDirectory: serverDirectory,
  environment: environment,
);
```

shell을 직접 호출하지 않는다.

다음 구조는 사용하지 않는다.

```text
powershell.exe
↓
cd ...
↓
$env...
↓
dotnet run
```

환경변수와 workingDirectory는 Process API에서 직접 지정한다.

---

# 17. Phase 2 Process 실행

Phase 2에서는:

```text
ReviewPlatform.Server.exe
```

를 직접 실행한다.

예:

```dart
Process.start(
  serverExecutablePath,
  [],
  environment: environment,
);
```

workingDirectory는 server executable 위치로 설정한다.

---

# 18. 서버 중지

Stop 버튼을 누르면 현재 서버 process 종료를 시도한다.

초기 구현:

```dart
_process?.kill();
```

종료 후 process reference를 해제한다.

상태는:

```text
Stopping
↓
Stopped
```

으로 변경한다.

필요하면 향후 graceful shutdown endpoint를 추가할 수 있다.

---

# 19. 앱 종료 시 서버

초기 정책:

```text
ReviewPlatform Windows 앱 종료
→ 자식 Server process도 종료
```

즉 server lifecycle은 Windows Flutter 앱에 종속된다.

Flutter 앱 종료 후 서버가 백그라운드에서 계속 살아남도록 구현하지 않는다.

이 기능이 필요해질 경우 Windows Service로 전환한다.

---

# 20. Server Status

최소 다음 상태를 정의한다.

```text
stopped

starting

running

stopping

error
```

UI 표시 예:

```text
● Stopped

● Starting...

● Running

● Error
```

Process 객체가 존재한다는 이유만으로 `running`이라고 판단하지 않는다.

---

# 21. Health Check

ASP.NET 서버에 health endpoint를 추가한다.

권장:

```http
GET /health
```

정상 응답:

```json
{
  "status": "ok"
}
```

HTTP 200이면 서버가 실제 요청을 받을 준비가 된 것으로 판단한다.

---

# 22. 시작 성공 판정

Start 과정:

```text
Process 생성 성공

≠

Server Ready
```

따라서 반드시 Health Check까지 성공해야:

```text
running
```

상태로 변경한다.

Health Check가 일정 시간 동안 실패하면:

```text
error
```

상태로 변경한다.

Process가 이미 종료된 경우 exit code도 기록한다.

---

# 23. Health Check 주소

로컬 Windows 앱의 health check는 기본적으로:

```text
http://127.0.0.1:<port>/health
```

를 사용한다.

Server binding은 휴대폰 접근을 위해:

```text
http://0.0.0.0:<port>
```

로 설정할 수 있다.

둘을 혼동하지 않는다.

---

# 24. Server Address 표시

GUI에서는 최소:

```text
Local:
http://127.0.0.1:5080
```

을 표시한다.

향후 필요하면 LAN/Tailscale 주소도 표시할 수 있다.

현재 구현에서 자동 네트워크 인터페이스 탐색은 필수가 아니다.

---

# 25. 로그 수집

서버 stdout과 stderr를 모두 읽는다.

개념적으로:

```dart
process.stdout
    .transform(utf8.decoder)
    .listen(...);

process.stderr
    .transform(utf8.decoder)
    .listen(...);
```

로그는 UI에 실시간 표시한다.

---

# 26. 로그 버퍼

로그를 무제한 메모리에 누적하지 않는다.

초기에는 최근 일정 개수만 유지한다.

예:

```text
최근 1000 lines
```

오래된 로그부터 제거한다.

---

# 27. 로그 UI

기본 기능:

```text
자동 스크롤

Clear

복사 가능
```

추후:

```text
Log level filter
Export
```

를 추가할 수 있다.

초기 MVP에는 필요하지 않다.

---

# 28. Process 비정상 종료

서버 process가 사용자 Stop 요청 없이 종료되면:

```text
running
↓
error
```

로 상태를 변경한다.

UI에 다음 정보를 표시한다.

```text
Server exited unexpectedly.

Exit code: <code>
```

stderr 마지막 일부를 함께 볼 수 있도록 한다.

---

# 29. 설정 Validation

Start 전에 최소 다음을 검증한다.

```text
Provider가 비어있지 않음

Model이 비어있지 않음

Port 범위가 유효함

필요한 API Key 존재
```

Port:

```text
1 ~ 65535
```

를 허용하되 기본값은:

```text
5080
```

으로 한다.

---

# 30. Port 충돌

서버 시작 실패 원인이 port already in use인 경우 사용자가 이해할 수 있는 메시지를 표시한다.

예:

```text
Port 5080 is already in use.
Choose another port or stop the process using it.
```

초기 구현에서 자동으로 다른 port를 선택하지 않는다.

---

# 31. Working Directory 탐색

절대 경로:

```text
C:\Users\Leon\review_platform\...
```

를 source code에 하드코딩하지 않는다.

개발 환경과 publish 환경을 구분한다.

Phase 1 개발 중에는 프로젝트 root 기준 상대 경로 또는 개발 설정을 사용한다.

Phase 2에서는 executable 배치 위치를 기준으로 server executable을 탐색한다.

---

# 32. 개발 모드 / 배포 모드

가능하면 다음을 분리한다.

```text
Development

Server launcher:
dotnet run
```

```text
Release

Server launcher:
ReviewPlatform.Server.exe
```

환경별 launcher 선택 로직은 LocalServerService 내부에 둔다.

UI에서 구분하지 않는다.

---

# 33. Settings UI

Windows Settings에:

```text
Local Server
```

section을 추가한다.

최소 UI:

```text
Provider

Model

API Key

Port

Status

Start

Stop

Logs
```

Start button:

```text
Stopped / Error
→ enabled

Starting / Running / Stopping
→ disabled
```

Stop button:

```text
Running / Starting
→ enabled

Stopped
→ disabled
```

---

# 34. API Key 변경

서버 실행 중 API Key 또는 provider/model을 변경하더라도 기존 process에는 자동 적용되지 않는다.

설정 변경 후에는:

```text
Server restart required
```

표시가 가능하다.

초기 구현에서는 자동 restart하지 않는다.

---

# 35. Provider 변경

Provider를 변경하면 해당 Provider에 필요한 secret storage key를 사용한다.

예:

```text
OpenAI 선택
→ OpenAI API Key field

Gemini 선택
→ Gemini API Key field
```

Provider마다 서로 다른 key를 저장할 수 있도록 구조를 만든다.

---

# 36. 자동 시작

초기 구현 범위에서:

```text
Windows 시작 시 자동 실행
```

은 구현하지 않는다.

향후 별도 feature로 추가한다.

ReviewPlatform 실행 시 서버 자동 시작 역시 초기에는 기본 `false`로 둔다.

추후 옵션:

```text
[ ] ReviewPlatform 실행 시 서버 자동 시작
```

추가 가능.

---

# 37. 클라이언트 연결 설정

Windows 로컬 클라이언트가 자기 서버에 연결할 경우:

```text
http://127.0.0.1:<port>
```

를 사용한다.

Android 클라이언트에서는 서버 주소를 별도로 설정한다.

예:

```text
http://<PC IP>:5080
```

또는 향후:

```text
Tailscale address
```

를 사용할 수 있다.

---

# 38. 보안 원칙

현재 Server Manager는 개인용 서버를 대상으로 한다.

그러나 다음은 반드시 지킨다.

```text
API Key source code 저장 금지

API Key Git commit 금지

API Key 일반 settings 저장 금지

API Key 로그 출력 금지

API Key Flutter Android 클라이언트 전달 금지
```

LLM API 호출은 항상 ASP.NET Server에서 수행한다.

---

# 39. Android 제한

Android ReviewPlatform은:

```text
Server Manager
```

를 포함하지 않는다.

Android에서는 다음만 수행한다.

```text
Server URL 설정

Health Check

Server API 사용
```

Local ASP.NET Server process를 Android에서 실행하려고 시도하지 않는다.

---

# 40. 서버 Health Endpoint 구현

ASP.NET Server에 최소 health endpoint를 제공한다.

가능하면 dependency 없는 매우 단순한 endpoint로 만든다.

예:

```text
GET /health
```

응답:

```json
{
  "status": "ok"
}
```

Health endpoint는 LLM API 연결 성공 여부까지 검사하지 않아도 된다.

목적은:

```text
ASP.NET application이 요청을 수신할 수 있는가
```

를 확인하는 것이다.

---

# 41. LLM 별도 테스트

향후 Server Manager에:

```text
Test LLM
```

버튼을 추가할 수 있다.

이 기능은 health check와 분리한다.

예:

```text
Health Check
→ Server 자체 정상 여부

LLM Test
→ API Key / Provider / Model 정상 여부
```

초기 MVP에서는 선택 기능이다.

---

# 42. 상태 모델 예시

개념적인 state:

```dart
enum LocalServerStatus {
  stopped,
  starting,
  running,
  stopping,
  error,
}
```

ViewModel state:

```text
status

provider

model

port

logs

lastError

processExitCode
```

secret value 자체를 state dump/debug log에 포함하지 않는다.

---

# 43. ViewModel 책임

LocalServerViewModel:

```text
설정 load

설정 save

API Key save

start 요청

stop 요청

상태 update

log stream 구독

health check result 반영
```

Process 구현 세부사항은 ViewModel에 넣지 않는다.

---

# 44. LocalServerService 책임

```text
Process 생성

Process 종료

stdout/stderr stream

exitCode 관찰

health check

server executable 탐색

environment 구성
```

Flutter UI 관련 타입에 의존하지 않는다.

---

# 45. Codex 구현 금지사항

다음 구현은 하지 않는다.

```text
PowerShell script 파일을 매번 생성해서 실행

cmd.exe를 거쳐 dotnet 실행

API Key를 appsettings.json에 자동 저장

API Key를 SharedPreferences에 평문 저장

API Key를 로그에 출력

Flutter View에서 Process.start 직접 호출

Windows path 하드코딩

Android에서 Process 실행

서버 상태를 process != null만으로 판단
```

---

# 46. Phase 1 완료 조건

다음 조건을 모두 만족해야 한다.

1. Windows Settings에 Local Server 화면이 존재한다.

2. Provider를 입력/선택할 수 있다.

3. Model을 입력할 수 있다.

4. API Key를 secure storage에 저장할 수 있다.

5. Port를 설정할 수 있다.

6. Start 버튼으로 기존 ASP.NET Server를 `dotnet run`으로 실행할 수 있다.

7. 필요한 environment variables가 정상 전달된다.

8. Server stdout/stderr가 GUI에 표시된다.

9. `/health` 성공 후에만 Running으로 표시한다.

10. Stop 버튼으로 서버를 종료할 수 있다.

11. 서버가 비정상 종료되면 Error 상태로 전환한다.

12. Android에서는 Local Server 메뉴가 나타나지 않는다.

13. API Key가 log나 일반 settings에 나타나지 않는다.

---

# 47. Phase 2 완료 조건

Phase 1이 안정화된 후:

```text
dotnet run
```

dependency를 제거한다.

서버를 publish하고:

```text
ReviewPlatform.Server.exe
```

를 Flutter가 직접 실행한다.

최종 배포 구조 예:

```text
ReviewPlatform/
│
├─ ReviewPlatform.exe
│
├─ data/
│
└─ server/
   ├─ ReviewPlatform.Server.exe
   └─ ...
```

ReviewPlatform Windows 실행 파일이 자신의 설치 위치를 기준으로 server executable을 찾는다.

사용자가 .NET SDK 경로나 server project source directory를 알 필요가 없어야 한다.

---

# 48. 장기 목표

향후 필요할 경우:

```text
Windows Service

Auto Start

System Tray

Server background operation

Log export

Dynamic model list

Provider test

Tailscale address 표시

Server update
```

를 추가할 수 있다.

현재 구조는 이 기능들을 추가할 수 있도록 설계하되 선행 구현하지 않는다.

---

# 49. 구현 우선순위

Codex는 다음 순서로 작업한다.

```text
1. 기존 Settings architecture 분석

2. LocalServerConfig 작성

3. Secure storage 연동

4. LocalServerService 작성

5. ASP.NET /health 추가

6. LocalServerViewModel 작성

7. Windows Settings UI 작성

8. Process start/stop 구현

9. Log stream 구현

10. Health check 구현

11. Error handling

12. Windows 테스트

13. Android 메뉴 비노출 확인

14. flutter analyze

15. flutter test

16. flutter build windows
```

한 번에 Phase 2까지 구현하지 않는다.

우선 Phase 1을 완성한다.

---

# 50. Codex 작업 완료 시 검증 명령

Flutter:

```powershell
dart run build_runner build --delete-conflicting-outputs

flutter analyze

flutter test

flutter build windows
```

ASP.NET:

```powershell
dotnet build
```

가능하면 Server Manager에서 실제로:

```text
Start
↓
Health OK
↓
Running
↓
Stop
↓
Stopped
```

전체 flow를 확인한다.

---

# 51. 최종 제품 경험

Windows에서는 최종적으로 사용자가 다음 동작만 하면 된다.

```text
ReviewPlatform 실행
↓
Settings
↓
Local Server
↓
Provider / Model / API Key 설정
↓
Start Server
↓
● Running
```

그 이후 Android ReviewPlatform은 해당 PC 서버에 연결하여:

```text
문제 생성

PDF 분석

AI 채점

Sync
```

등의 서버 기능을 사용할 수 있어야 한다.

사용자가 PowerShell, `dotnet run`, 환경변수 설정, 프로젝트 경로 이동을 직접 수행할 필요가 없는 것이 이 기능의 최종 목적이다.
