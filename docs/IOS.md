# NVBeacon for iOS

## Implemented

- Native SwiftUI server list, per-server dashboard and settings.
- Multiple servers, explicit hostname/IP, username and SSH port.
- Password authentication and automatic detection of OpenSSH Ed25519, RSA (2048–8192-bit) and ECDSA (P-256/P-384/P-521)
  private keys, including bcrypt/AES-CTR protected keys (up to 256 rounds). Credentials use device-only, unlocked Keychain
  items and are excluded from server backups and application preferences.
- Explicit first-connection host fingerprint review before authentication.
  The accepted key is pinned to the exact hostname and port. Key changes block
  collection until the user verifies the change and resets trust.
- Shared-core GPU utilization, VRAM, temperature, process and Linux host RAM/swap
  parsing. Process ownership and full command lines are loaded separately;
  unavailable metadata does not discard the GPU snapshot.
- Configurable foreground polling (5–300 seconds), pull to refresh, at most four
  simultaneous server collections, cancellation on scene deactivation, and
  reconnection on return. Failed refreshes retain the last successful snapshot
  with an error and its timestamp. Edits invalidate in-flight results.
- Reviewed import/export of the existing `NVBeacon.servers` v1 JSON format.
  Imported servers receive new IDs and start disabled; local credentials,
  desktop identity-file paths and host trust are never restored from a backup.

## Build and test

From the repository root:

```bash
# Simulator build with Xcode’s local signing for Keychain access.
./scripts/build_ios.sh

# Compile for a physical iPhone/iPad without provisioning or installing.
SDK=iphoneos ./scripts/build_ios.sh

# Mobile model, SSH channel and lifecycle tests on macOS.
swift test --package-path Mobile/NVBeaconMobile --build-system native

# Existing app and portable-core regression tests.
swift test --build-system native
swift test --package-path Shared/NVBeaconCore --build-system native
```

