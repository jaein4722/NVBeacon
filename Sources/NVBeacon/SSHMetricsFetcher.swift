import Foundation

struct ServerReading: Sendable {
    let snapshot: GPUSnapshot
    let networkSample: NetworkSample?
}

struct SSHMetricsFetcher: Sendable {
    static let networkSampleCommand = RemoteMetricCommands.networkSampleCommand
    static let processDetailsCommand = RemoteMetricCommands.processDetailsCommand
    private static let controlSocketPath = "/tmp/nvbeacon-ssh-%C.sock"

    enum FetchError: LocalizedError, Equatable {
        case commandFailed(Int32, String)
        case commandTimedOut(Int)
        case outputLimitExceeded(Int)
        case emptyResponse
        case invalidOutput(String)
        case invalidProcessOutput(String)
        case invalidPSOutput(String)
        case askPassScriptCreationFailed
        case missingTarget

        var errorDescription: String? {
            let language = AppLocalizer.currentLanguage()
            switch self {
            case .commandFailed(_, let message):
                return message.isEmpty ? language.text("ssh command failed.", "ssh 명령이 실패했습니다.") : message
            case .commandTimedOut(let seconds):
                return language.text(
                    "ssh command timed out after \(seconds) seconds.",
                    "ssh 명령이 \(seconds)초 뒤 시간 초과되었습니다."
                )
            case .outputLimitExceeded(let limit):
                return language.text("SSH output exceeded the \(limit / 1_048_576) MiB limit.", "SSH 출력이 \(limit / 1_048_576)MiB 제한을 초과했습니다.")
            case .emptyResponse:
                return language.text("nvidia-smi output was empty.", "nvidia-smi 출력이 비어 있습니다.")
            case .invalidOutput(let line):
                return language.text("nvidia-smi output could not be parsed: \(line)", "nvidia-smi 출력을 파싱할 수 없습니다: \(line)")
            case .invalidProcessOutput(let line):
                return language.text("nvidia-smi process output could not be parsed: \(line)", "nvidia-smi process 출력을 파싱할 수 없습니다: \(line)")
            case .invalidPSOutput(let line):
                return language.text("ps output could not be parsed: \(line)", "ps 출력을 파싱할 수 없습니다: \(line)")
            case .askPassScriptCreationFailed:
                return language.text("Failed to create the temporary script for SSH password authentication.", "SSH 비밀번호 인증을 위한 임시 스크립트를 만들지 못했습니다.")
            case .missingTarget:
                return language.text("SSH target is missing.", "SSH target이 비어 있습니다.")
            }
        }
    }

    func fetchSummary(settings: AppSettings, password: String? = nil) async throws -> ServerReading {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let collector = MetricsCollector(transport: Transport(settings: normalized, password: password))
        do {
            let snapshot = try await collector.fetchSummary(gpuCommand: normalized.remoteCommand,
                                                           hostMetrics: normalized.hostMetricsOptions,
                                                           hostCommand: normalized.hostCommand)
            return ServerReading(snapshot: snapshot, networkSample: snapshot.networkSample)
        } catch {
            throw Self.localizedCollectionError(error)
        }
    }

    func fetchProcessDetails(
        settings: AppSettings,
        processes: [GPUProcessReading],
        password: String? = nil
    ) async throws -> [GPUProcessReading] {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let uniquePIDs = Array(Set(processes.map(\.pid))).sorted()
        guard !uniquePIDs.isEmpty else {
            return processes
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildDetailedPSLookupCommand(pids: uniquePIDs),
            password: password,
            allowEmptyOutput: true
        )
        let processDetails = try Self.parseDetailedPSSection(output)
        let processDetailsByPID = Dictionary(processDetails.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })

