import Foundation

struct SSHMetricsFetcher: Sendable {
    static let processDetailsCommand = "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
    private static let processSectionSeparator = "__GPUUSAGE_PROCESS_SECTION__"
    private static let psSectionSeparator = "__GPUUSAGE_PS_SECTION__"

    enum FetchError: LocalizedError, Equatable {
        case commandFailed(Int32, String)
        case emptyResponse
        case invalidOutput(String)
        case invalidProcessOutput(String)
        case invalidPSOutput(String)
        case askPassScriptCreationFailed
        case missingTarget

        var errorDescription: String? {
            switch self {
            case .commandFailed(_, let message):
                return message.isEmpty ? "ssh command failed." : message
            case .emptyResponse:
                return "nvidia-smi output was empty."
            case .invalidOutput(let line):
                return "nvidia-smi output could not be parsed: \(line)"
            case .invalidProcessOutput(let line):
                return "nvidia-smi process output could not be parsed: \(line)"
            case .invalidPSOutput(let line):
                return "ps output could not be parsed: \(line)"
            case .askPassScriptCreationFailed:
                return "SSH 비밀번호 인증을 위한 임시 스크립트를 만들지 못했습니다."
            case .missingTarget:
                return "SSH target is missing."
            }
        }
    }

    func fetchSummary(settings: AppSettings, password: String? = nil) async throws -> GPUSnapshot {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let output = try await runSSHCommand(
            settings: normalized,
            remoteCommand: Self.buildSummaryRemoteCommand(summaryCommand: normalized.remoteCommand),
            password: password
        )
        let gpus = try Self.parseSnapshot(output)
        return GPUSnapshot(takenAt: Date(), gpus: gpus)
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
            remoteCommand: Self.buildPSLookupCommand(pids: uniquePIDs),
            password: password,
            allowEmptyOutput: true
        )
        let processDetails = try Self.parsePSSection(output)
        let processDetailsByPID = Dictionary(uniqueKeysWithValues: processDetails.map { ($0.pid, $0) })

