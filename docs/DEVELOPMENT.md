# Development Guide

This document is for contributors and maintainers of NVBeacon.

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
NVBeacon-<version>-test-<commit>.app
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

Bundle-only behaviors include:

- Notification Center permission and delivery
- Sparkle update checks
- Launch at login registration

## Packaging

The canonical packaging entrypoint is:

```bash
./scripts/package_app.sh
```

By default this produces:

- `dist/NVBeacon.app`
- `dist/NVBeacon-<version>.dmg`

Useful examples:

```bash
SKIP_DMG=1 ./scripts/package_app.sh
BUILD_CONFIGURATION=debug ./scripts/package_app.sh
VERSION=0.4.0 BUILD_NUMBER=1 ./scripts/package_app.sh
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
xcrun notarytool store-credentials "NVBeaconNotary"

CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
KEYCHAIN_PROFILE="NVBeaconNotary" \
./scripts/package_app.sh
```

## Release Flow

NVBeacon uses tag-based GitHub Releases.

Typical release sequence:

1. commit the final release candidate to `master`
2. run `swift test`
3. update `CHANGELOG.md`
4. create and push a version tag

Example:

```bash
git tag v0.4.0
git push origin v0.4.0
```

The release workflow:

- builds the DMG on a macOS runner
- imports the Developer ID certificate with `apple-actions/import-codesign-certs`
- notarizes the app bundle and DMG with `notarytool`
- publishes the GitHub Release
- sets an SEO-friendly release title for remote NVIDIA GPU monitoring on macOS
- prepends a keyword-rich product summary before the version-specific notes
- uses the matching `CHANGELOG.md` section as the version-specific release notes
- generates a Sparkle `appcast.xml`
- publishes the latest appcast to the `appcast` branch
- syncs the Homebrew cask repository

## GitHub Pages

The repository also includes a lightweight marketing/SEO landing page under `site/`.

- source files live in `site/`
- deployment workflow lives in `.github/workflows/pages.yml`
- Pages should be configured to deploy from GitHub Actions
- published URL:

```text
https://jaein4722.github.io/NVBeacon/
```

Release page wording should stay aligned with the repository positioning:

- title format: `NVBeacon X.Y.Z: macOS menu bar app for remote NVIDIA GPU monitoring over SSH`
- opening summary: mention `macOS`, `remote NVIDIA GPU`, `SSH`, `nvidia-smi`, and alerting features when relevant

## App Updates

NVBeacon uses [Sparkle](https://sparkle-project.org/) for in-app update checks.

- App-side integration lives in `Sources/NVBeacon/AppUpdater.swift`
- The packaged app bundle includes `Sparkle.framework`
- The app reads its feed URL from `SUFeedURL` in `Info.plist`
- GitHub Actions publishes the latest appcast to the `appcast` branch at:

```text
https://raw.githubusercontent.com/jaein4722/NVBeacon/appcast/appcast.xml
```

Notes:

- Update installation is most reliable when release builds are Developer ID signed and notarized.
- The package script embeds `SUPublicEDKey` in the app bundle, and the release workflow signs update archives and the generated appcast feed with Sparkle's EdDSA tools.

### Sparkle Signing Keys

Sparkle uses an EdDSA key pair for signing update archives and appcast feeds.

Generate or inspect your keys with Sparkle's tools:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

For CI-friendly signing, export the private key from your login keychain:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

Repository secrets expected by the release workflow:

- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

The release workflow now fails if these secrets are missing, because NVBeacon treats unsigned update feeds as not ready for production use.

### CI Developer ID Certificate

GitHub Actions uses the standard Apple-maintained `apple-actions/import-codesign-certs`
action to import a `.p12` certificate bundle from repository secrets, then resolves the
`Developer ID Application` identity from the runner keychain search list.

Recommended flow:

1. Export the `Developer ID Application` certificate and private key from Keychain Access as a `.p12` file.
2. Protect the export with a strong temporary password.
3. Base64-encode the file and store it in `DEVELOPER_ID_P12_BASE64`.
4. Store the export password in `DEVELOPER_ID_P12_PASSWORD`.

Example:

```bash
base64 < developer-id-application.p12 | pbcopy
```

The notarization secrets should match the credentials you can use locally with:

```bash
xcrun notarytool store-credentials "NVBeaconNotary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

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
- In password-based mode, the password is stored in macOS Keychain and unlocked into memory once per app session to avoid repeated Keychain prompts during polling.
- The app shows a one-time warning before users switch into password-based mode because it is less secure than SSH key authentication.
- If the remote shell has a limited `PATH`, set `Remote Command` to an absolute path.
