# Settings Layout and Wording

NVBeacon has three clients: macOS, iPhone and iPad, and Windows (in the works). Each implements its own settings screen; the rules, names and glossary below are shared so that a setting looks and reads the same everywhere.

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

## iPhone and iPad

iOS has one Settings screen instead of tabs. Its sections follow the desktop tab order and names, and leave out what does not exist on iOS:

| Section | Contents |
| --- | --- |
| General | Language |
| Monitoring | Refresh interval, busy GPU detection, highlighting your own processes, host information |
| Display | Theme |
| Advanced | Server backup and import, diagnostic information |
| About | Version and build, open source licenses, links |

- The server list is the main screen. Per-server settings (connection, authentication, reuse, commands) live only in the server editor, as in the desktop Servers tab.
- Platform notes, such as monitoring pausing in the background, go in a section footer rather than in a text row.
- Desktop-only settings (launch at login, Dock icon, display mode, popover size, alert thresholds) are omitted, not shown disabled.

## Rules

1. **Group by task.** A tab holds one kind of task. Do not add a setting to a tab because it has room.
2. **Per-server settings live only in Servers.** Everything that applies to the selected server (connection, commands, reuse, test) is there, and nothing global is.
3. **Two places for help text.** Help for one item is a single caption line under its label. A note that covers a whole section is the section footer. Longer help for one item opens from a `?` button. No free-standing text rows, except transient status such as an import result.
4. **Dependent controls.** Controls that depend on a switch stay visible and are disabled while the switch is off. Fields that belong to one choice of a picker (a fixed height, password fields, a threshold for one detection mode) appear only for that choice.
5. **Order.** Common settings first. Reloading, clearing and deleting come last, use a red button and ask for confirmation.
6. **Ranges and defaults.** Numeric fields state their range and default in the caption, for example `1–300 s · Default 10 s`.
7. **One name everywhere.** A setting that exists on several clients uses the same English and Korean label on each, even when the control differs (a stepper on macOS, a picker on iOS).

## Adding or Moving a Setting

1. Choose the tab (and the iOS section) with rules 1 and 2.
2. Decide for each client whether it applies. Leave it out where the feature does not exist; do not show it disabled.
3. Use the same label on every client and follow the wording rules. Add a glossary row for a new concept.
4. Update the tables in this document in the same change.

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