        return processes.map { process in
            guard let details = processDetailsByPID[process.pid] else {
                return process
            }

            return GPUProcessReading(
                gpuUUID: process.gpuUUID,
                pid: process.pid,
                processName: process.processName,
                usedGPUMemoryMB: process.usedGPUMemoryMB,
                user: details.user,
                commandLine: details.commandLine
            )
        }
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
        try parseGPUSection(output)
    }

    static func parseSnapshot(_ output: String) throws -> [GPUReading] {
        let gpuSection = section(named: nil, from: output)
        let processSection = section(named: processSectionSeparator, from: output)
        let psSection = section(named: psSectionSeparator, from: output)

        let gpus = try parseGPUSection(gpuSection)
        let processes = try parseProcessSection(processSection)
        let processDetails = try parsePSSection(psSection)

        let processDetailsByPID = Dictionary(uniqueKeysWithValues: processDetails.map { ($0.pid, $0) })
        let enrichedProcesses = processes.map { process in
            let details = processDetailsByPID[process.pid]
            return GPUProcessReading(
                gpuUUID: process.gpuUUID,
                pid: process.pid,
                processName: process.processName,
                usedGPUMemoryMB: process.usedGPUMemoryMB,
                user: details?.user,
                commandLine: details?.commandLine
            )
        }

        guard !enrichedProcesses.isEmpty else {
            return gpus
        }

        let processesByGPU = Dictionary(grouping: enrichedProcesses, by: \.gpuUUID)
        return gpus.map { gpu in
            GPUReading(
                index: gpu.index,
                name: gpu.name,
                uuid: gpu.uuid,
                utilization: gpu.utilization,
                memoryUsedMB: gpu.memoryUsedMB,
                memoryTotalMB: gpu.memoryTotalMB,
                temperatureCelsius: gpu.temperatureCelsius,
                processes: gpu.uuid.flatMap { processesByGPU[$0] } ?? []
            )
        }
    }

    private static func parseGPUSection(_ output: String) throws -> [GPUReading] {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        guard !lines.isEmpty else {
            throw FetchError.emptyResponse
        }

        return try lines.map(parseLine(_:)).sorted { $0.index < $1.index }
    }

    private static func parseProcessSection(_ output: String) throws -> [GPUProcessReading] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parseProcessLine(_:))
    }

    private static func parsePSSection(_ output: String) throws -> [RemoteProcessStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parsePSLine(_:))
    }

    private func runSSHCommand(
        settings: AppSettings,
        remoteCommand: String,
        password: String?,
        allowEmptyOutput: Bool = false
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let trimmedPassword = password?.trimmingCharacters(in: .newlines)
            let askPassScriptURL: URL?

            if let trimmedPassword, !trimmedPassword.isEmpty {
                askPassScriptURL = try Self.createAskPassScript()
            } else {
                askPassScriptURL = nil
            }

            defer {
                if let askPassScriptURL {
                    try? FileManager.default.removeItem(at: askPassScriptURL)
                }
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.buildSSHArguments(
                settings: settings,
                prefersPasswordAuth: !(trimmedPassword?.isEmpty ?? true),
                remoteCommand: remoteCommand
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            if let askPassScriptURL, let trimmedPassword {
                process.environment = ProcessInfo.processInfo.environment.merging(
                    [
                        "SSH_ASKPASS": askPassScriptURL.path,
                        "SSH_ASKPASS_REQUIRE": "force",
                        "GPUUSAGE_SSH_PASSWORD": trimmedPassword,
                        "DISPLAY": "gpuusage:0",
                    ],
                    uniquingKeysWith: { _, newValue in newValue }
                )
            }

            try process.run()
            process.waitUntilExit()

            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw FetchError.commandFailed(process.terminationStatus, stderr.isEmpty ? stdout : stderr)
            }

            guard allowEmptyOutput || !stdout.isEmpty else {
                throw FetchError.emptyResponse
            }

            return stdout
        }.value
    }

    private static func buildSSHArguments(
        settings: AppSettings,
        prefersPasswordAuth: Bool,
        remoteCommand: String
    ) -> [String] {
        var arguments = [
            "-o", "ConnectTimeout=5",
        ]

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

    private static func parseLine(_ line: String) throws -> GPUReading {
        let columns = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let index = Int(columns.first ?? "") else {
            throw FetchError.invalidOutput(line)
        }

        if columns.count >= 7 {
            return GPUReading(
                index: index,
                name: columns[1],
                uuid: columns[2],
                utilization: Int(columns[3]) ?? 0,
                memoryUsedMB: Int(columns[4]) ?? 0,
                memoryTotalMB: Int(columns[5]) ?? 0,
                temperatureCelsius: columns[6] == "N/A" ? nil : Int(columns[6]),
                processes: []
            )
        }

        guard columns.count >= 6 else {
            throw FetchError.invalidOutput(line)
        }

        return GPUReading(
            index: index,
            name: columns[1],
            uuid: nil,
            utilization: Int(columns[2]) ?? 0,
            memoryUsedMB: Int(columns[3]) ?? 0,
            memoryTotalMB: Int(columns[4]) ?? 0,
            temperatureCelsius: columns[5] == "N/A" ? nil : Int(columns[5]),
            processes: []
        )
    }

    private static func parseProcessLine(_ line: String) throws -> GPUProcessReading {
        let columns = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard columns.count >= 4, let pid = Int(columns[1]) else {
            throw FetchError.invalidProcessOutput(line)
        }

        return GPUProcessReading(
            gpuUUID: columns[0],
            pid: pid,
            processName: columns[2],
            usedGPUMemoryMB: Int(columns[3]) ?? 0,
            user: nil,
            commandLine: nil
        )
    }

    private static func buildSummaryRemoteCommand(summaryCommand: String) -> String {
        """
        \(summaryCommand)
        printf '\\n\(processSectionSeparator)\\n'
        process_output="$(\(processDetailsCommand) 2>/dev/null || true)"
        printf '%s\\n' "$process_output"
        """
    }

    private static func buildPSLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    private static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func createAskPassScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gpuusage-askpass-\(UUID().uuidString).sh")
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

    private static func section(named name: String?, from output: String) -> String {
        let separators = [processSectionSeparator, psSectionSeparator]

        if let name {
            guard let startRange = output.range(of: name) else {
                return ""
            }

            let contentStart = startRange.upperBound
            let nextRange = separators
                .filter { $0 != name }
                .compactMap { separator -> Range<String.Index>? in
                    output.range(of: separator, range: contentStart..<output.endIndex)
                }
                .min { $0.lowerBound < $1.lowerBound }

            let sectionRange = contentStart..<(nextRange?.lowerBound ?? output.endIndex)
            return String(output[sectionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let firstSeparatorRange = separators
            .compactMap { separator in output.range(of: separator) }
            .min { $0.lowerBound < $1.lowerBound }

        let endIndex = firstSeparatorRange?.lowerBound ?? output.endIndex
        return String(output[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsePSLine(_ line: String) throws -> RemoteProcessStatus {
        let columns = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)

        guard columns.count >= 2, let pid = Int(columns[0]) else {
            throw FetchError.invalidPSOutput(line)
        }

        let commandLine = columns.count == 3 ? String(columns[2]) : nil
        return RemoteProcessStatus(
            pid: pid,
            user: String(columns[1]),
            commandLine: commandLine
        )
    }
}
