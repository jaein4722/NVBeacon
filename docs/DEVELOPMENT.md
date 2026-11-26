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
| `Shared/Localization` | Interface strings for every client, one JSON file per language |
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

## Translations

Every client reads its interface text from `Shared/Localization`: `en.json` lists every key, and each other file (`ko.json`, `zh-Hans.json`) translates some of them. A missing key shows the English text.

```json
{
  "name": "한국어",
  "strings": {
    "Settings": "설정",
    "%@ finished": "%@ 종료",
    "measurement::Unavailable": "측정 불가"
  }
}
```

- The key is the English text. Where one English text has two meanings, the key starts with a context, `context::English`; only the part after the last `::` is shown in English.
- `ios::` keys hold iPhone and iPad text that differs from the desktop text with the same English.
- `%@` (or `%lld` for an integer, as iOS uses) stands for a value. Use `%1$@`, `%2$@` to put values in another order, and `%%` for a percent sign in a text that has values. A text without values is shown as written.
- The macOS app looks texts up with `language.text("Key", value)` or a view's `t("Key", value)`; the Windows pages with `t("Key", value)`, and the Windows app with `InterfaceLanguage.text`. Add a new text to `en.json` and to the translations you can write.
- The app packages ship the files: `scripts/package_app.sh` copies them into `NVBeacon.app/Contents/Resources/Localization`, and `Windows/scripts/package.ps1` next to `NVBeacon.exe`. Development builds read them from the source tree.

To add a language, copy `en.json` to `<code>.json`, using the language code iOS and macOS use (`ja`, `de`, `pt-BR`, `zh-Hant`), set `name` to the language's own name, and translate the texts; untranslated keys can be left out. The macOS and Windows language settings list every file. For iOS, also add the code to `knownRegions` in `Mobile/NVBeacon.xcodeproj/project.pbxproj` and to the language picker in `Mobile/NVBeacon/RootView.swift`.

```bash
python3 scripts/translations.py check   # unknown keys, placeholders that differ, unused texts
python3 scripts/translations.py ios     # regenerate Mobile/NVBeacon/<code>.lproj/Localizable.strings
```

iOS looks texts up by their English through Xcode string files, so run the second command after any change to the shared files and commit the result; pull requests check both.

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
