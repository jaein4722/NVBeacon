# Changelog

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

- Added a Dock icon toggle in Appearance settings for users who want GPUUsage visible in the Dock and App Switcher.
- Fixed popover theme application so the main GPU panel follows the selected light, dark, or system appearance.
- Backfilled `~/.ssh/config` identity and port values into Settings when a saved host alias is selected or reloaded.
- Tightened Settings control spacing and made idle GPU rows visually more subdued without overpowering active rows.

## 0.2.3-1 - 2026-03-31

- Fixed the GitHub release workflow so Homebrew tap sync can use the configured secret without invalid workflow conditions.
- Verified automated DMG release publishing and Homebrew tap updates end-to-end.
