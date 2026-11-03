// Manual, read-only benchmark. Compile with benchmark_host_metrics.sh so the
// measurements use the current shared collector and macOS process runner.
import Darwin
import Foundation

private enum BenchmarkError: Error {
    case invalidArguments, missingSettings, noEligibleServers, remoteFailure, invalidResponse
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func cpuMilliseconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
    return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
}

private func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

private struct Server: Sendable {
    let target: String
    let port: String
    let identity: String
    let reusesConnection: Bool
    let gpuCommand: String
    let memoryCommand: String

    init?(_ json: [String: Any]) {
        guard json["isEnabled"] as? Bool ?? true,
              (json["sshAuthenticationMode"] as? String ?? "keyBased") == "keyBased",
              let target = json["sshTarget"] as? String, !target.isEmpty,
              !target.hasPrefix("-"), !target.contains(where: { $0.isWhitespace }) else { return nil }
        self.target = target
        port = json["sshPort"] as? String ?? ""
        identity = json["sshIdentityFilePath"] as? String ?? ""
        reusesConnection = (json["sshConnectionReuseMode"] as? String ?? "reuseWhenPossible") == "reuseWhenPossible"
        gpuCommand = json["remoteCommand"] as? String ?? RemoteMetricCommands.defaultGPUCommand
        memoryCommand = json["memoryCommand"] as? String ?? RemoteMetricCommands.defaultMemoryCommand
    }
}

private actor BenchmarkTransport: RemoteCommandExecuting {
    let server: Server
    let controlPath = "/tmp/nvbeacon-benchmark-\(UUID().uuidString.prefix(8))-%C.sock"
    var lastOutput = ""

    init(server: Server) { self.server = server }

    func execute(_ command: String) async throws -> RemoteCommandOutput {
        // Same public-key, timeout, multiplexing, shell, and bounded process
        // runner behavior as the app; use a private short-lived control socket.
        var args = ["-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=1", "-o", "TCPKeepAlive=yes",
                    "-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey",
                    "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                    "-o", "StrictHostKeyChecking=yes"]
        if server.reusesConnection {
            args += ["-o", "ControlMaster=auto", "-o", "ControlPersist=5",
                     "-o", "ControlPath=\(controlPath)", "-o", "StreamLocalBindUnlink=yes"]
        }
        if !server.port.isEmpty { args += ["-p", server.port] }
        if !server.identity.isEmpty { args += ["-i", NSString(string: server.identity).expandingTildeInPath] }
        args += [server.target, "/bin/sh", "-lc", shellQuote(command)]
        let result = try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: args)
        guard result.exitStatus == 0 else { throw BenchmarkError.remoteFailure }
        lastOutput = result.standardOutput
        return result
    }
}

private struct ReplayTransport: RemoteCommandExecuting {
    let text: String
    func execute(_ command: String) -> RemoteCommandOutput {
        .init(standardOutput: text, standardError: "", exitStatus: 0)
    }
}

private struct Observation: Codable {
    let round: Int
    let variant: String
    let wallMS: Double
    let localCPUMS: Double
    let requestBytes: Int
    let responseBytes: Int
}

private struct RemoteObservation: Codable {
    let round: Int
    let variant: String
    let wallMS: Double
    let cpuMS: Double
    let responseBytes: Int
}

private struct RemotePayload: Decodable {
    let observations: [RemoteObservation]
}

private struct ReplayObservation: Codable {
    let variant: String
    let medianWallUS: Double
    let medianCPUUS: Double
    let iterationsPerBlock: Int
    let blocks: Int
}

private struct ServerResult: Codable {
    let serverIndex: Int
    let connectionReuse: Bool
    let gpuCount: Int
    let interfaceCount: Int
    let configuredPollSeconds: Int
    let observations: [Observation]
    let remoteObservations: [RemoteObservation]
    let replayObservations: [ReplayObservation]
    let remoteMeasurementAvailable: Bool
}

