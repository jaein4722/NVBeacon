<a id="readme-top"></a>

<div align="center">
  <img src="assets/banner.jpg" alt="NVBeacon: remote GPU monitoring over SSH">
  <p>Remote NVIDIA GPU monitoring over SSH, from your Mac menu bar and on iPhone and iPad.</p>
  <p>
    <img src="https://img.shields.io/github/v/release/jaein4722/NVBeacon?style=flat-square" alt="GitHub Release">
    <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&logo=apple" alt="macOS 14+">
    <img src="https://img.shields.io/badge/iOS-17%2B-111111?style=flat-square&logo=apple" alt="iOS 17+">
    <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="MIT License">
  </p>
  <p>
    <a href="#download">Download</a>
    ·
    <a href="https://jaein4722.github.io/NVBeacon/">Website</a>
    ·
    <a href="https://github.com/jaein4722/NVBeacon/issues">Report a Bug</a>
    ·
    <a href="https://github.com/jaein4722/NVBeacon/issues">Request a Feature</a>
  </p>
</div>

> [!NOTE]
> **NVBeacon for iPhone and iPad is out now!** Check on your GPU servers from anywhere. [Get it on the App Store](https://apps.apple.com/app/nvbeacon/id6830951631).
>
> **NVBeacon 1.0 is on its way.** It will be released together with the launch of NVBeacon for Windows. Stay tuned!

<div align="center">
  <img src="assets/menu-bar-summary.png" alt="NVBeacon menu bar summary" width="320">
</div>

<div align="center">
  <img src="assets/popover-overview.png" alt="NVBeacon popover in light mode" width="46%">
  <img src="assets/popover-overview-dark.png" alt="NVBeacon popover in dark mode" width="46%">
</div>

NVBeacon connects to your GPU servers over plain SSH, runs `nvidia-smi`, and shows what every GPU is doing. Nothing is installed on the server, and there is no account or cloud service. It answers the questions you keep opening Terminal for:

- Is the server busy right now?
- Which GPU is running my job, and what else is on it?
- Did my training job finish?
- Has a GPU stayed idle long enough to use?

## Download

| Platform | Get NVBeacon | Requires |
| --- | --- | --- |
| **macOS** | `brew install --cask jaein4722/tap/nvbeacon`<br>or the DMG from [GitHub Releases](https://github.com/jaein4722/NVBeacon/releases) | macOS 14 or later |
| **iPhone & iPad** | <a href="https://apps.apple.com/app/nvbeacon/id6830951631"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/en-us" alt="Download on the App Store" height="40"></a> | iOS 17 or later |
| **Windows** | In the works | |

On each server you only need SSH access and `nvidia-smi`.

## Features

**GPUs at a glance**
- Utilization, memory, temperature and process count for every GPU, across as many servers as you add.
- Busy detection by processes, memory or utilization. Your own jobs and GPUs are highlighted.

**Processes**
- Every GPU process with its user, PID, GPU memory and command line.

**The rest of the server**
- CPU, RAM, swap and network throughput in one collapsible section. Each metric can be turned off.

**Connections**
- SSH keys or passwords, several servers at once, and JSON backup and restore of server settings.
- Move every server from your Mac to iPhone with a QR code.
- English and Korean, light and dark appearance.

### Mac and iPhone

| | Mac | iPhone & iPad |
| --- | --- | --- |
| Where it lives | Menu bar summary (text or icon) and a popover, or a window you can keep on top | Overview of all servers; split view on wider screens |
| Refresh | Every 1–300 seconds (default 10), in the background | Every 5–300 seconds while the app is open |
| Job alerts | Notifications when a watched process exits or a starred GPU stays idle | — |
| GPU history | Optional, per user, up to 24 hours | — |
| Adding servers | Manually or from `~/.ssh/config` | Manually, from a backup, or from your Mac |
| Host keys | Your OpenSSH `known_hosts` | Fingerprint review before the first login |

## Quick Start

### Mac

1. Open NVBeacon. It appears in the menu bar.
2. Right-click the menu bar item and choose **Settings…**.
3. In **Servers**, add a server or import one from `~/.ssh/config`, choose key or password authentication, and click **Test Connection**.
4. Left-click the menu bar item to open the popover. To keep it open on screen, choose **Show as Window**.
5. Allow notifications if you want job alerts.

Settings apply as you change them.

### iPhone and iPad

Add a server with its hostname or IP address, username and port, then confirm its host fingerprint. Connect your VPN first for private servers; SSH aliases, ProxyJump and SSH agent connections are not supported on iPhone.

To bring your Mac servers over, put both devices on the same network. On the Mac, choose **Settings → Advanced → Transfer All Servers to iPhone…**. On iPhone, choose **Transfer from Mac**, scan the QR code, and check that both screens show the same six digits.

## Privacy and Security

- Your device connects to your servers directly. There is no NVBeacon account, cloud service, advertising or analytics. See the [privacy policy](https://jaein4722.github.io/NVBeacon/privacy.html).
- Nothing is installed on the server. NVBeacon runs `nvidia-smi` and reads Linux counters such as `/proc/meminfo` over SSH.
- Passwords are stored in the Keychain. In key mode, the Mac app never reads the Keychain while polling.
- Server backups never contain passwords or private keys. The Mac → iPhone transfer sends credentials only over its encrypted, code-verified connection.
- Diagnostic reports leave out server names, addresses, users, key paths, commands and process details.

## FAQ

<details>
<summary>The popover says <code>nvidia-smi</code> was not found.</summary>

Non-interactive SSH shells often have a shorter `PATH`. In the Mac app, open **Settings → Servers**, select the server and set its GPU query command to an absolute path such as `/usr/bin/nvidia-smi`.
</details>

<details>
<summary>How much load does NVBeacon put on a server?</summary>

One SSH command per refresh. GPU, CPU, memory and network data share that call, and both apps reuse the SSH connection between refreshes by default. CPU and network rates are computed from consecutive refreshes, so they appear from the second refresh on. On Mac, a command times out after 15 seconds.
</details>

<details>
<summary>Why does the Mac app warn me when I switch to password authentication?</summary>

Passwords are less secure than SSH keys. NVBeacon stores each password in the Keychain and unlocks it once per app session so polling does not prompt you repeatedly.
</details>

<details>
<summary>Where is GPU history stored, and how do I turn it off?</summary>

GPU history is off by default. When it is on, the Mac app samples per-user GPU usage at most once a minute per server and appends one short JSON line per GPU to `~/Library/Application Support/com.leejaein.NVBeacon/GPUHistory/`. Data older than 24 hours is dropped. Turn it off in Settings; existing files stay until you delete that folder.
</details>

<details>
<summary>Can I monitor a server behind a jump host?</summary>

On Mac, yes: NVBeacon uses your OpenSSH setup, including `ProxyJump` in `~/.ssh/config`. Such servers cannot be exported to a backup. On iPhone, connect through a VPN instead.
</details>

## Advanced

<details>
<summary>Custom query commands</summary>

In **Settings → Servers**, the GPU query command and the host information command apply to the selected server. An empty host command restores the default script.

A custom host command must print these sections:

| Section marker | Output |
| --- | --- |
| `__NVBEACON_CPU_SECTION__` | One aggregate `cpu` line and a `btime` line from `/proc/stat` |
| `__NVBEACON_MEMORY_SECTION__` | `/proc/meminfo` fields in kB: `MemTotal`, `MemAvailable`, optionally `SwapTotal` and `SwapFree` |
| `__GPUUSAGE_NETWORK_SECTION__` | One `interface received_bytes transmitted_bytes` line per interface |

The app sets `NVBEACON_COLLECT_CPU`, `NVBEACON_COLLECT_MEMORY` and `NVBEACON_COLLECT_NETWORK` to `1` or `0`. Honor them so that disabled metrics are not collected. Missing or malformed host output never interrupts GPU monitoring.
</details>

<details>
<summary>Server backups</summary>

**Settings → Advanced → Export Servers…** saves server settings as `NVBeacon.servers` JSON (version 2). Each target is resolved with OpenSSH to its effective user, host and port. Export stops if a server needs ProxyJump or ProxyCommand. Backups include key-file paths, authentication and reuse modes, and custom commands; treat them as private.

**Import Servers…** shows a preview first. Imported servers get new IDs and start disabled, and existing servers are kept. Importing does not install keys or restore passwords. Version 1 backups can still be imported. The limit is 100 servers and 1 MB.
</details>

<details>
<summary>Transferring servers to iPhone</summary>

The Mac can send OpenSSH keys and unencrypted PEM keys (RSA PKCS#1, ECDSA SEC1, and PKCS#8 for RSA, ECDSA and Ed25519). Keys held only by an SSH agent or a hardware token need separate setup on iPhone; a passphrase-protected key is unlocked on iPhone.

The QR code expires after three minutes, and each pairing sends the full server list once. After import, review the host fingerprints together and choose **Trust and Connect**. New servers start disabled. Existing servers that already have credentials are kept.
</details>

<details>
<summary>Host information details</summary>

RAM used is `MemTotal − MemAvailable`, so reclaimable cache is not counted. RAM and swap bars turn orange at 85% and red at 95%. They do not reflect container, cgroup or scheduler limits.

Network rates come from `/sys/class/net` or `/proc/net/dev`. Loopback, container and overlay interfaces are skipped, and bonded or bridged interfaces are counted once through the aggregate device. This filtering is heuristic.
</details>

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for building, testing and packaging the Mac app, and [docs/IOS.md](docs/IOS.md) for the iPhone and iPad app. The platform-independent models, parsers, query commands and backup format live in [NVBeaconCore](Shared/NVBeaconCore/README.md). Release notes are in [CHANGELOG.md](CHANGELOG.md).

## License

Distributed under the MIT License. See [LICENSE](LICENSE).

<p align="right">(<a href="#readme-top">back to top</a>)</p>
