import Foundation

public enum MetricsParseError: Error, Equatable, Sendable {
    case emptyResponse
    case invalidOutput(String)
    case invalidProcessOutput(String)
    case invalidPSOutput(String)
}

public enum MetricsParser {
    private static let processSectionSeparator = RemoteMetricCommands.processSectionSeparator
    private static let psSectionSeparator = RemoteMetricCommands.psSectionSeparator
    private static let cpuSectionSeparator = RemoteMetricCommands.cpuSectionSeparator
    private static let networkSectionSeparator = RemoteMetricCommands.networkSectionSeparator
    private static let memorySectionSeparator = RemoteMetricCommands.memorySectionSeparator

    public static func parse(_ output: String) throws -> [GPUReading] {
        try parseGPUSection(output)
    }

    public static func parseSnapshot(_ output: String) throws -> [GPUReading] {
        let gpuSection = section(named: nil, from: output)
        let processSection = section(named: processSectionSeparator, from: output)
        let psSection = section(named: psSectionSeparator, from: output)

        let gpus = try parseGPUSection(gpuSection)
        let processes = try parseProcessSection(processSection)
        let processDetails = try parsePSSection(psSection)

        let processDetailsByPID = Dictionary(processDetails.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        let enrichedProcesses = processes.map { process in
            let details = processDetailsByPID[process.pid]
            return GPUProcessReading(
                gpuUUID: process.gpuUUID,
                pid: process.pid,
                processName: process.processName,
                usedGPUMemoryMB: process.usedGPUMemoryMB,
                userID: process.userID,
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

    public static func parseHostCPU(_ output: String) -> Int? {
        let lines = section(named: cpuSectionSeparator, from: output).split(whereSeparator: \.isNewline)
        guard lines.count == 2 else { return nil }
        guard let first = cpuCounters(lines[0]), let second = cpuCounters(lines[1]),
              second.total > first.total, second.idle >= first.idle else { return nil }
        let total = second.total - first.total
        let idle = second.idle - first.idle
        guard idle <= total else { return nil }
        return Int((100 * Double(total - idle) / Double(total)).rounded())
    }

    private static func cpuCounters(_ line: Substring) -> (total: UInt64, idle: UInt64)? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 5, fields[0] == "cpu" else { return nil }
        let numbers = fields.dropFirst().prefix(8).compactMap { UInt64($0) }
        guard numbers.count == min(fields.count - 1, 8), numbers.count >= 4 else { return nil }
        var total: UInt64 = 0
        for number in numbers {
            let (sum, overflow) = total.addingReportingOverflow(number)
            guard !overflow else { return nil }
            total = sum
        }
        let (idle, overflow) = numbers[3].addingReportingOverflow(numbers.count > 4 ? numbers[4] : 0)
        guard !overflow else { return nil }
        return (total, idle)
    }

    public static func parseHostCPUSample(_ output: String, takenAt: Date) -> HostCPUSample? {
        let lines = section(named: cpuSectionSeparator, from: output).split(whereSeparator: \.isNewline)
        let cpuLines = lines.filter { $0.split(whereSeparator: \.isWhitespace).first == "cpu" }
        guard cpuLines.count == 1, let counters = cpuCounters(cpuLines[0]) else { return nil }
        let bootLines = lines.filter { $0.split(whereSeparator: \.isWhitespace).first == "btime" }
        guard bootLines.count <= 1 else { return nil }
        var bootTime: UInt64?
        if let bootLine = bootLines.first {
            let fields = bootLine.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let value = UInt64(fields[1]) else { return nil }
            bootTime = value
        }
        return HostCPUSample(takenAt: takenAt, total: counters.total, idle: counters.idle, bootTime: bootTime)
    }

    public static func networkSection(_ output: String) -> String {
        section(named: networkSectionSeparator, from: output)
    }

    public static func parseNetworkSection(_ output: String) -> [NetworkInterfaceReading] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)

                guard
                    columns.count >= 3,
                    let receivedBytes = UInt64(columns[1]),
                    let transmittedBytes = UInt64(columns[2])
                else {
                    return nil
                }

                return NetworkInterfaceReading(
                    name: String(columns[0]),
                    receivedBytes: receivedBytes,
                    transmittedBytes: transmittedBytes
                )
            }
    }

