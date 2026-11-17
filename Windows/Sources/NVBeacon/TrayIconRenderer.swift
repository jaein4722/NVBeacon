import Foundation
import NVBeaconCore
import NVBeaconWindowsKit
import WinSDK

/// Draws the tray icon. The tray cannot show text next to the icon like the macOS
/// menu bar, so the number (average utilization or busy GPU count) is drawn into
/// the icon itself, large and bold, on a badge tinted by load:
///
/// - Average + Busy: average utilization, with a strip along the bottom showing the
///   share of busy GPUs.
/// - Average Util / Busy Count: just that number.
/// - Icon Only: the app icon.
///
/// With "Color by load" off, the number is drawn without a badge in the taskbar's
/// text color. A red dot marks a server that failed its last refresh.
enum TrayIconRenderer {
    struct Summary: Equatable {
        /// Average utilization of every GPU with data, nil before the first data arrives.
        var average: Int?
        var busy: Int
        var total: Int
        var hasError: Bool
    }

    static func summary(for states: [ServerState], settings: WindowsSettings) -> Summary {
        let gpus = states.flatMap { $0.snapshot?.gpus ?? [] }
        let average = gpus.isEmpty ? nil : Int((Double(gpus.reduce(0) { $0 + $1.utilization }) / Double(gpus.count)).rounded())
        return Summary(average: average, busy: gpus.filter(settings.isBusy).count, total: gpus.count,
                       hasError: states.contains { $0.lastError != nil || $0.passwordRejected })
    }

    static func makeIcon(summary: Summary, style: TrayIconStyle, usesColor: Bool) -> HICON? {
        render(summary: summary, style: style, usesColor: usesColor, lightTaskbar: Theme.taskbarIsLight,
               size: Int(max(16, GetSystemMetrics(SM_CXSMICON)))).makeIcon()
    }

    static func render(summary: Summary, style: TrayIconStyle, usesColor: Bool, lightTaskbar: Bool, size: Int) -> Canvas {
        var canvas = Canvas(size: size)

        if style == .iconOnly, canvas.drawAppIcon() {
            if summary.hasError { canvas.drawErrorDot() }
            return canvas
        }

        let text: String
        let ratio: Double?
        switch style {
        case .busyOnly:
            text = summary.average == nil ? "–" : String(summary.busy)
            ratio = summary.total > 0 ? Double(summary.busy) / Double(summary.total) : nil
        case .averageAndBusy, .averageOnly, .iconOnly:
            // Icon Only falls back to the average when there is no app icon (development builds).
            text = summary.average.map(String.init) ?? (summary.hasError ? "!" : "–")
            ratio = summary.average.map { Double($0) / 100 }
        }
        let foreground: Pixel
        let badgeIsRed = usesColor && (ratio ?? 0) >= 0.7
        if usesColor {
            canvas.fillBadge(color: ratio.map(loadColor) ?? Pixel(r: 128, g: 128, b: 128))
            foreground = .white
        } else {
            foreground = lightTaskbar ? Pixel(r: 0, g: 0, b: 0) : .white
        }
        var textBottom = size
        if style == .averageAndBusy {
            let strip = max(2, size / 8)
            let inset = max(2, size / 6)
            let share = summary.total > 0 ? Double(summary.busy) / Double(summary.total) : 0
            canvas.drawStrip(x: inset, y: size - inset / 2 - strip, width: size - inset * 2, height: strip,
                             filled: share, color: foreground)
            textBottom = size - inset / 2 - strip
        }
        canvas.drawText(text, color: foreground, top: 0, bottom: textBottom)
        if summary.hasError { canvas.drawErrorDot(onRed: badgeIsRed) }
        return canvas
    }

