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
- **Settings** mirror the macOS app's tabs (General, Servers, Monitoring,
  Notifications, Display, Advanced, About) and save to `%APPDATA%\NVBeacon\settings.json` as you edit.
  Saved hosts are read from `%USERPROFILE%\.ssh\config`. Server backups use the
  same file format as the macOS app.
- Both executables take `[--interval SECONDS] [--demo] [TARGET ...]`; the CLI also
  takes `--once`. Targets or `--demo` (two sample servers with made-up data)
  replace the saved servers for that session only.
- WebView2 is created when a window first opens and released 60 seconds after the
  flyout closes (`--release-after SECONDS`). `--diag` writes timings to
  `%LOCALAPPDATA%\NVBeacon\diag.log`.

SSH:

- Uses the system `ssh.exe`, so `~/.ssh/config`, keys, ssh-agent and
  `known_hosts` work as in a terminal. Connect once with `ssh` first so the host
  key is in `known_hosts`.
- Connection reuse (the default, per server): Win32-OpenSSH has no working
  `ControlMaster`, so NVBeacon keeps one `ssh.exe` per server running a remote
  `/bin/sh -s` and sends each command framed with random markers. Commands run
  through the login shell exactly as a fresh connection would run them. GPU
  History, process details and exit checks use a second connection so they never
  wait for a poll. A dropped connection is reopened by the next command.
  "New connection every refresh" starts `ssh.exe` for every command instead.
- Password authentication: the password is kept in Windows Credential Manager.
  ssh runs NVBeacon.exe as its `SSH_ASKPASS` program, which answers only the
  server's password prompt (not host-key questions, passphrases or one-time
  codes), once per connection. If the server rejects the password, polling of
  that server stops until the password is saved again or its login changes.
  This needs OpenSSH 8.4 or later (`SSH_ASKPASS_REQUIRE`), as in Windows 11; the
  OpenSSH 8.1 built into Windows 10 cannot do it, and NVBeacon says so instead of
  connecting. Use key authentication there.

Packaging: `scripts\package.ps1 -Version 1.2.3` (or a pre-release such as
`1.2.3-beta.1`) builds a release folder and zip in `dist\` that runs without the Swift toolchain (Swift and C++ runtime DLLs, the
WebView2 loader, the UI files and license notices). The icon and version
information are compiled into the executables from `packaging\NVBeacon.rc.in`.
`packaging\THIRD-PARTY-NOTICES.txt` holds the full license texts of the bundled
libraries, read from their upstream sources at the toolchain's tag by
`scripts\generate-notices.ps1`; packaging stops if it is stale (for example after a
toolchain update), and Settings › About opens it.

Installer: add `-Installer` to also build `dist\NVBeacon-1.2.3-windows-x64-setup.exe`
from `packaging\NVBeacon.iss` with Inno Setup 6 (`winget install JRSoftware.InnoSetup`).
It installs for the current user under `%LOCALAPPDATA%\Programs\NVBeacon` without an
administrator prompt, adds a Start menu entry and an entry in Installed apps, and
upgrades an existing install in place. The first install can also turn on Launch at
Login (off by default); upgrades leave that setting to the app. Before copying files it asks a running
NVBeacon to quit, so GPU History is saved. Uninstalling removes Launch at Login when it
points to that copy and asks whether to also delete NVBeacon's data: settings and
records (`%APPDATA%\NVBeacon`, `%LOCALAPPDATA%\NVBeacon`) and saved SSH passwords. The
default answer is No, and a silent uninstall keeps the data. The
installer is not code-signed, so SmartScreen warns on first run.

Current limits: no automatic updates yet.
