import SwiftUI
import NVBeaconCore

/// Shared by the Mac popover and the iOS server detail.
struct GPUCardSummary: View {
    let gpu: NVBeaconCore.GPUReading
    let mine: Bool
    let badge: Text
    let expanded: Bool
    let expandable: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
#if os(macOS)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                identity
                Spacer(minLength: 8)
                status
            }
#else
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    identity
                    Spacer(minLength: 4)
                    disclosureIcon
                }
                status
            }
#endif
#if os(iOS)
            let layout = VStackLayout(alignment: .leading, spacing: 6)
#else
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
#endif
            layout {
                ThinMetricBar(title: "Util", valueText: "\(gpu.utilization)%", ratio: gpu.utilizationRatio,
                              tint: Color(red: 0.93, green: 0.45, blue: 0.15))
                ThinMetricBar(title: memoryLabel, valueText: memoryValue,
                              ratio: gpu.memoryUsageRatio, tint: Color(red: 0.12, green: 0.54, blue: 0.94))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var memoryLabel: String {
#if os(iOS)
        "VRAM"
#else
        "Memory"
#endif
    }

    private var memoryValue: String {
#if os(iOS)
        let total = GPUCapacityText.format(gpu.memoryTotalMB)
        let used = GPUCapacityText.format(gpu.memoryUsedMB)
        let sameUnit = used.unit == total.unit
        return "\(gpu.memoryUsagePercent)% · \(used.value)\(sameUnit ? "" : " " + used.unit) / \(total.value) \(total.unit)"
#else
        return "\(gpu.memoryUsagePercent)% · \(gpu.memoryUsedMB)/\(gpu.memoryTotalMB)MB"
#endif
    }

    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
#if os(iOS)
            Text("GPU \(gpu.index)").font(.subheadline.bold()).fixedSize()
            Text(gpu.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
#else
            Text("GPU \(gpu.index)").font(.headline).fixedSize()
            Text(gpu.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
#endif
        }
    }

    @ViewBuilder private var disclosureIcon: some View {
        if expandable {
            Image(systemName: expanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(expanded ? Color.orange : .secondary)
                .accessibilityHidden(true)
        }
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
#if os(iOS)
            if let temperature = gpu.temperatureCelsius {
                Label {
                    Text(verbatim: "\(temperature)°C")
                } icon: {
                    Image(systemName: "thermometer.medium")
                }
                .accessibilityLabel(Text("Temperature: \(temperature)°C"))
            }
            Label {
                Text(gpu.processes.count, format: .number)
            } icon: {
                Image(systemName: "list.bullet.rectangle")
            }
            .accessibilityLabel(Text("\(gpu.processes.count) processes"))
#else
            Text(verbatim: "\(gpu.temperatureSummary) · \(gpu.processes.count)p · \(gpu.utilization)%")
                .font(.caption.weight(.semibold)).monospacedDigit()
#endif
            if mine {
                badge.font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 6)
#if os(macOS)
                    .padding(.vertical, 2)
#endif
                    .background(.green.opacity(0.12), in: Capsule())
            }
#if os(macOS)
            disclosureIcon
#endif
        }
#if os(iOS)
        .font(.caption2.weight(.medium)).monospacedDigit()
        .foregroundStyle(.secondary)
#endif
    }
}

#if os(iOS)
enum GPUCapacityText {
    static func format(_ mib: Int) -> (value: String, unit: String) {
        guard mib >= 1024 else { return (mib.formatted(), "MiB") }
        return ((Double(mib) / 1024).formatted(.number.precision(.fractionLength(0...1))), "GiB")
    }
}

#endif

extension View {
    func gpuCardSurface(mine: Bool, expanded: Bool) -> some View {
#if os(macOS)
        let corner: CGFloat = 14
        let background = Color(nsColor: .controlBackgroundColor)
#else
        let corner: CGFloat = 12
        let background = Color(uiColor: .secondarySystemGroupedBackground)
#endif
        return self.padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((mine ? Color.green.opacity(0.08) : background), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(expanded ? Color.orange.opacity(0.42) : mine ? .green.opacity(0.26) : .primary.opacity(0.05))
                    .allowsHitTesting(false)
            }
    }
}

struct ThinMetricBar: View {
    let title: String
    let valueText: String
    let ratio: Double
    let tint: Color

    private var clampedRatio: Double {
        min(max(ratio, .zero), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary).fixedSize()

                Spacer(minLength: 4)

#if os(iOS)
                Text(verbatim: valueText).font(.caption2.monospacedDigit())
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
#else
                Text(valueText).font(.caption2.monospacedDigit()).lineLimit(1)
#endif
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))

                    if clampedRatio > 0 {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.72), tint],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
#if os(iOS)
                            .frame(width: proxy.size.width * clampedRatio)
#else
                            .frame(width: max(8, proxy.size.width * clampedRatio))
#endif
                    }
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
