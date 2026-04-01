<a id="readme-top"></a>

<div align="center">
  <img src="icon.png" alt="GPUUsage Logo" width="128" height="128">
  <h1>GPUUsage</h1>
  <p>A native macOS menu bar app for monitoring remote NVIDIA GPU servers over SSH.</p>
  <p>
    <img src="https://img.shields.io/github/v/release/jaein4722/GPUUsage?style=flat-square" alt="GitHub Release">
    <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2">
    <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="MIT License">
  </p>
  <p>
    <a href="https://github.com/jaein4722/GPUUsage/releases">Download Latest Release</a>
    ·
    <a href="https://github.com/jaein4722/GPUUsage/issues">Report Bug</a>
    ·
    <a href="https://github.com/jaein4722/GPUUsage/issues">Request Feature</a>
  </p>
</div>

## About

GPUUsage gives you a fast view of a remote GPU box without keeping a terminal open.

It connects over `ssh`, runs `nvidia-smi` on the target server, and turns the result into a compact menu bar summary plus a detailed popover UI. It is built for people who regularly ask:

- Is the server busy right now?
- Which GPU is being used?
- Which process is running on that GPU?
- Did my job finish?
- Has a watched GPU stayed idle long enough to reuse?

## Screenshots

<div align="center">
  <img src="assets/menu-bar-summary.png" alt="GPUUsage menu bar summary" width="320">
</div>

<p align="center"><em>At-a-glance menu bar summary</em></p>

<div align="center">
  <img src="assets/popover-overview.png" alt="GPUUsage popover UI" width="620">
</div>

<p align="center"><em>Detailed popover with per-GPU status, process details, and notification controls</em></p>

## Features

- Native macOS menu bar UI with compact status text or icon-only mode
- Per-GPU utilization, memory, temperature, and process count
- On-demand process details with user, PID, memory, and command preview
- Process exit notifications through macOS Notification Center
- GPU idle notifications with configurable idle duration and memory threshold
- Configurable busy GPU detection based on active processes, memory usage, or utilization
- Built-in update checks using Sparkle, the standard macOS update framework
- Import from local `~/.ssh/config`
- SSH key authentication and password-based authentication
- English / Korean UI with a `System` language option
- Light / dark / system appearance support
- Optional Dock icon and configurable popover outside-click behavior

## Installation

### Homebrew

```bash
brew install --cask jaein4722/tap/gpuusage
```

### GitHub Releases

Download the latest `.dmg` from the [Releases page](https://github.com/jaein4722/GPUUsage/releases).

### Manual Installation

1. Download the latest `GPUUsage.dmg` from [GitHub Releases](https://github.com/jaein4722/GPUUsage/releases).
2. Open the DMG.
3. Drag `GPUUsage.app` into `Applications`.
4. Launch the app from `Applications`.
5. If macOS blocks the app because it cannot verify the developer, open `System Settings > Privacy & Security` and choose `Open Anyway`.

## Requirements

- macOS 14 or later
- SSH access from your Mac to the target server
- `nvidia-smi` available on the remote host

## Quick Start

1. Launch GPUUsage.
2. Right-click the menu bar item and open `Settings…`.
3. Set `SSH Target` directly or import a saved host from `~/.ssh/config`.
4. Choose your authentication method.
5. Allow notifications if you want process exit or GPU idle alerts.
6. Left-click the menu bar item to open the GPU popover.
7. Open the `About` tab when you want to check for a newer release manually.

All settings apply automatically. There is no separate apply button.

## Notifications

GPUUsage supports two kinds of alerts:

- `Process Exit`: watch a running GPU process and get notified when it really exits
- `GPU Idle`: star a GPU and get notified when it stays idle long enough

You can manage notification permission, active watches, and recent notification history from the `Notifications` tab in Settings.

## Settings Overview

GPUUsage uses a native macOS-style settings window with these sections:

- `General`: server connection, authentication, polling, busy GPU detection
- `General`: server connection, authentication, polling, busy GPU detection, update preferences
- `Notifications`: permission, test notification, active watches, history, idle thresholds
- `Appearance`: theme, language, Dock icon, menu bar summary, popover behavior
- `Advanced`: remote command override
- `About`: version, links, runtime summary, and current configuration

## Language Support

The interface can be set to:

- `System`
- `English`
- `Korean`

`System` follows the current macOS language. Unsupported system languages fall back to English.

## Notes

- GPUUsage uses your local SSH setup directly, including `~/.ssh/config`.
- In key-based mode, background polling does not read from Keychain.
- In password-based mode, the password is stored in macOS Keychain, not `UserDefaults`.
- If the remote non-interactive shell has a limited `PATH`, set `Remote Command` to an absolute path such as `/usr/bin/nvidia-smi`.
- Public DMG downloads may still trigger a Gatekeeper warning unless the release is signed and notarized.
- Short release notes are tracked in [CHANGELOG.md](/Users/leejaein/Documents/SideProjects/GPUUsage/CHANGELOG.md).

## For Developers

Development, packaging, test app, and release workflow notes live in [docs/DEVELOPMENT.md](/Users/leejaein/Documents/SideProjects/GPUUsage/docs/DEVELOPMENT.md).

## License

Distributed under the MIT License. See [LICENSE](/Users/leejaein/Documents/SideProjects/GPUUsage/LICENSE) for details.

## Acknowledgments

- [Best README Template](https://github.com/othneildrew/Best-README-Template) for the structural inspiration

<p align="right">(<a href="#readme-top">back to top</a>)</p>
