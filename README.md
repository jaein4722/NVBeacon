# GPUUsage

macOS 메뉴바에서 원격 서버의 `nvidia-smi` 결과를 주기적으로 가져와 GPU 사용량을 보여주는 간단한 앱입니다.

## How it works

- 로컬 Mac에서 `ssh`를 실행합니다.
- 원격 서버에서 `nvidia-smi --query-gpu=... --format=csv,noheader,nounits`를 호출합니다.
- 메뉴바에는 평균 utilization과 busy GPU 수를 요약해서 보여줍니다.
- 드롭다운에는 GPU별 utilization, memory, temperature를 표시합니다.

## Requirements

- macOS 14+
- Xcode 26+ 또는 Swift 6.3+
- 로컬 Mac에서 대상 서버로 `ssh` 가능해야 합니다.
- 원격 서버에서 `nvidia-smi` 실행 가능해야 합니다.

## Run

```bash
swift run
```

또는 Xcode에서 `Package.swift`를 열어서 실행해도 됩니다.

## First-time setup

앱을 실행한 뒤 메뉴바 아이콘을 우클릭해서 `Settings…`를 엽니다. 설정 창은 macOS 기본 Settings 스타일을 따르며, `General`, `Appearance`, `Advanced`, `About` 네 섹션으로 나뉩니다. 변경 사항은 `Apply` 없이 자동 반영됩니다.

- `Import From ~/.ssh/config`: 로컬 `~/.ssh/config`에 등록된 alias를 바로 가져와 적용
- `SSH Target`: `gpu-prod` 또는 `user@host`
- `Identity File`: 선택 사항, 필요하면 `~/.ssh/id_ed25519`
- `SSH Password`: 선택 사항, 입력하면 비밀번호 인증 사용
- `Refresh Interval`: polling 간격(초)
- `Menu Bar Summary`: 메뉴바에 `평균 사용률`, `busy GPU 수`, 둘 다, 또는 `icon only` 표시
- `Remote Command`: 기본값은 `nvidia-smi` 쿼리, 필요하면 절대 경로로 변경

좌클릭:

- 현재 GPU 상태와 프로세스 정보를 보여주는 팝오버를 엽니다.
- 팝오버 오른쪽 상단의 새로고침 아이콘으로 즉시 polling 가능

우클릭:

- `Settings…`
- `Quit GPUUsage`

## Notes

- 이 앱은 macOS의 기존 SSH 키와 `~/.ssh/config`를 그대로 사용합니다.
- 비밀번호 인증을 쓰는 경우 비밀번호는 `UserDefaults`가 아니라 macOS Keychain에 저장합니다.
- 서버에서 non-interactive shell의 PATH가 다르면 `Remote Command`에 `/usr/bin/nvidia-smi ...` 같은 전체 경로를 넣으세요.

## Package For Distribution

```bash
./scripts/package_app.sh
```

기본 실행 결과:

- `dist/GPUUsage.app`
- `dist/GPUUsage-0.2.1.zip`

옵션 환경 변수:

- `VERSION=0.2.1`
- `BUILD_NUMBER=1`
- `BUNDLE_ID=com.example.GPUUsage`
- `CODESIGN_IDENTITY="Developer ID Application: ..."`
- `NOTARIZE=1`
- `KEYCHAIN_PROFILE=GPUUsageNotary`
- `APPLE_ID=...`
- `APPLE_TEAM_ID=...`
- `APPLE_APP_PASSWORD=...`

설명:

- `CODESIGN_IDENTITY`가 없으면 ad-hoc 서명으로 로컬 배포용 앱을 만듭니다.
- 외부 사용자에게 배포하려면 `Developer ID Application` 서명과 notarization이 필요합니다.
- ad-hoc 빌드는 다른 Mac에서 Gatekeeper에 의해 차단되는 것이 정상입니다.

### Real Distribution

1. Apple Developer Program 계정에서 `Developer ID Application` 인증서를 만든 뒤 Keychain에 설치합니다.
2. notarization 자격 증명을 저장합니다.

```bash
xcrun notarytool store-credentials "GPUUsageNotary"
```

3. 배포용 앱을 빌드하고 notarize 합니다.

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
KEYCHAIN_PROFILE="GPUUsageNotary" \
./scripts/package_app.sh
```

4. 스크립트가 끝난 뒤 `dist/GPUUsage-0.2.1.zip`를 배포합니다.