        return processes.map { process in
            guard let details = processDetailsByPID[process.pid] else {
                return process
            }

            return GPUProcessReading(
                gpuUUID: process.gpuUUID,
                pid: process.pid,
                processName: process.processName,
                usedGPUMemoryMB: process.usedGPUMemoryMB,
                userID: details.userID,
                user: details.user,
                commandLine: details.commandLine
            )
        }
    }

    func fetchRemoteUserID(
        settings: AppSettings,
        username: String,
        password: String? = nil
    ) async throws -> Int {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildRemoteUIDLookupCommand(username: username),
            password: password
        )

        guard let uid = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FetchError.invalidPSOutput(output)
        }

        return uid
    }

    func fetchProcessStatuses(
        settings: AppSettings,
        pids: [Int],
        password: String? = nil
    ) async throws -> [RemoteProcessStatus] {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let uniquePIDs = Array(Set(pids)).sorted()
        guard !uniquePIDs.isEmpty else {
            return []
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildPSLookupCommand(pids: uniquePIDs),
            password: password,
            allowEmptyOutput: true
        )

        return try Self.parsePSSection(output)
    }

    static func parse(_ output: String) throws -> [GPUReading] {
        try parsing { try MetricsParser.parse(output) }
    }

    static func parseSnapshot(_ output: String) throws -> [GPUReading] {
        try parsing { try MetricsParser.parseSnapshot(output) }
    }

    static func parseReading(_ output: String) throws -> ServerReading {
        let takenAt = Date()
        let interfaces = MetricsParser.parseNetworkSection(MetricsParser.networkSection(output))
        let sample = interfaces.isEmpty ? nil : NetworkSample(takenAt: takenAt, interfaces: interfaces)
        let snapshot = GPUSnapshot(takenAt: takenAt, gpus: try parseSnapshot(output), hostMemory: MetricsParser.parseHostMemory(output), hostCPU: MetricsParser.parseHostCPU(output), networkSample: sample, hostCPUSample: MetricsParser.parseHostCPUSample(output, takenAt: takenAt))
        return ServerReading(snapshot: snapshot, networkSample: sample)
    }

    static func parseHostCPU(_ output: String) -> Int? {
        MetricsParser.parseHostCPU(output)
    }

    static func parseHostMemory(_ output: String) -> HostMemoryReading? {
        MetricsParser.parseHostMemory(output)
    }

    private static func parsePSSection(_ output: String) throws -> [RemoteProcessStatus] {
        try parsing { try MetricsParser.parsePSSection(output) }
    }

    private static func parseDetailedPSSection(_ output: String) throws -> [RemoteProcessStatus] {
        try parsing { try MetricsParser.parseDetailedPSSection(output) }
    }

    private func runSSHCommand(
        settings: AppSettings,
        remoteCommand: String,
        password: String?,
        allowEmptyOutput: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        let trimmedPassword = password?.trimmingCharacters(in: .newlines)
        do {
            return try await Self.executeSSHCommand(
                settings: settings, remoteCommand: remoteCommand,
                trimmedPassword: trimmedPassword, allowEmptyOutput: allowEmptyOutput
            )
        } catch let error as FetchError {
            try Task.checkCancellation()
            guard settings.sshConnectionReuseMode == .reuseWhenPossible,
                  Self.shouldRetryWithoutConnectionReuse(after: error) else { throw error }
            var fallbackSettings = settings
            fallbackSettings.sshConnectionReuseMode = .newConnectionEachRefresh
            return try await Self.executeSSHCommand(
                settings: fallbackSettings, remoteCommand: remoteCommand,
                trimmedPassword: trimmedPassword, allowEmptyOutput: allowEmptyOutput
            )
        }
    }

    private static func executeSSHCommand(
        settings: AppSettings,
        remoteCommand: String,
        trimmedPassword: String?,
        allowEmptyOutput: Bool
    ) async throws -> String {
        let askPassScriptURL: URL?

        if let trimmedPassword, !trimmedPassword.isEmpty {
            askPassScriptURL = try createAskPassScript()
        } else {
            askPassScriptURL = nil
        }

        defer {
            if let askPassScriptURL {
                try? FileManager.default.removeItem(at: askPassScriptURL)
            }
        }

        let arguments = buildSSHArguments(
            settings: settings,
            prefersPasswordAuth: !(trimmedPassword?.isEmpty ?? true),
            remoteCommand: remoteCommand
        )
        var environment: [String: String]?
        if let askPassScriptURL, let trimmedPassword {
            environment = ProcessInfo.processInfo.environment.merging(
                ["SSH_ASKPASS": askPassScriptURL.path,
                 "SSH_ASKPASS_REQUIRE": "force",
                 "GPUUSAGE_SSH_PASSWORD": trimmedPassword,
                 "DISPLAY": "nvbeacon:0"],
                uniquingKeysWith: { _, newValue in newValue }
            )
        }
        let result: ProcessCommandRunner.Output
        do {
            result = try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: arguments, environment: environment
            )
        } catch ProcessCommandRunner.RunError.timedOut {
            throw FetchError.commandTimedOut(15)
        } catch ProcessCommandRunner.RunError.outputLimitExceeded(let limit) {
            throw FetchError.outputLimitExceeded(limit)
        }
        let stdout = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)

        guard result.exitStatus == 0 else {
            throw FetchError.commandFailed(result.exitStatus, stderr.isEmpty ? stdout : stderr)
        }

        guard allowEmptyOutput || !stdout.isEmpty else {
            throw FetchError.emptyResponse
        }

        return stdout
    }

    static func buildSSHArguments(
        settings: AppSettings,
        prefersPasswordAuth: Bool,
        remoteCommand: String
    ) -> [String] {
        var arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "TCPKeepAlive=yes",
        ]

        if settings.sshConnectionReuseMode == .reuseWhenPossible {
            arguments.append(contentsOf: [
                "-o", "ControlMaster=auto",
                "-o", "ControlPersist=45",
                "-o", "ControlPath=\(controlSocketPath)",
                "-o", "StreamLocalBindUnlink=yes",
            ])
        }

        if prefersPasswordAuth {
            arguments.append(contentsOf: [
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=password,keyboard-interactive,publickey",
            ])
        } else {
            arguments.append(contentsOf: [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
            ])
        }

        if !settings.sshIdentityFilePath.isEmpty {
            arguments.append(contentsOf: ["-i", settings.sshIdentityFilePath])
        }

        if let port = settings.resolvedPort {
            arguments.append(contentsOf: ["-p", String(port)])
        }

        arguments.append(settings.sshTarget)
        arguments.append(contentsOf: [
            "/bin/sh",
            "-lc",
            shellQuoted(remoteCommand),
        ])

        return arguments
    }

    private static func shouldRetryWithoutConnectionReuse(after error: FetchError) -> Bool {
        switch error {
        case .commandFailed(_, let message):
            let normalized = message.lowercased()
            return normalized.contains("control socket")
                || normalized.contains("mux_client")
                || normalized.contains("master is dead")
                || normalized.contains("session open refused by peer")
                || normalized.contains("broken pipe")
        case .commandTimedOut:
            return true
        default:
            return false
        }
    }

    static func buildSummaryRemoteCommand(summaryCommand: String, memoryCommand: String = AppSettings.defaultMemoryCommand, includesNetworkUsage: Bool = true, hostCommand: String? = nil) -> String {
        RemoteMetricCommands.summary(summaryCommand: summaryCommand, memoryCommand: memoryCommand, includesNetworkUsage: includesNetworkUsage, hostCommand: hostCommand)
    }

    private static func buildPSLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    private static func buildDetailedPSLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o uid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    private static func buildRemoteUIDLookupCommand(username: String) -> String {
        "id -u -- \(shellQuoted(username))"
    }

    private static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func createAskPassScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-askpass-\(UUID().uuidString).sh")
        let contents = """
        #!/bin/sh
        printf '%s' "$GPUUSAGE_SSH_PASSWORD"
        """

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            throw FetchError.askPassScriptCreationFailed
        }
    }

    private static func parsing<Value>(_ parse: () throws -> Value) throws -> Value {
        do { return try parse() }
        catch { throw localizedCollectionError(error) }
    }

    private static func localizedCollectionError(_ error: any Error) -> any Error {
        if let error = error as? MetricsParseError {
            switch error {
            case .emptyResponse: return FetchError.emptyResponse
            case .invalidOutput(let line): return FetchError.invalidOutput(line)
            case .invalidProcessOutput(let line): return FetchError.invalidProcessOutput(line)
            case .invalidPSOutput(let line): return FetchError.invalidPSOutput(line)
            }
        }
        if case let MetricsCollectionError.commandFailed(status, message) = error {
            return FetchError.commandFailed(status, message)
        }
        return error
    }

    private struct Transport: RemoteCommandExecuting {
        let settings: AppSettings
        let password: String?

        func execute(_ command: String) async throws -> RemoteCommandOutput {
            let text = try await SSHMetricsFetcher().runSSHCommand(
                settings: settings, remoteCommand: command, password: password
            )
            return RemoteCommandOutput(standardOutput: text, standardError: "", exitStatus: 0)
        }
    }
}
