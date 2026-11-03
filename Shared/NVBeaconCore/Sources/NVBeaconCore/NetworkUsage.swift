import Foundation

public struct NetworkInterfaceReading: Identifiable, Equatable, Sendable {
    public init(name: String, receivedBytes: UInt64, transmittedBytes: UInt64) {
        self.name = name
        self.receivedBytes = receivedBytes
        self.transmittedBytes = transmittedBytes
    }

    public let name: String
    public let receivedBytes: UInt64
    public let transmittedBytes: UInt64

    public var id: String { name }
}

public struct NetworkSample: Equatable, Sendable {
    public init(takenAt: Date, interfaces: [NetworkInterfaceReading]) {
        self.takenAt = takenAt
        self.interfaces = interfaces
    }

    public let takenAt: Date
    public let interfaces: [NetworkInterfaceReading]

    public var receivedBytes: UInt64 {
        interfaces.reduce(0) { $0 + $1.receivedBytes }
    }

    public var transmittedBytes: UInt64 {
        interfaces.reduce(0) { $0 + $1.transmittedBytes }
    }
}

public struct NetworkUsage: Equatable, Sendable {
    /// `nil` until two samples are far enough apart to measure a rate.
    public let receivedBytesPerSecond: Double?
    public let transmittedBytesPerSecond: Double?
    public let totalReceivedBytes: UInt64
    public let totalTransmittedBytes: UInt64
    public let interfaces: [NetworkInterfaceReading]
    public let sampledAt: Date

    public var hasRates: Bool {
        receivedBytesPerSecond != nil && transmittedBytesPerSecond != nil
    }

    public var interfaceNames: [String] {
        interfaces.map(\.name)
    }

    public var rateSummary: String {
        "↓ \(NetworkUsageFormatter.rateText(receivedBytesPerSecond)) ↑ \(NetworkUsageFormatter.rateText(transmittedBytesPerSecond))"
    }

    public var totalSummary: String {
        "↓ \(NetworkUsageFormatter.byteCountText(totalReceivedBytes)) ↑ \(NetworkUsageFormatter.byteCountText(totalTransmittedBytes))"
    }
}

public enum NetworkUsageEvaluator {
    /// Compares two cumulative counter samples and derives a transfer rate.
    ///
    /// - Parameters:
    ///   - previous: The previously captured sample, if any.
    ///   - current: The newest sample.
    ///   - maximumInterval: Samples further apart than this are treated as a fresh baseline,
    ///     because averaging over a long gap (sleep, paused polling) is misleading.
    public static func usage(
        previous: NetworkSample?,
        current: NetworkSample,
        maximumInterval: TimeInterval,
        minimumInterval: TimeInterval = 1
    ) -> NetworkUsage? {
        guard !current.interfaces.isEmpty else { return nil }

        var receivedBytesPerSecond: Double?
        var transmittedBytesPerSecond: Double?

        if let previous, !previous.interfaces.isEmpty {
            let interval = current.takenAt.timeIntervalSince(previous.takenAt)

            if interval >= minimumInterval, interval > 0, interval <= maximumInterval {
                let previousByName = Dictionary(
                    previous.interfaces.map { ($0.name, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                var receivedDelta: UInt64 = 0
                var transmittedDelta: UInt64 = 0
                var matchedInterfaceCount = 0
                var countersAreConsistent = true

                for interface in current.interfaces {
                    guard let oldInterface = previousByName[interface.name] else { continue }

                    guard
                        interface.receivedBytes >= oldInterface.receivedBytes,
                        interface.transmittedBytes >= oldInterface.transmittedBytes
                    else {
                        countersAreConsistent = false
                        break
                    }

                    receivedDelta += interface.receivedBytes - oldInterface.receivedBytes
                    transmittedDelta += interface.transmittedBytes - oldInterface.transmittedBytes
                    matchedInterfaceCount += 1
                }

                if countersAreConsistent, matchedInterfaceCount > 0 {
                    receivedBytesPerSecond = Double(receivedDelta) / interval
                    transmittedBytesPerSecond = Double(transmittedDelta) / interval
                }
            }
        }

        return NetworkUsage(
            receivedBytesPerSecond: receivedBytesPerSecond,
            transmittedBytesPerSecond: transmittedBytesPerSecond,
            totalReceivedBytes: current.receivedBytes,
            totalTransmittedBytes: current.transmittedBytes,
            interfaces: current.interfaces,
            sampledAt: current.takenAt
        )
    }
}

public enum NetworkUsageFormatter {
    public static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return "--"
        }

        return "\(valueText(bytesPerSecond))/s"
    }

    public static func byteCountText(_ bytes: UInt64) -> String {
        valueText(Double(bytes))
    }

    private static func valueText(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(bytes, 0)
        var unitIndex = 0

        while value >= 1_000, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }

        guard unitIndex > 0 else {
            return "\(Int(value.rounded())) B"
        }

        let format = value >= 100 ? "%.0f %@" : "%.1f %@"
        return String(
            format: format,
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            units[unitIndex]
        )
    }
}
