# Changelog

## 0.3.5 - 2026-04-08

- Added an optional launch-at-login setting using the standard macOS login item mechanism.
- Added automatic polling recovery after system wake and made manual refresh restart polling when needed.
- Added a lightweight GitHub Pages landing site for product and SEO visibility.

## 0.3.4 - 2026-04-01

- Rebranded the app from GPUUsage to NVBeacon across the app UI, packaging output, release metadata, and repository URLs.
- Renamed the GitHub repository to `jaein4722/NVBeacon` and updated Sparkle/appcast references to the new repository path.
- Renamed the Homebrew cask integration from `gpuusage` to `nvbeacon` so future release automation and installation paths match the new product name.

## 0.3.3 - 2026-04-01

- Reworked password-based SSH authentication to avoid repeated Keychain prompts during background polling.
- Added a session-based unlock flow so password-based mode reads Keychain only when the user explicitly saves or unlocks the stored password.
- Added a one-time security warning before enabling password-based authentication, with a do-not-show-again option.

## 0.3.2 - 2026-04-01

- Added Sparkle-based in-app update support with standard macOS update behavior.
- Added secure Sparkle signing flow using `SUPublicEDKey`, signed release assets, and an auto-published `appcast` branch in GitHub Actions.
- Moved automatic update preferences into `General` settings and simplified the About screen to keep manual update checks in one natural place.

## 0.3.1 - 2026-04-01

- Added configurable busy GPU detection with support for active process, memory threshold, process-or-memory, and utilization threshold modes.
- Changed the default busy GPU rule to count GPUs with active compute processes as busy even when utilization temporarily drops to `0%`.
- Added busy detection controls to Settings and updated busy counts across the menu bar, popover, and About view.

## 0.3.0 - 2026-04-01

- Added process exit notifications with per-process watch controls, notification history, and permission management.
- Added GPU idle notifications with configurable idle duration and memory threshold settings.
- Reworked Settings with native tabbed sections for connection, notifications, appearance, advanced options, and about information.
- Added `~/.ssh/config` host import and backfilling for target, port, and identity values.
- Added English / Korean language selection, improved About information, and refreshed user-facing documentation and screenshots.
- Added local test app build helpers, refreshed app branding, and improved release/readme packaging details.

## 0.2.4 - 2026-03-31

- Added a Dock icon toggle in Appearance settings for users who want NVBeacon visible in the Dock and App Switcher.
- Fixed popover theme application so the main GPU panel follows the selected light, dark, or system appearance.
- Backfilled `~/.ssh/config` identity and port values into Settings when a saved host alias is selected or reloaded.
- Tightened Settings control spacing and made idle GPU rows visually more subdued without overpowering active rows.

## 0.2.3-1 - 2026-03-31

- Fixed the GitHub release workflow so Homebrew tap sync can use the configured secret without invalid workflow conditions.
- Verified automated DMG release publishing and Homebrew tap updates end-to-end.
