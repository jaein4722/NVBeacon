# NVBeacon for iOS Changelog

Release notes for the iPhone and iPad app. The Mac app's notes are in [CHANGELOG.md](../CHANGELOG.md).

## 1.0.1 - 2026-11-17

- Fixed missing GPU processes on servers whose login shell is zsh, and collection on servers whose login shell is tcsh or fish. Remote commands now always run in `/bin/sh`.
- GPU processes whose `/proc` entry is hidden on the server (for example with `hidepid` or in containers) are now listed with an unknown owner instead of disappearing.
- Text that a server's login files print, such as a welcome banner, no longer breaks collection or the process owner lookup.
- The summary's **Updated** time now shows the oldest data instead of the newest, and a server that missed refreshes shows how long ago it last updated.
- **Cancel** in the server editor now also stops a save that is still unlocking an encrypted key.
- The import review now shows custom memory commands from older Mac backups instead of hiding them.
- Reorganized Settings into General, Monitoring, GPUs and Processes, Host Information, Display, Advanced and About, using the same names and Korean wording as the Mac app.

## 1.0.0 - 2026-11-17

- Initial release for iPhone and iPad: SSH GPU monitoring, optional host metrics, Mac transfer and settings backup.
