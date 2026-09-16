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

`/api/sync/*` 요청에는 `X-Sync-Token` 헤더가 필요합니다. 토큰은 소스 코드나 Git에 저장하지 않습니다.