`build_ios.sh` prints the selected Xcode/SDK and rejects SDKs older than 27.1.
It uses the unversioned `iphoneos` / `iphonesimulator` SDK selector so that the
newest SDK in the selected Xcode is used. Set `DEVELOPER_DIR` if you have multiple
Xcode installations. Build products and dependency clones stay in ignored
`.build/ios` and `.build/ios-packages` directories. SwiftPM and the Xcode project
have dependency lockfiles. For RSA user authentication the preview uses the
andrewkomkov Citadel and NIOSSH forks at revisions `e039002` and `ca4d82b`.
The wire key blob stays `ssh-rsa` and the authentication signature uses
`rsa-sha2-256`. These are fork revisions rather than upstream releases.
Recheck [Citadel #131](https://github.com/orlandos-nl/Citadel/pull/131) and
[NIOSSH #3](https://github.com/Wellz26/swift-nio-ssh/pull/3) when upgrading.
On macOS, `./scripts/test_ios_ssh_keys.sh` generates temporary keys and exercises the
mobile transport against a loopback OpenSSH daemon using plain and passphrase-protected
Ed25519, RSA and ECDSA P-256/P-384/P-521 files. RSA authentication is restricted to SHA-256.

The manual **iOS** GitHub Actions workflow chooses the newest installed SDK and
runs mobile tests and both platform builds. It intentionally fails when the
runner lacks SDK 27.1+ instead of silently building with an older SDK. Run it on
a runner image providing that toolchain; macOS release checks are unchanged.

For interactive testing, install an iOS simulator runtime through Xcode Settings
→ Components, choose an iPhone or iPad, and Run. For a physical device, choose
your development team under Signing & Capabilities and a bundle identifier
available to that team. The command-line script disables signing for physical-device compile
checks; use Xcode Run or Archive for signed builds.

## Connect a server

1. Add a reachable DNS hostname or IP and an explicit username. For internal
   servers, enable your VPN first and allow local-network access if prompted.
2. Import an Ed25519, RSA or ECDSA OpenSSH private key from Files, or select password
   authentication if the SSH server supports it. Enter the key passphrase if
   needed. Save the server.
3. Open the server, choose **Verify Host Key**, compare the SHA256 fingerprint
   against a trusted source, then choose **Trust and Connect**.
4. Confirm GPU/RAM readings and expand a process to see its command line.

Older macOS backups may contain aliases such as `lab-gpu` and key paths such as
`~/.ssh/id_ed25519`. iOS cannot read the Mac's SSH config, key files or agent.
Replace aliases with reachable endpoints and register credentials on the device
before enabling each imported server. Custom commands execute under the SSH
account; review them before enabling imported servers.

## Import a Mac backup during testing

Rebuild and run the app in Xcode after updating `Mobile/App.xcconfig` and
`Mobile/Info.plist`; the iOS
Files integration requires `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace`. Credentials remain in Keychain, outside the
shared Documents folder.

With NVBeacon installed in your already-running simulator, run from the repo:

```bash
./scripts/stage_ios_backup.sh "/absolute/path/to/NVBeacon-servers.json"
```

This copies the file into the app's Documents folder without creating, booting,
restarting or deleting a simulator, and without applying any settings. With
multiple simulators running, explicitly select the one you are testing:

```bash
SIMULATOR_UDID="your-device-udid" ./scripts/stage_ios_backup.sh "/absolute/path/to/NVBeacon-servers.json"
```

Known simulator issue observed during interactive validation: the NVBeacon app
folder can appear in Files but fail to open with a DocumentManager cached-domain
error, even though the JSON exists. Restarting the picker and simulator did not
resolve this in the tested runtime. Import from a separate local Files folder
worked. The staging helper copies correctly, but app-folder navigation is not
fully validated; use another Files location if this occurs.

In NVBeacon, choose **Import Server Backup** on the empty screen or **… → Import
Servers**, then **Browse → On My iPhone/iPad → NVBeacon** and choose the JSON.
Review the server count and names, then choose **Import**. On a physical device,
put the JSON in iCloud Drive or another Files provider and select it there.

Verify that existing servers remain, the imported server count matches the
backup, all imported servers are disabled, and Edit Server retains the expected
port, authentication type and GPU/memory commands. Replace Mac SSH aliases with
reachable hosts, enter an explicit username and register device credentials
before enabling. Import does not restore passwords, private keys or host trust.

## Architecture

```text
Mobile/NVBeacon/                  SwiftUI app, Files integration, scene lifecycle
Mobile/NVBeaconMobile/            iOS client models, store, Keychain and SSH
Shared/NVBeaconCore/              Models, commands, parser, collector, archive
Sources/NVBeacon/                 Existing macOS app and OpenSSH transport
```

The mobile package uses Citadel's OpenSSH key parsing and authentication delegates
with NIOSSH negotiation, and a bounded NIO child-channel handler to retain stdout,
stderr and exit status (including exit status delivered after EOF). Each remote
command owns a fresh TCP/SSH connection. The transport owns
the TCP channel throughout authentication, closes it on cancellation, bounds
connection setup to 10 seconds, applies a 25-second request deadline, and caps
combined output at 2 MiB before buffering. A connection closed without an exit
status is a failed request. No remote shell or local `Process` runs on iOS.

The package also builds on macOS so its client and transport behavior can be
tested without a simulator. The macOS executable and its Sparkle dependency do
not depend on the mobile package. No new dependency was added to NVBeaconCore.

## Remaining port work

This is a foreground-monitoring preview, not full macOS feature parity.

- Continuous SSH polling while backgrounded or locked is unavailable. Reliable
  background job-exit/idle alerts require a separately designed server-side
  monitor and push delivery; no silent background entitlement is declared.
- GPU-idle watches, PID-exit watches, notification history, widgets and Live
  Activities have not been ported.
- OpenSSH aliases, ProxyJump, SSH agents, interactive keyboard authentication/MFA,
  legacy PEM/PKCS#8 containers, RSA-SHA512-only servers and connection reuse are not supported in the preview.
- English UI only; localization and fuller iPad layouts remain follow-up work.

Suggested next milestone: validate the first device connection, then port
foreground watch behavior with explicit iOS lifecycle semantics before choosing
a background notification architecture.

## Initial validation (2026-11-02)

- Xcode 27.2 / SDK 27.2 simulator and unsigned physical-device builds succeeded.
- macOS app, portable-core and mobile-package tests passed. Mobile integration
  tests use temporary loopback SSH servers to exercise password/Ed25519
  authentication, unknown/changed host-key rejection, both output streams,
  exit status after EOF, cancellation and hung-command deadlines.
- The app launched on an iPhone 18 Pro simulator running iOS 27.2; the initial
  monitor and settings screens were visually inspected.
- The monitor toolbar label was then constrained to its icon after visual
  inspection showed an oversized menu. Both builds passed again; a subsequent
  simulator rerun was blocked because `simctl list runtimes` returned an empty
  list. That final visual adjustment still needs an interactive recheck.
- Real GPU-server collection, full interactive server-editor/Files flows and
  physical-device execution have not yet been validated. A simulator launch
  does not establish those checks.
- After a separate Xcode assistant removed module imports, the required imports
  were restored. A Debug build for the user's existing iPhone 18 Pro destination
  then succeeded with SDK 27.2 and `ONLY_ACTIVE_ARCH=YES` / arm64, using two build
  jobs and without booting, installing or launching a simulator. That build also
  includes the Files sharing configuration. User-side Xcode Run and end-to-end
  import remain to be checked.

## Interactive import validation (2026-11-02)

The Xcode build and app launch succeeded on the selected iPhone 18 Pro simulator
with iOS 27.2. Two reviewed imports from a separate local Files folder succeeded:
an eight-server Mac backup and an eight-server test copy with SSH aliases resolved
to explicit endpoints. Persisted settings matched their source data, all imports
remained disabled, and representative editor ports were verified. No credentials
were imported and no real SSH/GPU-server collection was performed. Resolving
aliases for the test copy was an external preparation step; the Mac export
implementation has not yet changed.
