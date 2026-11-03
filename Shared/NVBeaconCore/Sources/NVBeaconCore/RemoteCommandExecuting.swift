import Foundation

public struct RemoteCommandOutput: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitStatus: Int32

    public init(standardOutput: String, standardError: String, exitStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitStatus = exitStatus
    }
}

/// The platform owns connection setup, credentials, host-key verification and
/// cancellation. Core only requests a command on an already configured target.
public protocol RemoteCommandExecuting: Sendable {
    func execute(_ command: String) async throws -> RemoteCommandOutput
}

public enum MetricsCollectionError: Error, Equatable, Sendable {
    case commandFailed(Int32, String)
}

public struct MetricsCollector<Transport: RemoteCommandExecuting>: Sendable {
    public let transport: Transport
    public init(transport: Transport) { self.transport = transport }

    public func fetchSummary(
        gpuCommand: String = RemoteMetricCommands.defaultGPUCommand,
        memoryCommand: String = RemoteMetricCommands.defaultMemoryCommand,
        includesNetworkUsage: Bool = true,
        hostMetrics: HostMetricsOptions = .init()
    ) async throws -> GPUSnapshot {
        try Task.checkCancellation()
        let output = try await transport.execute(
            RemoteMetricCommands.summary(summaryCommand: gpuCommand, memoryCommand: memoryCommand,
                                         includesNetworkUsage: includesNetworkUsage, hostMetrics: hostMetrics)
        )
        try Task.checkCancellation()
        guard output.exitStatus == 0 else {
            throw MetricsCollectionError.commandFailed(
                output.exitStatus,
                output.standardError.isEmpty ? output.standardOutput : output.standardError
            )
        }
        let takenAt = Date()
        let interfaces = hostMetrics.network && includesNetworkUsage
            ? MetricsParser.parseNetworkSection(MetricsParser.networkSection(output.standardOutput)) : []
        return GPUSnapshot(
            takenAt: takenAt,
            gpus: try MetricsParser.parseSnapshot(output.standardOutput),
            hostMemory: hostMetrics.memory ? MetricsParser.parseHostMemory(output.standardOutput) : nil,
            hostCPU: hostMetrics.cpu ? MetricsParser.parseHostCPU(output.standardOutput) : nil,
            networkSample: interfaces.isEmpty ? nil : NetworkSample(takenAt: takenAt, interfaces: interfaces),
            hostCPUSample: hostMetrics.cpu ? MetricsParser.parseHostCPUSample(output.standardOutput, takenAt: takenAt) : nil
        )
    }
}
