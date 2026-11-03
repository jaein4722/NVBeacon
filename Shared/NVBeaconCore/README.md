# NVBeaconCore

A dependency-free Swift package for NVBeacon clients. It contains Foundation-only
GPU/process/host-metric models, parsing, Linux remote-query command construction,
the versioned server archive schema, and a transport-injected metrics collector.

```bash
swift test --package-path Shared/NVBeaconCore
```

The package can be built independently of the macOS executable and Sparkle.
Apple deployment floors are macOS 14 and iOS 17; these declarations do not restrict
Linux or Windows clients. Linux core tests run in the PR workflow. Windows runtime
validation remains work for the Windows client/toolchain effort.

## Platform boundary

- Clients implement `RemoteCommandExecuting`. Connection setup, credentials,
  host-key trust, cancellation, and transport-specific timeouts belong there.
- Core checks cancellation before and after collection and never launches
  `Process`, accesses a Keychain, reads `~/.ssh/config`, or performs UI work.
- The current query defaults target NVIDIA Linux servers. Client portability does
  not imply that `/proc/meminfo` exists on Windows remote servers.
- Session presentation, notification watches, app preferences, local filesystem
  permission handling, localization, and lifecycle scheduling remain app-side.

## Host collection

`MetricsCollector.fetchSummary(hostMetrics:)` accepts `HostMetricsOptions` to
select CPU, memory, and network collection. All are enabled by default;
`.none` omits their remote commands and parsing. GPU collection is independent.

CPU samples contain aggregate counters and the boot timestamp from `/proc/stat`.
Clients retain the previous sample per connection and use `CPUUsageEvaluator`
between polls, just as `NetworkUsageEvaluator` uses previous network counters.
There is no extra sampling sleep or SSH command. Keep baselines separate per
server and reset them when collection or connection settings change.

## Archive compatibility

The `NVBeacon.servers` v1 JSON schema is unchanged. SSH targets and identity paths
are opaque data in core. A target may be an OpenSSH alias and a path may refer to
another machine. A future iOS/Windows client must resolve/import suitable endpoint
information and register credentials locally; sharing this schema alone does not
make every existing macOS SSH configuration portable.

The macOS adapter retains import review, private-file handling, fresh local IDs,
disabled initial imports, and separation from existing credentials.
