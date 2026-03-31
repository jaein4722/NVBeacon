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
- 로컬 Mac에서 대상 서버로 비밀번호 없이 `ssh` 가능해야 합니다.
- 원격 서버에서 `nvidia-smi` 실행 가능해야 합니다.

## Run

```bash
swift run
```

또는 Xcode에서 `Package.swift`를 열어서 실행해도 됩니다.

## First-time setup

앱을 실행한 뒤 메뉴바 아이콘을 눌러 아래 값을 입력합니다.

- `SSH Target`: `gpu-prod` 또는 `user@host`
- `Identity File`: 선택 사항, 필요하면 `~/.ssh/id_ed25519`
- `Refresh Interval`: polling 간격(초)
- `Remote Command`: 기본값은 `nvidia-smi` 쿼리, 필요하면 절대 경로로 변경

## Notes

- 이 앱은 macOS의 기존 SSH 키와 `~/.ssh/config`를 그대로 사용합니다.
- 서버에서 non-interactive shell의 PATH가 다르면 `Remote Command`에 `/usr/bin/nvidia-smi ...` 같은 전체 경로를 넣으세요.

## Package For Distribution

```bash
./scripts/package_app.sh
```

기본 실행 결과:

- `dist/GPUUsage.app`
- `dist/GPUUsage-0.1.0.zip`

옵션 환경 변수:

- `VERSION=0.1.0`
- `BUILD_NUMBER=1`
- `BUNDLE_ID=com.example.GPUUsage`
- `CODESIGN_IDENTITY="Developer ID Application: ..."`
- `NOTARIZE=1`
- `APPLE_ID=...`
- `APPLE_TEAM_ID=...`
- `APPLE_APP_PASSWORD=...`

설명:

- `CODESIGN_IDENTITY`가 없으면 ad-hoc 서명으로 로컬 배포용 앱을 만듭니다.
- 외부 사용자에게 배포하려면 `Developer ID Application` 서명과 notarization이 필요합니다.