    public static func parseHostMemory(_ output: String) -> HostMemoryReading? {
        let memorySection = section(named: memorySectionSeparator, from: output)
        let keys: Set<String> = ["MemTotal", "MemAvailable", "SwapTotal", "SwapFree"]
        var values = [String: Int]()
        for line in memorySection.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[2] == "kB" else { continue }
            let key = String(fields[0].dropLast())
            guard fields[0].hasSuffix(":"), keys.contains(key) else { continue }
            guard let value = Int(fields[1]), value >= 0 else {
                if key == "MemTotal" || key == "MemAvailable" { return nil }
                continue
            }
            guard values[key] == nil else { return nil }
            values[key] = value
        }

        // MemFree alone excludes reclaimable cache and can exaggerate OOM risk.
        guard let total = values["MemTotal"], total > 0,
              let available = values["MemAvailable"], available <= total else { return nil }
        let swapTotal = values["SwapTotal"]
        let swapFree = values["SwapFree"]
        let validSwap: Bool
        if let swapTotal, let swapFree {
            validSwap = swapFree <= swapTotal
        } else {
            validSwap = false
        }
        return HostMemoryReading(
            totalKiB: total,
            availableKiB: available,
            swapTotalKiB: validSwap ? swapTotal : nil,
            swapFreeKiB: validSwap ? swapFree : nil
        )
    }

    private static func parseGPUSection(_ output: String) throws -> [GPUReading] {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        guard !lines.isEmpty else {
            throw MetricsParseError.emptyResponse
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

    public static func parsePSSection(_ output: String) throws -> [RemoteProcessStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parsePSLine(_:))
    }

    public static func parseDetailedPSSection(_ output: String) throws -> [RemoteProcessStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0) }

        return try lines.map(parseDetailedPSLine(_:))
    }

    private static func parseLine(_ line: String) throws -> GPUReading {
        let columns = line
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let index = Int(columns.first ?? "") else {
            throw MetricsParseError.invalidOutput(line)
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
            throw MetricsParseError.invalidOutput(line)
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
            throw MetricsParseError.invalidProcessOutput(line)
        }

        let hasUIDColumn = columns.count >= 5
        return GPUProcessReading(
            gpuUUID: columns[0],
            pid: pid,
            processName: hasUIDColumn ? columns[3] : columns[2],
            usedGPUMemoryMB: Int(hasUIDColumn ? columns[4] : columns[3]) ?? 0,
            userID: hasUIDColumn ? Int(columns[2]) : nil,
            user: nil,
            commandLine: nil
        )
    }

    private static func section(named name: String?, from output: String) -> String {
        let separators = [processSectionSeparator, psSectionSeparator, memorySectionSeparator, cpuSectionSeparator, networkSectionSeparator, RemoteMetricCommands.hostSectionSeparator]

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
            throw MetricsParseError.invalidPSOutput(line)
        }

        let commandLine = columns.count == 3 ? String(columns[2]) : nil
        return RemoteProcessStatus(
            pid: pid,
            userID: nil,
            user: String(columns[1]),
            commandLine: commandLine
        )
    }

    private static func parseDetailedPSLine(_ line: String) throws -> RemoteProcessStatus {
        let columns = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)

        guard columns.count >= 3, let pid = Int(columns[0]) else {
            throw MetricsParseError.invalidPSOutput(line)
        }

        let commandLine = columns.count == 4 ? String(columns[3]) : nil
        return RemoteProcessStatus(
            pid: pid,
            userID: Int(columns[1]),
            user: String(columns[2]),
            commandLine: commandLine
        )
    }

}
