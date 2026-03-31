import Foundation

struct SSHMetricsFetcher: Sendable {
    static let processDetailsCommand = "nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
    private static let processSectionSeparator = "__GPUUSAGE_PROCESS_SECTION__"

    enum FetchError: LocalizedError, Equatable {
        case commandFailed(Int32, String)
        case emptyResponse
        case invalidOutput(String)
        case invalidProcessOutput(String)
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
            case .missingTarget:
                return "SSH target is missing."
            }
        }
    }

    func fetch(settings: AppSettings) async throws -> GPUSnapshot {
        let normalized = settings.normalized()
        guard normalized.isConfigured else {
            throw FetchError.missingTarget
        }

        let output = try await runSSHCommand(settings: normalized)
        let gpus = try Self.parseSnapshot(output)
        return GPUSnapshot(takenAt: Date(), gpus: gpus)
    }

    static func parse(_ output: String) throws -> [GPUReading] {
        try parseGPUSection(output)
    }

    static func parseSnapshot(_ output: String) throws -> [GPUReading] {
        let gpuSection: String
        let processSection: String

        if let separatorRange = output.range(of: processSectionSeparator) {
            gpuSection = String(output[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            processSection = String(output[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            gpuSection = output
            processSection = ""
        }

        let gpus = try parseGPUSection(gpuSection)
        let processes = try parseProcessSection(processSection)

        guard !processes.isEmpty else {
            return gpus
        }

        let processesByGPU = Dictionary(grouping: processes, by: \.gpuUUID)
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

    private func runSSHCommand(settings: AppSettings) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.buildSSHArguments(settings: settings)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw FetchError.commandFailed(process.terminationStatus, stderr.isEmpty ? stdout : stderr)
            }

            guard !stdout.isEmpty else {
                throw FetchError.emptyResponse
            }

            return stdout
        }.value
    }

    private static func buildSSHArguments(settings: AppSettings) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]

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
            shellQuoted(buildCombinedRemoteCommand(summaryCommand: settings.remoteCommand)),
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
            usedGPUMemoryMB: Int(columns[3]) ?? 0
        )
    }

    private static func buildCombinedRemoteCommand(summaryCommand: String) -> String {
        [
            summaryCommand,
            "printf '\\n\(processSectionSeparator)\\n'",
            "\(processDetailsCommand) 2>/dev/null || true",
        ].joined(separator: "; ")
    }

    private static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
