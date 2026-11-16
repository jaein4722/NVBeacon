# NVBeacon for Windows (work in progress)

An early Windows client. It reuses `Shared/NVBeaconCore` unchanged and collects
metrics through the Windows OpenSSH client (`ssh.exe`).

## Requirements

- Windows 10 or 11 with the OpenSSH client (`C:\Windows\System32\OpenSSH\ssh.exe`)
- Swift 6.2 for Windows, with Visual Studio 2022 Build Tools (MSVC x64 and a Windows 11 SDK)

## Build and test

```powershell
cd Windows
swift build
swift test
```

## Run

```powershell
# Tray app: per-GPU utilization bars in the notification area, details in its menu
.build\debug\NVBeacon.exe gpu-box alice@gpu.example.com

# Console output, for checking collection from a terminal
.build\debug\nvbeacon-cli.exe --once gpu-box
```

Before the first build, fetch the WebView2 SDK (headers and loader, kept out of git):

```powershell
.\scripts\fetch-webview2.ps1
```

Left-clicking the tray icon opens a flyout whose content is an HTML page in
Microsoft Edge WebView2 (`Sources/NVBeacon/UI`); right-clicking opens the native menu.
WebView2 is created when the flyout first opens and released 60 seconds after it
closes (`--release-after SECONDS`). `--diag` writes timings to
`%LOCALAPPDATA%\NVBeacon\diag.log`.

Both take `[--interval SECONDS] [--demo] [TARGET ...]`; the CLI also takes `--once`.
`--demo` adds two sample servers with made-up data, for trying the UI without a GPU server. Without
targets they read `%APPDATA%\NVBeacon\servers.txt`, one SSH target per line.

Current limits:

- Key or ssh-agent authentication only. Connect once with `ssh` from a terminal
  first so the host key is in `known_hosts`.
- No connection reuse: Win32-OpenSSH does not support `ControlMaster`.
- No settings window, notifications, history, or installer yet.
