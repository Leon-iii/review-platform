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
