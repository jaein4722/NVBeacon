import Foundation

struct NetworkInterfaceReading: Identifiable, Equatable, Sendable {
    let name: String
    let receivedBytes: UInt64
    let transmittedBytes: UInt64

    var id: String { name }
}

struct NetworkSample: Equatable, Sendable {
    let takenAt: Date
    let interfaces: [NetworkInterfaceReading]

    var receivedBytes: UInt64 {
        interfaces.reduce(0) { $0 + $1.receivedBytes }
    }

    var transmittedBytes: UInt64 {
        interfaces.reduce(0) { $0 + $1.transmittedBytes }
    }
}

struct NetworkUsage: Equatable, Sendable {
    /// `nil` until two samples are far enough apart to measure a rate.
    let receivedBytesPerSecond: Double?
    let transmittedBytesPerSecond: Double?
    let totalReceivedBytes: UInt64
    let totalTransmittedBytes: UInt64
    let interfaces: [NetworkInterfaceReading]
    let sampledAt: Date

    var hasRates: Bool {
        receivedBytesPerSecond != nil && transmittedBytesPerSecond != nil
    }

    var interfaceNames: [String] {
        interfaces.map(\.name)
    }

    var rateSummary: String {
        "↓ \(NetworkUsageFormatter.rateText(receivedBytesPerSecond)) ↑ \(NetworkUsageFormatter.rateText(transmittedBytesPerSecond))"
    }

    var totalSummary: String {
        "↓ \(NetworkUsageFormatter.byteCountText(totalReceivedBytes)) ↑ \(NetworkUsageFormatter.byteCountText(totalTransmittedBytes))"
    }
}

enum NetworkUsageEvaluator {
    /// Compares two cumulative counter samples and derives a transfer rate.
    ///
    /// - Parameters:
    ///   - previous: The previously captured sample, if any.
    ///   - current: The newest sample.
    ///   - maximumInterval: Samples further apart than this are treated as a fresh baseline,
    ///     because averaging over a long gap (sleep, paused polling) is misleading.
    static func usage(
        previous: NetworkSample?,
        current: NetworkSample,
        maximumInterval: TimeInterval
    ) -> NetworkUsage? {
        guard !current.interfaces.isEmpty else { return nil }

        var receivedBytesPerSecond: Double?
        var transmittedBytesPerSecond: Double?

        if let previous, !previous.interfaces.isEmpty {
            let interval = current.takenAt.timeIntervalSince(previous.takenAt)

            if interval > 0, interval <= maximumInterval {
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

enum NetworkUsageFormatter {
    static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return "--"
        }

        return "\(valueText(bytesPerSecond))/s"
    }

    static func byteCountText(_ bytes: UInt64) -> String {
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
