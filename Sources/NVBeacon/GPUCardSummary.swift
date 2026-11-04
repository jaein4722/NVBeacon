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
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { identity; status }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    identity
                    Spacer(minLength: 2)
                    status.fixedSize(horizontal: true, vertical: false)
                }
            }
#endif
#if os(iOS)
            let horizontal = AnyLayout(GPUMetricColumns())
#else
            let horizontal = AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
#endif
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7)) : horizontal
            layout {
                ThinMetricBar(title: "Util", valueText: "\(gpu.utilization)%", ratio: gpu.utilizationRatio,
                              tint: Color(red: 0.93, green: 0.45, blue: 0.15))
                ThinMetricBar(title: memoryLabel, valueText: "\(gpu.memoryUsagePercent)% · \(gpu.memoryUsedMB)/\(gpu.memoryTotalMB)MB",
                              ratio: gpu.memoryUsageRatio, tint: Color(red: 0.12, green: 0.54, blue: 0.94),
                              compactValue: compactMemory)
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

    private var compactMemory: String {
        func gib(_ mib: Int) -> String {
            (Double(mib) / 1024).formatted(.number.precision(.fractionLength(0...1)))
        }
        return "\(gpu.memoryUsagePercent)% · \(gib(gpu.memoryUsedMB))/\(gib(gpu.memoryTotalMB)) GiB"
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

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(gpu.temperatureSummary) · \(gpu.processes.count)p · \(gpu.utilization)%")
#if os(iOS)
                .font(.caption2.weight(.semibold)).monospacedDigit()
#else
                .font(.caption.weight(.semibold)).monospacedDigit()
#endif
            if mine {
                badge.font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.green.opacity(0.12), in: Capsule())
            }
            if expandable {
                Image(systemName: expanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(expanded ? Color.orange : .secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

#if os(iOS)
/// The two tracks share one scale, regardless of the length of the counter labels.
private struct GPUMetricColumns: Layout {
    private let gap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (2 * (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) + gap)
        let column = ProposedViewSize(width: max(0, width - gap) / 2, height: nil)
        return CGSize(width: width, height: subviews.map { $0.sizeThatFits(column).height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = max(0, bounds.width - gap) / 2
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + gap), y: bounds.maxY),
                       anchor: .bottomLeading, proposal: .init(width: width, height: nil))
        }
    }
}
#endif

extension View {
    func gpuCardSurface(mine: Bool, expanded: Bool) -> some View {
#if os(macOS)
        let background = Color(nsColor: .controlBackgroundColor)
#else
        let background = Color(uiColor: .secondarySystemGroupedBackground)
#endif
        return self.padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((mine ? Color.green.opacity(0.08) : background), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
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
    var compactValue: String? = nil

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
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: valueText).fixedSize()
                    Text(verbatim: compactValue ?? valueText).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(.caption2.monospacedDigit())
                    .accessibilityLabel(valueText)
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
