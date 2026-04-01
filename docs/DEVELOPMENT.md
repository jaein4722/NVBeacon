# Development Guide

This document is for contributors and maintainers of GPUUsage.

## Prerequisites

- macOS 14 or later
- Xcode 26 or Swift 6.2 or later
- SSH access to a remote machine with `nvidia-smi`

## Build and Test

Standard SwiftPM commands:

```bash
swift build
swift test
```

## Test App Workflow

Some features, especially Notification Center behavior, should be tested from an actual `.app` bundle instead of `swift run`.

Build and open a fresh local test app:

```bash
OPEN_APP=1 ./scripts/build_test_app.sh
```

The script will:

- kill existing test app processes
- remove older test app bundles from `dist/`
- build a fresh app bundle
- open the new app

Generated app format:

```text
GPUUsage-<version>-test-<commit>.app
```

For iterative development, the repository also includes:

```bash
./scripts/dev_build.sh
./scripts/dev_test.sh
```

These helper scripts run the normal SwiftPM workflow and then build a fresh test app bundle.

## Running From Source

```bash
swift run
```

`swift run` is useful for quick iteration, but bundle-only behaviors may differ from the test app path.

## Packaging

The canonical packaging entrypoint is:

```bash
./scripts/package_app.sh
```

By default this produces:

- `dist/GPUUsage.app`
- `dist/GPUUsage-<version>.dmg`

Useful examples:

```bash
SKIP_DMG=1 ./scripts/package_app.sh
BUILD_CONFIGURATION=debug ./scripts/package_app.sh
VERSION=0.3.1 BUILD_NUMBER=1 ./scripts/package_app.sh
```

Supported environment variables:

- `VERSION`
- `BUILD_NUMBER`
- `BUNDLE_ID`
- `SPARKLE_FEED_URL`
- `SPARKLE_PUBLIC_ED_KEY`
- `CODESIGN_IDENTITY`
- `NOTARIZE`
- `KEYCHAIN_PROFILE`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

If `icon.png` exists at the repository root, the packaging script automatically converts it into an `.icns` asset and embeds it in the app bundle.

## Signing and Notarization

Ad-hoc local builds are fine for personal testing. Public distribution without Gatekeeper warnings requires:

1. a `Developer ID Application` certificate
2. notarization

Example:

```bash
xcrun notarytool store-credentials "GPUUsageNotary"

CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
KEYCHAIN_PROFILE="GPUUsageNotary" \
./scripts/package_app.sh
```

## Release Flow

GPUUsage uses tag-based GitHub Releases.

Typical release sequence:

1. commit the final release candidate to `master`
2. run `swift test`
3. update `CHANGELOG.md`
4. create and push a version tag

Example:

```bash
git tag v0.3.1
git push origin v0.3.1
```

The release workflow:

- builds the DMG on a macOS runner
- publishes the GitHub Release
- uses the matching `CHANGELOG.md` section as the release notes
- generates a Sparkle `appcast.xml`
- publishes the latest appcast to the `appcast` branch
- syncs the Homebrew cask repository

## App Updates

GPUUsage uses [Sparkle](https://sparkle-project.org/) for in-app update checks.

- App-side integration lives in `Sources/GPUUsage/AppUpdater.swift`
- The packaged app bundle includes `Sparkle.framework`
- The app reads its feed URL from `SUFeedURL` in `Info.plist`
- GitHub Actions publishes the latest appcast to the `appcast` branch at:

```text
https://raw.githubusercontent.com/jaein4722/GPUUsage/appcast/appcast.xml
```

Notes:

- Update installation is most reliable when release builds are Developer ID signed and notarized.
- `SUPublicEDKey` support is wired through packaging, but secure signed appcasts still need an EdDSA signing key workflow if you want full Sparkle feed signing.

## Homebrew Tap Sync

The repository can update the Homebrew cask automatically after a GitHub Release.

Required repository secret:

- `HOMEBREW_TAP_TOKEN`

Recommended token scope:

- fine-grained PAT
- target repository: `jaein4722/homebrew-tap`
- permission: `Contents: write`

## Project Notes

- SSH keys and `~/.ssh/config` are used directly from the local Mac.
- In key-based mode, background polling does not read from Keychain.
- In password-based mode, the password is stored in macOS Keychain rather than `UserDefaults`.
- If the remote shell has a limited `PATH`, set `Remote Command` to an absolute path.