private struct Report: Codable {
    let recordedAt: String
    let samplesPerVariant: Int
    let notes: [String]
    let servers: [ServerResult]
    let failedServerIndices: [Int]
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

private func remoteProgram(commands: [String: String], samples: Int) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["commands": commands, "samples": samples])
    let encoded = data.base64EncodedString()
    // Standard-library-only helper. It executes the app's generated read-only
    // commands and returns numerical measurements, never their raw output.
    return """
    python3 - <<'NVBEACON_BENCHMARK_PY'
    import base64, json, random, resource, subprocess, time
    config = json.loads(base64.b64decode('\(encoded)'))
    commands = config['commands']
    rng = random.Random(4722)
    observations = []
    for command in commands.values():
        subprocess.run(['/bin/sh', '-lc', command], capture_output=True, timeout=12, check=True)
    for trial in range(config['samples']):
        variants = list(commands)
        rng.shuffle(variants)
        for variant in variants:
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.perf_counter_ns()
            result = subprocess.run(['/bin/sh', '-lc', commands[variant]], capture_output=True, timeout=12)
            wall_ms = (time.perf_counter_ns() - start) / 1e6
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            if result.returncode:
                raise RuntimeError('remote benchmark command failed')
            cpu_ms = ((after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)) * 1000
            observations.append(dict(round=trial, variant=variant, wallMS=wall_ms, cpuMS=cpu_ms, responseBytes=len(result.stdout)))
    print(json.dumps(dict(observations=observations)))
    NVBEACON_BENCHMARK_PY
    """
}

private func replay(text: String, options: HostMetricsOptions, name: String, iterations: Int) async throws -> ReplayObservation {
    let collector = MetricsCollector(transport: ReplayTransport(text: text))
    for _ in 0..<20 { _ = try await collector.fetchSummary(hostMetrics: options) }
    var walls = [Double]()
    var cpus = [Double]()
    var checksum = 0
    for _ in 0..<7 {
        let cpu = cpuMilliseconds()
        let start = ContinuousClock.now
        for _ in 0..<iterations {
            let snapshot = try await collector.fetchSummary(hostMetrics: options)
            checksum += snapshot.gpus.count + (snapshot.hostMemory == nil ? 0 : 1)
        }
        walls.append(milliseconds(start.duration(to: .now)) * 1000 / Double(iterations))
        cpus.append((cpuMilliseconds() - cpu) * 1000 / Double(iterations))
    }
    guard checksum > 0 else { throw BenchmarkError.invalidResponse }
    return .init(variant: name, medianWallUS: median(walls), medianCPUUS: median(cpus),
                 iterationsPerBlock: iterations, blocks: walls.count)
}

@main
private struct HostMetricsBenchmark {
    static func main() async {
        do { try await run() }
        catch {
            // Raw errors can contain connection details or remote process data.
            print("Benchmark could not complete. Check the selected settings domain and public-key SSH access.")
            exit(1)
        }
    }

