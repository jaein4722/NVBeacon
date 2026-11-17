# Development Guide

Branching, commits and the pull request format are in [AGENTS.md](../AGENTS.md). Maintainers handle releases, signing and distribution.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/NVBeacon`, `Tests` | macOS menu bar app (SwiftPM) |
| `Mobile/NVBeacon` | iPhone and iPad app (`Mobile/NVBeacon.xcodeproj`) |
| `Mobile/NVBeaconMobile` | iOS client package: store, Keychain and SSH transport. It also builds on macOS, so its tests run without a simulator |
| `Windows` | Windows tray app: its own Swift package, with the UI as HTML pages in WebView2 |
| `Shared/NVBeaconCore` | Models, parsers, remote commands, the server backup format and the metrics collector. No dependencies, and no process, Keychain or UI code: every client uses it, and each runs commands through its own `RemoteCommandExecuting` |
| `Shared/NVBeaconTransfer` | Mac → iPhone server transfer |
| `site` | Landing page, deployed when `master` changes |

Settings tabs, labels and wording follow [SETTINGS.md](SETTINGS.md).

## Requirements

- Mac app: macOS 14 or later with Xcode 26 (Swift 6.2) or later
- iOS app: an Xcode with the iOS SDK 27.1 or later
- Windows app: Windows 10 or 11 with Swift 6.2 and the Visual Studio 2022 Build Tools; see [Windows/README.md](../Windows/README.md)
- SSH access to a machine with `nvidia-smi`

## Tests

```bash
swift test --build-system native
swift test --package-path Shared/NVBeaconCore --build-system native
swift test --package-path Shared/NVBeaconTransfer --build-system native
swift test --package-path Mobile/NVBeaconMobile --build-system native
swift test --package-path Windows    # on Windows
```

Pull requests run the first three on macOS, the shared core on Linux as well, and the Windows client on Windows. A change to `Shared/NVBeaconCore` affects all three clients. `./scripts/test_ios_ssh_keys.sh` runs the iOS transport against a local OpenSSH server with every supported key type.

## Mac app

`swift run` is enough for quick checks. Notifications, update checks and launch at login only work from an app bundle:

```bash
OPEN_APP=1 ./scripts/build_test_app.sh
```

This builds `dist/NVBeacon-<version>-test-<commit>.app`, removes earlier test apps and opens the new one.

`./scripts/package_app.sh` builds `dist/NVBeacon.app` and `dist/NVBeacon-<version>.dmg`, ad-hoc signed. `SKIP_DMG=1` skips the DMG. The other options are the variables at the top of the script.

## iOS app

Open `Mobile/NVBeacon.xcodeproj` and run the **NVBeacon** scheme, or build from the command line:

```bash
./scripts/build_ios.sh               # simulator
SDK=iphoneos ./scripts/build_ios.sh  # device, compile only, unsigned
```

- `./scripts/stage_ios_backup.sh <backup.json>` copies a server backup into the app's Documents folder on a running simulator.
- Citadel and swift-nio-ssh are pinned to forks in `Mobile/NVBeaconMobile/Package.swift`.
- After changing iOS dependencies, run `python3 scripts/generate_ios_notices.py` to update the bundled license notices.

## Windows app

Build, run and packaging steps are in [Windows/README.md](../Windows/README.md). The package builds only on Windows.
