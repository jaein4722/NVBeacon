# GPUUsage

macOS 메뉴바에서 원격 서버의 `nvidia-smi` 결과를 주기적으로 가져와 GPU 사용량을 보여주는 간단한 앱입니다.

짧은 릴리즈 기록은 [CHANGELOG.md](/Users/leejaein/Documents/SideProjects/GPUUsage/CHANGELOG.md)에서 관리합니다.

## How it works

- 로컬 Mac에서 `ssh`를 실행합니다.
- 원격 서버에서 `nvidia-smi --query-gpu=... --format=csv,noheader,nounits`를 호출합니다.
- 메뉴바에는 평균 utilization과 busy GPU 수를 요약해서 보여줍니다.
- 드롭다운에는 GPU별 utilization, memory, temperature를 표시합니다.

## Requirements

- macOS 14+
- Xcode 26+ 또는 Swift 6.2+
- 로컬 Mac에서 대상 서버로 `ssh` 가능해야 합니다.
- 원격 서버에서 `nvidia-smi` 실행 가능해야 합니다.

## Run

```bash
swift run
```

또는 Xcode에서 `Package.swift`를 열어서 실행해도 됩니다.

알림처럼 번들 앱이 필요한 기능을 개발 중에 확인하려면 테스트용 `.app`를 만드세요.

```bash
OPEN_APP=1 ./scripts/build_test_app.sh
open dist/GPUUsage-0.2.4-test-<commit>.app
```

이 스크립트는 기존 테스트 앱 프로세스를 종료하고, 이전 테스트 앱 번들을 정리한 뒤 새 테스트 앱을 생성합니다.

반복 개발용으로는 아래 스크립트를 쓰면 `swift build` 또는 `swift test` 뒤에 테스트용 `.app`까지 같이 생성합니다.

```bash
./scripts/dev_build.sh
./scripts/dev_test.sh
```

`swift build` / `swift test` 자체는 SwiftPM 차원에서 post-build hook을 붙일 수 없어서, 저장소에서는 위 dev 스크립트로 같은 흐름을 제공합니다.

## First-time setup

앱을 실행한 뒤 메뉴바 아이콘을 우클릭해서 `Settings…`를 엽니다. 설정 창은 macOS 기본 Settings 스타일을 따르며, `General`, `Notifications`, `Appearance`, `Advanced`, `About` 다섯 섹션으로 나뉩니다. 변경 사항은 `Apply` 없이 자동 반영됩니다.

- `Import From ~/.ssh/config`: 로컬 `~/.ssh/config`에 등록된 alias를 바로 가져와 적용
- `SSH Target`: `gpu-prod` 또는 `user@host`
- `Auth Method`: 기본값은 `Key-based`, 필요하면 `Password-based`
- `Identity File`: 선택 사항, 필요하면 `~/.ssh/id_ed25519`
- `SSH Password`: `Password-based`일 때만 사용
- `Refresh Interval`: polling 간격(초), `1...300` 범위에서 직접 입력 또는 stepper로 조정
- `Notifications`: macOS 알림 권한 상태 확인, 권한 요청, 테스트 알림 전송, 현재 `프로세스 종료` / `GPU idle` watch 목록 관리, 최근 24시간 notification 설정 내역 확인
- `Idle Duration` / `Memory Threshold`: GPU idle 알림 기준, 각각 `1...3600s`, `0...10240MB` 범위에서 직접 입력 또는 stepper로 조정
- `Theme`: `System`, `Light`, `Dark` 중 선택
- `Show Dock icon`: Dock과 App Switcher에 앱 아이콘 표시 여부
- `Close popover on outside click`: 팝오버 바깥 영역 클릭 시 자동 닫힘 여부
- `Menu Bar Summary`: 메뉴바에 `평균 사용률`, `busy GPU 수`, 둘 다, 또는 `icon only` 표시
- `Remote Command`: 기본값은 `nvidia-smi` 쿼리, 필요하면 절대 경로로 변경

좌클릭:

