# Development Guide

This document is for contributors. Maintainers handle releases, signing, and distribution.

## GitHub Flow

NVBeacon follows GitHub Flow. `master` is the release-ready default branch.

1. Update a clean local `master` with `git pull --ff-only origin master`.
2. Create a short-lived branch for the change: `feat/<topic>`, `fix/<topic>`,
   `chore/<topic>`, or `docs/<topic>`.
3. Commit focused changes. After explicit approval, push the branch and open a pull
   request targeting `master`, following the format in [AGENTS.md](../AGENTS.md).
   Link the related issue when there is one.
4. Run the relevant tests and complete review before merging the pull request.
   Squash intermediate commits when practical.
5. Delete the merged branch when it is no longer needed.

Urgent fixes follow the same process on a `fix/<topic>` branch. Do not introduce
long-lived `develop`, `release/*`, or `hotfix/*` branches.

Keep unrelated work separate. If the current worktree contains in-progress
changes, preserve it, fetch `origin/master`, and create a separate branch and
worktree from that ref. Do not switch or pull over uncommitted work to start an
unrelated change.

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

Test the platform-independent package without the macOS app or Sparkle:

```bash
swift test --package-path Shared/NVBeaconCore --build-system native
```

The `Tests` workflow runs this package on Linux and runs macOS app/process tests
with Xcode 26, without signing secrets. SSH execution tests cover large concurrent
stdout/stderr, cancellation, forced termination, timeout cleanup, inherited pipes,
already-cancelled tasks and output limits. Platform transports own process/network
resources; see [NVBeaconCore](../Shared/NVBeaconCore/README.md) for the shared API.

An optional local SSH smoke check reads at most two enabled, key-authenticated
servers from the installed macOS app's settings. It is disabled in normal tests
and CI, does not read passwords or change configuration, and logs counts only:

```bash
NVBEACON_LIVE_SSH_SMOKE=1 swift test --build-system native --filter liveSSHCollectionWithTheSharedCore
```

### Host Metrics Overhead Benchmark

Run a manual, read-only comparison against enabled, key-authenticated servers in
an existing app settings domain:

```bash
bash scripts/benchmark_host_metrics.sh \
  --settings-domain com.leejaein.NVBeacon \
  --samples 12 --max-servers 2 --parse-iterations 300 \
  --output dist/benchmarks/host-metrics-overhead.json
```

Use the test app's bundle identifier as the settings domain to measure its
configured servers instead. The benchmark does not change settings, read
passwords from Keychain, install remote software, or run in normal tests/CI.
It performs additional monitoring queries, so run it when that temporary load
is acceptable.

The helper compiles the current core collector and macOS process runner with
optimization. After warm-up, it alternates GPU-only and all-host SSH polls and
records wall time, local process CPU time, and script/response sizes. Replaying
the captured responses in memory separates collection/parsing cost from SSH.
If Python 3 is already available remotely, a standard-library helper also
measures generated command wall/child CPU time and isolated CPU, memory, and
network probes in shuffled order. An empty-shell control estimates shell
startup overhead. Python helper CPU is excluded from child CPU measurements.

Only numerical results with anonymous server indices are saved under the
ignored `dist/` directory. Endpoints, usernames, identity paths, custom commands,
and raw process/GPU responses are not saved. Payload sizes exclude SSH framing
and encryption. Normal app polling and remote workloads remain running;
end-to-end differences can include workload/network noise. This benchmark
does not measure GUI rendering, persistent app memory, or the separate SSH
master process's CPU usage.

## Test App Workflow

Some features, especially Notification Center behavior, should be tested from an actual `.app` bundle instead of `swift run`.

Packaged builds use SwiftPM's `native` build system for both the executable and its output path. With Xcode 27.2, the default `swiftbuild` backend was observed to record SDK 14.0 in the executable despite compiling with the current SDK, causing settings to use legacy AppKit/SwiftUI styling. The native backend records the actual SDK version while preserving the macOS 14.0 minimum deployment target. `SWIFTPM_BUILD_SYSTEM` can override this backend after verifying the resulting app's SDK metadata and appearance.

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

Release DMGs are generated as styled installer images with a custom background and
Applications shortcut using `dmgbuild`.

Useful examples:

```bash
SKIP_DMG=1 ./scripts/package_app.sh
BUILD_CONFIGURATION=debug ./scripts/package_app.sh
VERSION=0.8.0 BUILD_NUMBER=1 ./scripts/package_app.sh
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
- `APP_STORE_CONNECT_API_KEY_PATH`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`

If `icon.png` exists at the repository root, the packaging script automatically converts it into an `.icns` asset and embeds it in the app bundle.

Local builds are ad-hoc signed by default, which is fine for personal testing. Official
releases are built by the maintainer's tag-triggered release workflow.

## Landing Page

The project landing page lives in `site/` and deploys through
`.github/workflows/pages.yml`.

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

## Project Notes

- SSH keys and `~/.ssh/config` are used directly from the local Mac.
- In key-based mode, background polling does not read from Keychain.
- In password-based mode, the password is stored in macOS Keychain and unlocked into memory once per app session to avoid repeated Keychain prompts during polling.
- The app shows a one-time warning before users switch into password-based mode because it is less secure than SSH key authentication.
- If the remote shell has a limited `PATH`, set `Remote Command` to an absolute path.