    static func run() async throws {
        var domain = "com.leejaein.NVBeacon"
        var samples = 12
        var maxServers = 2
        var iterations = 300
        var output = "dist/benchmarks/host-metrics-overhead.json"
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count % 2 == 0 else { throw BenchmarkError.invalidArguments }
        for offset in stride(from: 0, to: args.count, by: 2) {
            let value = args[offset + 1]
            switch args[offset] {
            case "--settings-domain": domain = value
            case "--samples": samples = Int(value) ?? 0
            case "--max-servers": maxServers = Int(value) ?? 0
            case "--parse-iterations": iterations = Int(value) ?? 0
            case "--output": output = value
            default: throw BenchmarkError.invalidArguments
            }
        }
        guard (1...50).contains(samples), (1...8).contains(maxServers), (1...10000).contains(iterations),
              let defaults = UserDefaults(suiteName: domain), let data = defaults.data(forKey: "nvbeacon.settings"),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BenchmarkError.missingSettings }
        let servers = Array(((json["servers"] as? [[String: Any]]) ?? []).compactMap(Server.init).prefix(maxServers))
        guard !servers.isEmpty else { throw BenchmarkError.noEligibleServers }
        var results = [ServerResult]()
        var failures = [Int]()
        for (index, server) in servers.enumerated() {
            print("Measuring anonymous server \(index + 1)/\(servers.count), \(samples) paired rounds.")
            fflush(nil)
            do {
                let result = try await measure(server, index: index + 1, samples: samples,
                                               iterations: iterations, pollSeconds: json["pollIntervalSeconds"] as? Int ?? 10)
                results.append(result)
                for name in ["gpuOnly", "allHost"] {
                    let rows = result.observations.filter { $0.variant == name }
                    print("server \(index + 1) \(name): median=\(String(format: "%.3f", median(rows.map(\.wallMS)))) ms, median payload=\(Int(median(rows.map { Double($0.responseBytes) }))) bytes")
                }
            } catch {
                failures.append(index + 1)
                print("Anonymous server \(index + 1) could not be measured; connection details omitted.")
            }
        }
        let report = Report(recordedAt: ISO8601DateFormatter().string(from: Date()), samplesPerVariant: samples,
                            notes: [
                                "Read-only, opt-in benchmark; no credentials, endpoints, GPU UUIDs, commands, or process details are saved.",
                                "Optimized Swift build of current core and ProcessCommandRunner; excludes GUI rendering and persistent app memory.",
                                "Warm-up excluded. SSH A/B order alternates; isolated remote command order is seeded and shuffled.",
                                "Request bytes are the generated script; response bytes are UTF-8 stdout. Neither is encrypted wire traffic.",
                                "Remote CPU includes child shell/process CPU; remote helper Python CPU is excluded.",
                                "Host-only measurements include a shell launch; subtract the paired emptyShell control to estimate incremental probe cost.",
                                "The normal monitoring app and remote workloads remain running; paired timing can contain workload/network noise."
                            ], servers: results, failedServerIndices: failures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: destination, options: .atomic)
        print("Report: \(destination.path)")
        guard !results.isEmpty else { throw BenchmarkError.noEligibleServers }
    }

    static func measure(_ server: Server, index: Int, samples: Int, iterations: Int, pollSeconds: Int) async throws -> ServerResult {
        let transport = BenchmarkTransport(server: server)
        let collector = MetricsCollector(transport: transport)
        let variants: [(String, HostMetricsOptions)] = [("gpuOnly", .none), ("allHost", .init())]
        for (_, options) in variants {
            let snapshot = try await collector.fetchSummary(gpuCommand: server.gpuCommand, memoryCommand: server.memoryCommand, hostMetrics: options)
            guard !snapshot.gpus.isEmpty else { throw BenchmarkError.invalidResponse }
        }
        var observations = [Observation]()
        var lastOutputs = [String: String]()
        var gpuCount = 0
        var interfaceCount = 0
        for round in 0..<samples {
            let order = round % 2 == 0 ? variants : Array(variants.reversed())
            for (name, options) in order {
                let cpu = cpuMilliseconds()
                let start = ContinuousClock.now
                let snapshot = try await collector.fetchSummary(gpuCommand: server.gpuCommand, memoryCommand: server.memoryCommand, hostMetrics: options)
                let wallMS = milliseconds(start.duration(to: .now))
                let cpuMS = cpuMilliseconds() - cpu
                let text = await transport.lastOutput
                let requestBytes = RemoteMetricCommands.summary(summaryCommand: server.gpuCommand,
                    memoryCommand: server.memoryCommand, hostMetrics: options).utf8.count
                observations.append(.init(round: round, variant: name, wallMS: wallMS, localCPUMS: cpuMS,
                                          requestBytes: requestBytes, responseBytes: text.utf8.count))
                lastOutputs[name] = text
                gpuCount = snapshot.gpus.count
                if name == "allHost" { interfaceCount = snapshot.networkSample?.interfaces.count ?? 0 }
            }
        }
        let baseline = RemoteMetricCommands.summary(summaryCommand: server.gpuCommand, memoryCommand: server.memoryCommand, hostMetrics: .none)
        var commands = ["gpuOnly": baseline, "emptyShell": ":"]
        for (name, options) in [
            ("cpuProbe", HostMetricsOptions(cpu: true, memory: false, network: false)),
            ("memoryProbe", HostMetricsOptions(cpu: false, memory: true, network: false)),
            ("networkProbe", HostMetricsOptions(cpu: false, memory: false, network: true)),
            ("hostProbes", HostMetricsOptions()),
        ] {
            let full = RemoteMetricCommands.summary(summaryCommand: server.gpuCommand, memoryCommand: server.memoryCommand, hostMetrics: options)
            guard full.hasPrefix(baseline) else { throw BenchmarkError.invalidResponse }
            commands[name] = String(full.dropFirst(baseline.count))
            if name == "hostProbes" { commands["allHost"] = full }
        }
        var remoteObservations = [RemoteObservation]()
        var remoteAvailable = false
        do {
            let output = try await transport.execute(remoteProgram(commands: commands, samples: samples))
            remoteObservations = try JSONDecoder().decode(RemotePayload.self, from: Data(output.standardOutput.utf8)).observations
            remoteAvailable = true
        } catch {
            print("Anonymous server \(index): isolated remote timings unavailable (Python 3/access/timeout); SSH timings retained.")
        }
        var replayObservations = [ReplayObservation]()
        for (name, options) in variants {
            if let text = lastOutputs[name] {
                replayObservations.append(try await replay(text: text, options: options, name: name, iterations: iterations))
            }
        }
        return .init(serverIndex: index, connectionReuse: server.reusesConnection, gpuCount: gpuCount,
                     interfaceCount: interfaceCount, configuredPollSeconds: pollSeconds,
                     observations: observations, remoteObservations: remoteObservations,
                     replayObservations: replayObservations, remoteMeasurementAvailable: remoteAvailable)
    }
}
