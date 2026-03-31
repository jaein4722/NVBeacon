<a id="readme-top"></a>

<div align="center">
  <img src="icon.png" alt="GPUUsage Logo" width="128" height="128">
  <h1>GPUUsage</h1>
  <p>
    A native macOS menu bar app for monitoring remote NVIDIA GPU servers over SSH.
  </p>
  <p>
    <a href="https://github.com/jaein4722/GPUUsage/releases">Latest Release</a>
    ·
    <a href="https://github.com/jaein4722/GPUUsage/issues">Report Bug</a>
    ·
    <a href="https://github.com/jaein4722/GPUUsage/issues">Request Feature</a>
  </p>
</div>

## Table of Contents

- [About The Project](#about-the-project)
- [Features](#features)
- [Built With](#built-with)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Settings Overview](#settings-overview)
- [Development](#development)
- [Packaging](#packaging)
- [Releases](#releases)
- [Roadmap](#roadmap)
- [Acknowledgments](#acknowledgments)

## About The Project

GPUUsage is a lightweight macOS menu bar application for keeping an eye on remote NVIDIA GPU machines without opening a terminal every few minutes.

The app connects over `ssh`, runs `nvidia-smi` on the target server, and turns the result into a compact menu bar summary plus a detailed popover UI. It is designed for personal GPU servers, shared research boxes, and production inference or training hosts where you want a quick visual signal instead of a full dashboard.

Unlike a generic SSH menu bar tool, GPUUsage is built specifically around the operational questions that usually matter:

- How busy is the server right now?
- Which GPUs are active?
- Which process is using a given GPU?
- Did my job finish?
- Has a watched GPU stayed idle long enough to be reusable?

Short release notes are maintained in [CHANGELOG.md](/Users/leejaein/Documents/SideProjects/GPUUsage/CHANGELOG.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Features

- Native macOS menu bar app with a compact GPU summary in the status item.
- Per-GPU popover view with utilization, memory, temperature, and process count.
- On-demand process detail loading so background polling stays lightweight.
- Process exit notifications using macOS Notification Center.
- GPU idle notifications with configurable duration and memory threshold.
- Import server aliases directly from `~/.ssh/config`.
- Support for both SSH key authentication and password-based authentication.
- English / Korean interface selection, including a `System` mode that follows macOS language preferences.
- Appearance controls for `System`, `Light`, and `Dark`.
- Optional Dock icon, optional outside-click popover close behavior, and configurable menu bar summary style.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Built With

- [Swift 6.2](https://www.swift.org/)
- [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [AppKit](https://developer.apple.com/documentation/appkit)
- [UserNotifications](https://developer.apple.com/documentation/usernotifications)
- Remote `ssh`
- Remote `nvidia-smi`

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Getting Started

### Prerequisites

You need the following before GPUUsage can work reliably:

- macOS 14 or later
- Xcode 26 or Swift 6.2 or later if you want to build from source
- SSH access from your Mac to the target server
- `nvidia-smi` available on the remote host

### Installation

#### Option 1: Install via Homebrew

```bash
brew tap jaein4722/tap
brew install --cask gpuusage
```

#### Option 2: Download a release DMG

Download the latest `.dmg` from the [GitHub Releases page](https://github.com/jaein4722/GPUUsage/releases).

#### Option 3: Build from source

```bash
git clone https://github.com/jaein4722/GPUUsage.git
cd GPUUsage
swift build
swift run
```

If you want to test app-bundle-only features such as notifications, build a local test app instead of relying on `swift run`.

```bash
OPEN_APP=1 ./scripts/build_test_app.sh
```

That script kills any previous test app process, removes older test app bundles, builds a fresh `.app`, and opens it for you.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage

### First-Time Setup

1. Launch GPUUsage.
2. Right-click the menu bar item and choose `Settings…`.
3. Configure a server manually or import one from `~/.ssh/config`.
4. Pick the authentication mode.
5. Allow macOS notifications if you plan to use process exit or GPU idle alerts.

All settings apply automatically. There is no separate `Apply` button.

### Day-to-Day Workflow

- Left-click the menu bar item to open the GPU popover.
- Click the refresh icon in the popover header to fetch immediately.
- Expand a GPU row to load current process details.
- Toggle the bell button next to a process to receive a notification when that process exits.
- Toggle the star next to a GPU to receive a notification when that GPU stays idle long enough.
- Right-click the menu bar item for `Settings…` and `Quit GPUUsage`.

### How Polling Works

GPUUsage runs `ssh` locally and polls the remote server at the configured interval.

The summary polling path uses:

- `nvidia-smi --query-gpu=...`
- `nvidia-smi --query-compute-apps=...`

Detailed process command lines are fetched only when you expand a GPU row. This keeps background polling lighter than a full `ps` scan on every refresh.

For GPU idle alerts, the app records when a watched GPU first enters an idle state and only sends a notification once the configured idle duration has been continuously satisfied. If the GPU becomes active again, that timer resets.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Settings Overview

GPUUsage uses a native macOS-style settings window with five sections:

### General

- Import saved hosts from `~/.ssh/config`
- Set `SSH Target`, authentication mode, identity file, password, and SSH port
- Configure the polling interval

### Notifications

- Request or re-check Notification Center permission
- Send a test notification
- Review active process exit watches
- Review active GPU idle watches
- Inspect notification history for the last 24 hours
- Adjust idle alert duration and memory threshold

### Appearance

- Choose `System`, `Light`, or `Dark`
- Choose `System`, `English`, or `Korean`
- Control menu bar summary style
- Show or hide the Dock icon
- Toggle automatic popover close on outside click

### Advanced

- Override the remote `nvidia-smi` command

### About

- View app version and environment details

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Development

### Build and Test

```bash
swift build
swift test
```

For iterative local development, these helper scripts also build a fresh test app bundle:

```bash
./scripts/dev_build.sh
./scripts/dev_test.sh
```

`swift build` and `swift test` themselves cannot run a post-build hook through SwiftPM, so the repository provides these development scripts as the equivalent workflow.

### Bundle-Based Testing

Notification features are intentionally tested through a generated app bundle:

```bash
OPEN_APP=1 ./scripts/build_test_app.sh
```

The generated app name follows this format:

```text
GPUUsage-<version>-test-<commit>.app
```

### Notes

- SSH keys and `~/.ssh/config` integration are used directly from the local Mac.
- In key-based mode, background polling does not read from Keychain.
- In password-based mode, passwords are stored in macOS Keychain rather than `UserDefaults`.
- If the remote non-interactive shell has a limited `PATH`, set `Remote Command` to an absolute path such as `/usr/bin/nvidia-smi`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Packaging

The canonical packaging entrypoint is:

```bash
./scripts/package_app.sh
```

By default this produces:

- `dist/GPUUsage.app`
- `dist/GPUUsage-<version>.dmg`

Useful packaging options:

```bash
SKIP_DMG=1 ./scripts/package_app.sh
BUILD_CONFIGURATION=debug ./scripts/package_app.sh
VERSION=0.3.0 BUILD_NUMBER=1 ./scripts/package_app.sh
```

Supported environment variables include:

- `VERSION`
- `BUILD_NUMBER`
- `BUNDLE_ID`
- `CODESIGN_IDENTITY`
- `NOTARIZE`
- `KEYCHAIN_PROFILE`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

If `icon.png` exists at the repository root, the packaging script automatically converts it into an `.icns` asset and embeds it in the app bundle.

### Public Distribution

Ad-hoc local builds are fine for personal use, but public distribution without Gatekeeper warnings requires:

1. A `Developer ID Application` certificate
2. Notarization

Example:

```bash
xcrun notarytool store-credentials "GPUUsageNotary"

CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 \
KEYCHAIN_PROFILE="GPUUsageNotary" \
./scripts/package_app.sh
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Releases

GPUUsage uses tag-based GitHub Releases.

Release flow:

1. Commit the final release candidate to `master`
2. Run `swift test`
3. Update [CHANGELOG.md](/Users/leejaein/Documents/SideProjects/GPUUsage/CHANGELOG.md)
4. Create and push a tag such as `v0.3.0`

```bash
git tag v0.3.0
git push origin v0.3.0
```

The GitHub Actions release workflow then:

- builds the DMG on a macOS runner
- publishes the GitHub Release
- uses the matching `CHANGELOG.md` section as the release notes
- syncs the Homebrew cask repository

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Roadmap

- More alert types beyond process exit and GPU idle
- Multi-server profile improvements
- Better public distribution through signed and notarized CI artifacts

See the [open issues](https://github.com/jaein4722/GPUUsage/issues) for proposed improvements and bug reports.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Acknowledgments

- [Best README Template](https://github.com/othneildrew/Best-README-Template) for the structural inspiration
- Apple documentation for SwiftUI, AppKit, and UserNotifications

<p align="right">(<a href="#readme-top">back to top</a>)</p>
