# Changelog

## 0.8.0 - 2026-11-10

- Added an opt-in GPU History window with up to 24 hours of per-user GPU utilization. Turn on **Record GPU history** in Settings, then open the chart from the menu bar popover to view activity by server and GPU.
- Fixed GPU and host metrics collection on servers that use fish as their login shell.
- Thanks @Moviw for contributing GPU history and the fish compatibility fix in [#5](https://github.com/jaein4722/NVBeacon/pull/5) and [#11](https://github.com/jaein4722/NVBeacon/pull/11).

## 0.7.0 - 2026-11-05

- Added per-server network usage: download and upload rates plus total transferred bytes, shown in the popover and in the menu bar tooltip.
- Read network interface counters (`/sys/class/net`, falling back to `/proc/net/dev`) inside the existing polling SSH call, skipping loopback, container, and overlay interfaces as well as bond/bridge slaves.
- Grouped CPU, RAM/Swap, and network metrics in one host information section, expanded by default, with a saved expand/collapse state per server.
- Added collapsible server cards, expanded by default, with saved states independent of each server's host information section. Collapsing either section keeps polling and alerts running.
- Unified GPU and host query editors as matching single-line fields, preserving multiline script behavior through an executable single-line representation.
- Replaced the per-server memory-only command editor with a complete host information script for CPU, RAM/Swap, and network collection; preserved existing custom memory queries through migration. Server backup v2 preserves host scripts and still imports v1 backups.
- Added host information collection controls in General settings: turn all collection off or select CPU, memory, and network individually. Individual switches are hidden while collection is off, with their choices retained. The default host script skips disabled probes.
- Hid unconfigured swap and moved available RAM into the RAM bar tooltip to keep host information compact.
- Calculated CPU utilization between regular polls, removing the extra 0.2-second sampling delay while keeping a single SSH query for GPU and host metrics.
- Suppressed network rates for samples less than one second apart, and retained bond/bridge slave filtering when falling back to `/proc/net/dev` with available interface topology.
- Added a one-time Mac-to-iPhone server transfer in Advanced settings, with QR pairing, a six-digit comparison code, Touch ID or Mac password approval, and an encrypted local-network connection. Transferring needs the iOS app, which is still in the works and not on the App Store yet.
- Changed server export to record each target's effective username, hostname, and port, so backups no longer depend on local SSH aliases. Export now stops without writing a partial backup when a target requires ProxyJump or ProxyCommand. Normal monitoring still uses the saved SSH target.
- Thanks @JunbiaoXue for contributing server network and CPU monitoring in #7.

## 0.6.1 - 2026-11-02

- Hardened SSH command execution by draining standard output and standard error while commands run, preventing full output pipes from blocking polling.
- Improved cancellation and timeout cleanup so local SSH commands are terminated and reaped, including commands that ignore normal termination. Cancelled collection does not start a retry.
- Limited captured command output to 8 MiB per command to keep unusually large responses from growing memory without a bound.
- Prevented duplicate process metadata from causing a crash; the latest matching reading is retained.
- Extracted platform-independent models, parsers, collection logic, and the existing server backup format into NVBeaconCore, while keeping macOS SSH execution and credential handling in the app.
- Added process lifecycle regression tests, shared-core tests, and macOS/Linux CI checks.

## 0.6.0 - 2026-11-02

- Added per-server Linux RAM used/total, available RAM, and Swap monitoring in the GPU popover, with high-usage color indicators.
- Added a per-server memory query command in Advanced settings, alongside the GPU query command.
- Added a saved popover width setting in Appearance, adjustable from 480 to 800 pt with a 500 pt default. The popover and its content now always use the same width.
- Improved numeric settings so typing is not interrupted by range limits; values are validated on Return or when leaving the field.
- Avoided restarting SSH polling for appearance changes, server renaming/reordering, and alert thresholds. Superseded settings updates and outdated collection results are ignored.
- Added diagnostic information preview/copy from the current local state, excluding connection identifiers, custom commands, process details, and raw errors without running additional SSH queries.
- Added versioned JSON server backup/export and reviewed import. Imports preserve existing settings and add disabled servers with fresh IDs, without restoring passwords or notification watches.
- Restricted legacy shared-password recovery to the original migrated server so imported connections stay separate from existing credentials.
- Fixed local app packaging to record the actual macOS SDK and preserve native settings styling.
- Thanks @SAN-SHIa for contributing RAM/Swap monitoring and the popover width fix in #6.

## 0.5.0 - 2026-05-15

- Added multi-server GPU monitoring with per-server SSH target, authentication, connection reuse, enable/disable state, and remote command settings.
- Updated the menu bar popover to show all configured servers in order with per-server refresh, status, GPU rows, and adaptive height.
- Redesigned Settings server management with server ordering, saved host import, and selected-server editing.
- Stored password-based SSH credentials per server in Keychain while preserving legacy single-server migration behavior.
- Thanks @Liskie for contributing the multi-server monitoring implementation in #3.

## 0.4.2 - 2026-04-13

- Fixed the launch-at-login setting so packaged builds show a configurable `Off` state instead of incorrectly appearing unavailable.
- Simplified Settings copy by removing overly technical helper text and leaving only the most useful user-facing guidance.

## 0.4.1 - 2026-04-08

- Added a toggle to disable per-user process highlighting from the Appearance tab when users want the lightest possible polling behavior.
- Optimized process ownership detection so summary polling resolves GPU data and process UIDs in a single SSH call, while expanded process details refresh independently without resetting the main snapshot timer.
- Added a user-friendly SSH connection reuse setting with optional SSH multiplexing for faster polling, plus automatic fallback to fresh sessions when reuse is not supported cleanly.

## 0.4.0 - 2026-04-08

- Added automatic "my process" detection based on the active SSH username, with highlighting for matching remote processes and the GPUs they occupy.
- Reloaded GPU process details every time a row is expanded so VRAM usage and process metadata stay current instead of reusing stale cached values.
- Added CI-ready Developer ID signing and notarization support to the release workflow for signed DMG releases and notarized Sparkle updates.

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
