import Foundation

/// Effective collection choices. Disabled metrics never add commands to the SSH poll.
public struct HostMetricsOptions: Equatable, Sendable {
    public let cpu: Bool
    public let memory: Bool
    public let network: Bool

    public init(cpu: Bool = true, memory: Bool = true, network: Bool = true) {
        self.cpu = cpu
        self.memory = memory
        self.network = network
    }

    public static let none = HostMetricsOptions(cpu: false, memory: false, network: false)
    public var isEmpty: Bool { !cpu && !memory && !network }
}

public struct HostCPUSample: Equatable, Sendable {
    public let takenAt: Date
    public let total: UInt64
    public let idle: UInt64
    public let bootTime: UInt64?

    public init(takenAt: Date, total: UInt64, idle: UInt64, bootTime: UInt64? = nil) {
        self.takenAt = takenAt
        self.total = total
        self.idle = idle
        self.bootTime = bootTime
    }
}

/// Uses the contributor's aggregate CPU counter calculation across ordinary polls.
public enum CPUUsageEvaluator {
    public static func usage(previous: HostCPUSample?, current: HostCPUSample,
                             maximumInterval: TimeInterval, minimumInterval: TimeInterval = 1) -> Int? {
        guard let previous else { return nil }
        let interval = current.takenAt.timeIntervalSince(previous.takenAt)
        guard interval > 0, interval >= minimumInterval, interval <= maximumInterval,
              current.bootTime == previous.bootTime,
              current.total > previous.total, current.idle >= previous.idle else { return nil }
        let total = current.total - previous.total
        let idle = current.idle - previous.idle
        guard idle <= total else { return nil }
        return Int((100 * Double(total - idle) / Double(total)).rounded())
    }
}