    /// Development aid (`NVBeacon.exe --dump-tray-icons FOLDER`): every style at common
    /// tray sizes over a dark and a light taskbar, as one BMP sheet per size.
    static func dumpPreviews(to folder: String) {
        let samples = [
            Summary(average: 7, busy: 1, total: 21, hasError: false),
            Summary(average: 42, busy: 9, total: 21, hasError: false),
            Summary(average: 100, busy: 21, total: 21, hasError: true),
            Summary(average: nil, busy: 0, total: 0, hasError: false),
        ]
        let variants: [(TrayIconStyle, Bool)] = [(.averageAndBusy, true), (.averageOnly, true), (.busyOnly, true),
                                                 (.averageOnly, false), (.iconOnly, true)]
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for size in [16, 20, 24, 32] {
            let cell = size + 8
            var rows: [[UInt32]] = []
            for light in [false, true] {
                let background = light ? Pixel(r: 238, g: 238, b: 238) : Pixel(r: 32, g: 32, b: 32)
                for (style, color) in variants {
                    var row = [UInt32](repeating: 0, count: cell * samples.count * cell)
                    for (column, sample) in samples.enumerated() {
                        let canvas = render(summary: sample, style: style, usesColor: color, lightTaskbar: light, size: size)
                        for y in 0..<cell {
                            for x in 0..<cell {
                                var pixel = background
                                let ix = x - 4, iy = y - 4
                                if ix >= 0, iy >= 0, ix < size, iy < size {
                                    let top = canvas.pixels[iy * size + ix]
                                    pixel = Pixel(r: top.r * top.a + background.r * (1 - top.a),
                                                  g: top.g * top.a + background.g * (1 - top.a),
                                                  b: top.b * top.a + background.b * (1 - top.a))
                                }
                                row[y * cell * samples.count + column * cell + x] =
                                    (UInt32(pixel.r.rounded()) << 16) | (UInt32(pixel.g.rounded()) << 8) | UInt32(pixel.b.rounded())
                            }
                        }
                    }
                    rows.append(row)
                }
            }
            writeBMP(rows.flatMap { $0 }, width: cell * samples.count, height: cell * rows.count,
                     to: folder + "\\tray-\(size).bmp")
        }
    }

    private static func writeBMP(_ pixels: [UInt32], width: Int, height: Int, to path: String) {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let imageSize = UInt32(width * height * 4)
        data.append(contentsOf: Array("BM".utf8)); put32(54 + imageSize); put32(0); put32(54)
        put32(40); put32(UInt32(width)); put32(UInt32(bitPattern: Int32(-height))); put16(1); put16(32); put32(0)
        put32(imageSize); put32(2835); put32(2835); put32(0); put32(0)
        for pixel in pixels { put32(pixel) }
        FileManager.default.createFile(atPath: path, contents: data)
    }

    /// Green below 30 %, amber below 70 %, red above (the popover's bar colors).
    static func loadColor(_ ratio: Double) -> Pixel {
        switch ratio {
        case ..<0.3: Pixel(r: 36, g: 160, b: 72)
        case ..<0.7: Pixel(r: 214, g: 130, b: 0)
        default: Pixel(r: 220, g: 53, b: 45)
        }
    }

    struct Pixel: Equatable {
        var r: Double, g: Double, b: Double
        var a: Double = 1
        static let white = Pixel(r: 255, g: 255, b: 255)
    }

    /// Straight-alpha RGBA pixels, composited with "over".
    struct Canvas {
        let size: Int
        var pixels: [Pixel]

        init(size: Int) {
            self.size = size
            pixels = Array(repeating: Pixel(r: 0, g: 0, b: 0, a: 0), count: size * size)
        }

        mutating func blend(_ index: Int, _ color: Pixel, coverage: Double) {
            let alpha = color.a * coverage
            guard alpha > 0 else { return }
            let base = pixels[index]
            let outAlpha = alpha + base.a * (1 - alpha)
            guard outAlpha > 0 else { return }
            func mix(_ top: Double, _ bottom: Double) -> Double { (top * alpha + bottom * base.a * (1 - alpha)) / outAlpha }
            pixels[index] = Pixel(r: mix(color.r, base.r), g: mix(color.g, base.g), b: mix(color.b, base.b), a: outAlpha)
        }

        /// Rounded square over the whole icon, anti-aliased by 4×4 supersampling.
        mutating func fillBadge(color: Pixel) {
            let radius = Double(size) * 0.24
            let extent = Double(size)
            for y in 0..<size {
                for x in 0..<size {
                    var inside = 0
                    for sy in 0..<4 {
                        for sx in 0..<4 {
                            let px = Double(x) + (Double(sx) + 0.5) / 4, py = Double(y) + (Double(sy) + 0.5) / 4
                            let dx = max(radius - px, px - (extent - radius), 0)
                            let dy = max(radius - py, py - (extent - radius), 0)
                            if dx * dx + dy * dy <= radius * radius { inside += 1 }
                        }
                    }
                    blend(y * size + x, color, coverage: Double(inside) / 16)
                }
            }
        }

        mutating func drawStrip(x: Int, y: Int, width: Int, height: Int, filled: Double, color: Pixel) {
            let filledWidth = Double(width) * min(max(filled, 0), 1)
            for row in max(0, y)..<min(size, y + height) {
                for column in max(0, x)..<min(size, x + width) {
                    let covered = min(max(filledWidth - Double(column - x), 0), 1)
                    var track = color
                    track.a = 0.35
                    blend(row * size + column, track, coverage: 1)
                    blend(row * size + column, color, coverage: covered)
                }
            }
        }