- 현재 GPU 상태와 프로세스 정보를 보여주는 팝오버를 엽니다.
- 팝오버 오른쪽 상단의 새로고침 아이콘으로 즉시 polling 가능
- GPU를 펼친 뒤 각 프로세스 오른쪽의 종 아이콘으로 `프로세스 종료 시 알림` 감시를 걸 수 있음
- GPU 이름 왼쪽의 별 아이콘으로 `GPU idle 알림`을 토글할 수 있음
- 감시한 프로세스가 GPU 목록에서 사라져도, 원격 `ps`로 실제 종료 여부를 확인한 뒤 macOS 기본 알림으로 알려줌
- 별표된 GPU는 `util = 0%` 이고 memory가 지정 임계치 이하인 상태가 일정 시간 이상 유지되면 macOS 기본 알림으로 알려줌

우클릭:

- `Settings…`
- `Quit GPUUsage`

## Notes

- 이 앱은 macOS의 기존 SSH 키와 `~/.ssh/config`를 그대로 사용합니다.
- 기본 `Key-based` 모드에서는 background polling 중 Keychain을 읽지 않습니다.
- 비밀번호 인증을 쓰는 경우 비밀번호는 `UserDefaults`가 아니라 macOS Keychain에 저장합니다.
- 프로세스 종료 알림을 처음 사용할 때 macOS 알림 권한을 요청할 수 있습니다.
- GPU idle 알림도 같은 macOS 알림 권한을 사용합니다.
- 프로세스 종료 알림은 번들 앱(`GPUUsage.app`)으로 실행할 때만 동작합니다. `swift run` 개발 실행에서는 비활성화됩니다.
- 테스트용 앱은 `GPUUsage-<version>-test-<commit>.app` 형식으로 생성됩니다.
- 서버에서 non-interactive shell의 PATH가 다르면 `Remote Command`에 `/usr/bin/nvidia-smi ...` 같은 전체 경로를 넣으세요.

## Package For Distribution

```bash
./scripts/package_app.sh
```

기본 실행 결과:

- `dist/GPUUsage.app`
- `dist/GPUUsage-0.2.4.dmg`
- 저장소 루트에 `icon.png`가 있으면 자동으로 `.icns`로 변환되어 앱 아이콘으로 포함
- `SKIP_DMG=1`을 주면 `.app`만 만들고 DMG는 생략
- `BUILD_CONFIGURATION=debug`를 주면 debug 빌드 기반 `.app` 생성

옵션 환경 변수:

- `VERSION=0.2.4`
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
- 아이콘은 정사각형 PNG를 권장하며, 가장 좋은 품질은 `1024x1024` 이상입니다.

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

4. 스크립트가 끝난 뒤 `dist/GPUUsage-0.2.4.dmg`를 배포합니다.

## GitHub Releases

이 저장소에는 tag 기반 릴리즈 워크플로가 포함됩니다.

1. `master`에 릴리즈할 변경을 반영합니다.
2. `swift test`를 확인합니다.
3. `CHANGELOG.md`를 짧게 업데이트합니다.
4. `v0.2.4` 같은 tag를 생성하고 push합니다.

```bash
git tag v0.2.4
git push origin v0.2.4
```

5. GitHub Actions가 macOS runner에서 DMG를 빌드하고 해당 tag의 GitHub Release에 업로드합니다.

릴리즈 본문은 `CHANGELOG.md`의 해당 버전 섹션을 그대로 사용합니다. 따라서 tag를 만들기 전에 `## 0.x.y - YYYY-MM-DD` 형식의 항목을 먼저 추가해야 합니다.

기본 workflow는 ad-hoc 서명의 DMG를 올립니다. Gatekeeper 경고 없이 배포하려면 이후에 Apple Developer 인증서와 notarization secret을 CI에 추가해야 합니다.

## Homebrew Tap Sync

GitHub Release를 만들 때 `homebrew-tap` 저장소의 cask도 자동으로 갱신할 수 있습니다.

- `GPUUsage` 저장소 secrets에 `HOMEBREW_TAP_TOKEN` 추가
- 권장: fine-grained PAT, 대상 저장소는 `jaein4722/homebrew-tap`
- 필요 권한: `Contents: write`

설정되면 release workflow가 DMG URL을 포함한 `repository_dispatch`를 `homebrew-tap`으로 보내고, tap 저장소가 새 SHA256을 계산해 `Casks/gpuusage.rb`를 자동 commit/push합니다.
