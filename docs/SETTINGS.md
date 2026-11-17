# Settings Layout and Wording

The desktop clients (macOS, and Windows when it ships) use the same settings layout and wording. Each client implements its own settings screen; only the rules below are shared. The iPhone and iPad app follows the wording rules and the glossary.

## Tabs

| Tab | Contents |
| --- | --- |
| General | Launch at login, updates, language, Dock or taskbar icon |
| Servers | Server list and order, adding servers, the selected server's connection, authentication, password, SSH connection reuse, query commands and connection test |
| Monitoring | Refresh interval, busy GPU detection, highlighting your own processes, host information, GPU history |
| Notifications | Permission, GPU idle alert thresholds, active watches, recent history |
| Display | Menu bar text, display mode (popover or window), keep window on top, theme, popover width and height, closing on outside click |
| Advanced | Server backup, import and transfer, diagnostic information, reloading and clearing saved settings |
| About | App identity, version and build, links, runtime snapshot |

## Rules

1. **Group by task.** A tab holds one kind of task. Do not add a setting to a tab because it has room.
2. **Per-server settings live only in Servers.** Everything that applies to the selected server (connection, commands, reuse, test) is there, and nothing global is.
3. **Two places for help text.** Help for one item is a single caption line under its label. A note that covers a whole section is the section footer. Longer help for one item opens from a `?` button. No free-standing text rows, except transient status such as an import result.
4. **Dependent controls.** Controls that depend on a switch stay visible and are disabled while the switch is off. Fields that belong to one choice of a picker (a fixed height, password fields, a threshold for one detection mode) appear only for that choice.
5. **Order.** Common settings first. Reloading, clearing and deleting come last, use a red button and ask for confirmation.
6. **Ranges and defaults.** Numeric fields state their range and default in the caption, for example `1–300 s · Default 10 s`.

## Wording

- English: section headers, buttons and menu items use title case ("Check Now", "Keep Window on Top"). Labels of rows, switches and pickers use sentence case ("Refresh interval", "Keep window on top").
- Buttons that open another window or ask a question end with an ellipsis ("Delete History…").
- Korean: use the glossary below and no English words except product names, commands and units.

## Glossary

| Concept | English | Korean |
| --- | --- | --- |
| Periodic remote query | collection, refresh | 수집, 새로고침 |
| Refresh interval | Refresh interval | 새로고침 주기 |
| Busy GPU | busy | 사용 중 |
| Idle GPU | idle | 유휴 |
| Threshold | threshold | 기준 |
| Process or GPU alert subscription | watch | 감시 |
| Notification | notification, alert | 알림 |
| Process owner check | owner check | 소유자 확인 |
| macOS Keychain | Keychain | 키체인 |
| SSH identity file | key file | 키 파일 |
| Popover / window | popover / window | 팝오버 / 창 |