        /// A red dot with a white ring at the top right; dark on a red badge so it still shows.
        mutating func drawErrorDot(onRed: Bool = false) {
            let diameter = Double(max(5, size * 9 / 32))
            let center = Double(size) - diameter / 2
            for y in 0..<size {
                for x in 0..<size {
                    var inside = 0, ring = 0
                    for sy in 0..<4 {
                        for sx in 0..<4 {
                            let px = Double(x) + (Double(sx) + 0.5) / 4 - center, py = Double(y) + (Double(sy) + 0.5) / 4 - (diameter / 2)
                            let distance = (px * px + py * py).squareRoot()
                            if distance <= diameter / 2 { ring += 1 }
                            if distance <= diameter / 2 - 1 { inside += 1 }
                        }
                    }
                    blend(y * size + x, Pixel(r: 255, g: 255, b: 255), coverage: Double(ring) / 16)
                    blend(y * size + x, onRed ? Pixel(r: 40, g: 20, b: 20) : Pixel(r: 230, g: 40, b: 40), coverage: Double(inside) / 16)
                }
            }
        }

        /// Draws `text` as large as fits between `top` and `bottom`, centered on the digits.
        mutating func drawText(_ text: String, color: Pixel, top: Int, bottom: Int) {
            guard let mask = Self.textMask(text, size: size, top: top, bottom: bottom) else { return }
            for index in 0..<pixels.count where mask[index] > 0 {
                blend(index, color, coverage: mask[index])
            }
        }

        /// A large GDI rendering of the text, scaled down by area averaging so small
        /// icons keep the glyphs' real shapes and spacing. Bahnschrift is Windows'
        /// condensed numeral face; three digits use its Condensed width. The scale comes
        /// from the height of a digit, so "–" and "!" sit where digits would.
        static func textMask(_ text: String, size: Int, top: Int, bottom: Int) -> [Double]? {
            let face = text.count >= 3 ? "Bahnschrift SemiBold Condensed" : "Bahnschrift SemiBold"
            guard let glyphs = render(text, face: face), let digit = render("8", face: face),
                  let digitBox = digit.inkBox else { return nil }
            let inkBox = glyphs.inkBox ?? digitBox
            let available = Double(bottom - top)
            let maxWidth = Double(size) * (text.count >= 3 ? 0.94 : 0.84)
            let scale = min(available * 0.74 / Double(digitBox.height), maxWidth / Double(inkBox.width))
            // Place the ink: centered horizontally, digit height centered vertically.
            let originX = (Double(size) - Double(inkBox.width) * scale) / 2 - Double(inkBox.minX) * scale
            let originY = Double(top) + (available - Double(digitBox.height) * scale) / 2 - Double(digitBox.minY) * scale
            var mask = [Double](repeating: 0, count: size * size)
            for y in 0..<size {
                let sourceTop = (Double(y) - originY) / scale, sourceBottom = (Double(y + 1) - originY) / scale
                for x in 0..<size {
                    let sourceLeft = (Double(x) - originX) / scale, sourceRight = (Double(x + 1) - originX) / scale
                    mask[y * size + x] = glyphs.average(left: sourceLeft, top: sourceTop, right: sourceRight, bottom: sourceBottom)
                }
            }
            return mask
        }

        struct Raster {
            let width: Int, height: Int
            let coverage: [Double]

            struct Box { let minX: Int, minY: Int, width: Int, height: Int }

