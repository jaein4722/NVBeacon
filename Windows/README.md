# NVBeacon for Windows (work in progress)

An early Windows client. It reuses `Shared/NVBeaconCore` unchanged and collects
metrics through the Windows OpenSSH client (`ssh.exe`).

## Requirements

- Windows 10 or 11 with the OpenSSH client (`C:\Windows\System32\OpenSSH\ssh.exe`)
  and the Microsoft Edge WebView2 Runtime (included with Windows 11)
- Swift 6.2 for Windows, with Visual Studio 2022 Build Tools (MSVC x64 and a Windows 11 SDK)

## Build and test

Before the first build, fetch the WebView2 SDK (headers and loader, kept out of git):

```powershell
cd Windows
.\scripts\fetch-webview2.ps1
swift build
swift test
```

## Run

```powershell
# Tray app
.build\debug\NVBeacon.exe

# Console output, for checking collection from a terminal
.build\debug\nvbeacon-cli.exe --once
```

- **Left-click** the tray icon for the popover-style flyout (an HTML page in
  WebView2, `Sources/NVBeacon/UI`). **Right-click** for Settings… and Quit.
- **Settings** mirror the macOS app's tabs (General, Notifications, Appearance,
  Advanced, About) and save to `%APPDATA%\NVBeacon\settings.json` as you edit.
  Saved hosts are read from `%USERPROFILE%\.ssh\config`. Server backups use the
  same file format as the macOS app.
- Both executables take `[--interval SECONDS] [--demo] [TARGET ...]`; the CLI also
  takes `--once`. Targets or `--demo` (two sample servers with made-up data)
  replace the saved servers for that session only.
- WebView2 is created when a window first opens and released 60 seconds after the
  flyout closes (`--release-after SECONDS`). `--diag` writes timings to
  `%LOCALAPPDATA%\NVBeacon\diag.log`.

Current limits:

- Key or ssh-agent authentication only. Connect once with `ssh` from a terminal
  first so the host key is in `known_hosts`.
- No connection reuse: Win32-OpenSSH does not support `ControlMaster`.
- Not yet available: notifications, GPU history, highlighting your own
  processes, automatic updates, and an installer.
