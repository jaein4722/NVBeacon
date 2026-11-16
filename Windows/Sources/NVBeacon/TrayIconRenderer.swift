import NVBeaconCore
import NVBeaconWindowsKit
import WinSDK

/// Draws the tray icon: one bar per GPU (or per server when there are many GPUs),
/// filled from the bottom by utilization. The tray cannot show text, so the bars
/// stand in for the macOS menu bar summary.
enum TrayIconRenderer {
    struct Bar {
        var ratio: Double
        var stale: Bool
    }

    static func bars(for states: [ServerState]) -> [Bar] {
        let gpuBars = states.flatMap { state in
            (state.snapshot?.gpus ?? []).map { Bar(ratio: $0.utilizationRatio, stale: state.lastError != nil) }
        }
        if gpuBars.count <= 8 { return gpuBars }
        return states.compactMap { state in
            state.snapshot.map { Bar(ratio: Double($0.averageUtilization) / 100, stale: state.lastError != nil) }
        }.prefix(8).map { $0 }
    }

    static func makeIcon(for states: [ServerState]) -> HICON? {
        let size = Int(max(16, GetSystemMetrics(SM_CXSMICON)))
        var pixels = [UInt32](repeating: 0, count: size * size)
        let bars = bars(for: states)
        let hasError = states.contains { $0.lastError != nil }

        let inset = max(1, size / 16)
        let gap = max(1, size / 16)
        let count = max(1, bars.count)
        let available = size - inset * 2
        let barWidth = max(1, (available - gap * (count - 1)) / count)
        var x = inset + (available - (barWidth * count + gap * (count - 1))) / 2
        let top = inset, bottom = size - inset

        for index in 0..<count {
            let bar = index < bars.count ? bars[index] : nil
            fill(&pixels, size: size, x: x, y: top, width: barWidth, height: bottom - top, color: argb(110, 128, 128, 128))
            if let bar {
                let height = Int((Double(bottom - top) * min(max(bar.ratio, 0), 1)).rounded())
                let alpha: UInt32 = bar.stale ? 140 : 255
                fill(&pixels, size: size, x: x, y: bottom - height, width: barWidth, height: height,
                     color: color(for: bar.ratio, alpha: alpha))
            }
            x += barWidth + gap
        }
        if hasError {
            let dot = max(4, size / 3)
            fill(&pixels, size: size, x: size - dot, y: 0, width: dot, height: dot, color: argb(255, 230, 57, 70))
        }
        return createIcon(pixels: pixels, size: size)
    }

    private static func color(for ratio: Double, alpha: UInt32) -> UInt32 {
        switch ratio {
        case ..<0.3: argb(alpha, 52, 199, 89)
        case ..<0.7: argb(alpha, 255, 176, 32)
        default: argb(alpha, 255, 69, 58)
        }
    }

    private static func argb(_ a: UInt32, _ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 {
        (a << 24) | (r << 16) | (g << 8) | b
    }

    private static func fill(_ pixels: inout [UInt32], size: Int, x: Int, y: Int, width: Int, height: Int, color: UInt32) {
        guard width > 0, height > 0 else { return }
        for row in max(0, y)..<min(size, y + height) {
            for column in max(0, x)..<min(size, x + width) {
                pixels[row * size + column] = color
            }
        }
    }

    private static func createIcon(pixels: [UInt32], size: Int) -> HICON? {
        var header = BITMAPINFO()
        header.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        header.bmiHeader.biWidth = LONG(size)
        header.bmiHeader.biHeight = -LONG(size)  // top-down rows
        header.bmiHeader.biPlanes = 1
        header.bmiHeader.biBitCount = 32
        header.bmiHeader.biCompression = DWORD(BI_RGB)

        let screen = GetDC(nil)
        defer { ReleaseDC(nil, screen) }
        var bits: UnsafeMutableRawPointer?
        guard let color = CreateDIBSection(screen, &header, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            return nil
        }
        defer { DeleteObject(color) }
        pixels.withUnsafeBytes { bits.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let mask = CreateBitmap(Int32(size), Int32(size), 1, 1, nil) else { return nil }
        defer { DeleteObject(mask) }
        var info = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
        return CreateIconIndirect(&info)
    }
}