            var inkBox: Box? {
                var minX = width, minY = height, maxX = -1, maxY = -1
                for y in 0..<height {
                    for x in 0..<width where coverage[y * width + x] > 0.25 {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
                return maxX < 0 ? nil : Box(minX: minX, minY: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            }

            /// Mean coverage over a rectangle in source pixels (partial pixels weighted).
            func average(left: Double, top: Double, right: Double, bottom: Double) -> Double {
                let x0 = max(0, Int(left.rounded(.down))), x1 = min(width - 1, Int(right.rounded(.up)) - 1)
                let y0 = max(0, Int(top.rounded(.down))), y1 = min(height - 1, Int(bottom.rounded(.up)) - 1)
                guard x0 <= x1, y0 <= y1 else { return 0 }
                var total = 0.0
                for y in y0...y1 {
                    let wy = min(Double(y + 1), bottom) - max(Double(y), top)
                    guard wy > 0 else { continue }
                    for x in x0...x1 {
                        let wx = min(Double(x + 1), right) - max(Double(x), left)
                        if wx > 0 { total += coverage[y * width + x] * wx * wy }
                    }
                }
                return min(1, total / ((right - left) * (bottom - top)))
            }
        }

        /// White antialiased text on black at 120 px, read back as coverage.
        static func render(_ text: String, face: String) -> Raster? {
            let em = 120
            let units = Array(text.utf16)
            let width = em * max(1, units.count) + em / 2, height = em * 3 / 2
            var header = BITMAPINFO()
            header.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            header.bmiHeader.biWidth = LONG(width)
            header.bmiHeader.biHeight = -LONG(height)
            header.bmiHeader.biPlanes = 1
            header.bmiHeader.biBitCount = 32
            header.bmiHeader.biCompression = DWORD(BI_RGB)
            guard let dc = CreateCompatibleDC(nil) else { return nil }
            defer { DeleteDC(dc) }
            var bits: UnsafeMutableRawPointer?
            guard let bitmap = CreateDIBSection(dc, &header, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else { return nil }
            defer { DeleteObject(bitmap) }
            let previousBitmap = SelectObject(dc, bitmap)
            defer { SelectObject(dc, previousBitmap) }
            memset(bits, 0, width * height * 4)
            guard let font = face.withCString(encodedAs: UTF16.self, {
                CreateFontW(-Int32(em), 0, 0, 0, 600, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS),
                            DWORD(CLIP_DEFAULT_PRECIS), DWORD(ANTIALIASED_QUALITY), DWORD(DEFAULT_PITCH), $0)
            }) else { return nil }
            defer { DeleteObject(font) }
            let previousFont = SelectObject(dc, font)
            defer { SelectObject(dc, previousFont) }
            SetBkMode(dc, TRANSPARENT)
            SetTextColor(dc, 0x00FF_FFFF)
            _ = units.withUnsafeBufferPointer { TextOutW(dc, Int32(em / 4), Int32(em / 8), $0.baseAddress, Int32(units.count)) }
            GdiFlush()
            let source = bits.assumingMemoryBound(to: UInt32.self)
            return Raster(width: width, height: height,
                          coverage: (0..<width * height).map { Double((source[$0] >> 8) & 0xFF) / 255 })
        }


        /// The packaged app icon (resource 1), drawn with its alpha. False in development builds.
        mutating func drawAppIcon() -> Bool {
            guard let icon = LoadImageW(GetModuleHandleW(nil), UnsafePointer<WCHAR>(bitPattern: 1), UINT(IMAGE_ICON),
                                        Int32(size), Int32(size), UINT(LR_DEFAULTCOLOR)) else { return false }
            let handle = HICON(OpaquePointer(icon))
            defer { DestroyIcon(handle) }
            var info = ICONINFO()
            guard GetIconInfo(handle, &info), let color = info.hbmColor else { return false }
            defer {
                DeleteObject(color)
                if let mask = info.hbmMask { DeleteObject(mask) }
            }
            var header = BITMAPINFO()
            header.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            header.bmiHeader.biWidth = LONG(size)
            header.bmiHeader.biHeight = -LONG(size)
            header.bmiHeader.biPlanes = 1
            header.bmiHeader.biBitCount = 32
            header.bmiHeader.biCompression = DWORD(BI_RGB)
            var raw = [UInt32](repeating: 0, count: size * size)
            guard let dc = GetDC(nil) else { return false }
            defer { ReleaseDC(nil, dc) }
            let lines = raw.withUnsafeMutableBytes { GetDIBits(dc, color, 0, UINT(size), $0.baseAddress, &header, UINT(DIB_RGB_COLORS)) }
            guard lines > 0 else { return false }
            for index in 0..<raw.count {
                let value = raw[index]
                let alpha = Double((value >> 24) & 0xFF) / 255
                guard alpha > 0 else { continue }
                // Icon bitmaps are premultiplied; undo that for the straight-alpha canvas.
                func channel(_ shift: UInt32) -> Double { min(255, Double((value >> shift) & 0xFF) / alpha) }
                blend(index, Pixel(r: channel(16), g: channel(8), b: channel(0), a: alpha), coverage: 1)
            }
            return true
        }

        func makeIcon() -> HICON? {
            let packed: [UInt32] = pixels.map { pixel in
                let a = UInt32((min(max(pixel.a, 0), 1) * 255).rounded())
                func channel(_ value: Double) -> UInt32 { UInt32(min(max(value, 0), 255).rounded()) }
                return (a << 24) | (channel(pixel.r) << 16) | (channel(pixel.g) << 8) | channel(pixel.b)
            }
            var header = BITMAPINFO()
            header.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
            header.bmiHeader.biWidth = LONG(size)
            header.bmiHeader.biHeight = -LONG(size)
            header.bmiHeader.biPlanes = 1
            header.bmiHeader.biBitCount = 32
            header.bmiHeader.biCompression = DWORD(BI_RGB)
            let screen = GetDC(nil)
            defer { ReleaseDC(nil, screen) }
            var bits: UnsafeMutableRawPointer?
            guard let color = CreateDIBSection(screen, &header, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else { return nil }
            defer { DeleteObject(color) }
            packed.withUnsafeBytes { bits.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            guard let mask = CreateBitmap(Int32(size), Int32(size), 1, 1, nil) else { return nil }
            defer { DeleteObject(mask) }
            var info = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color)
            return CreateIconIndirect(&info)
        }
    }
}
