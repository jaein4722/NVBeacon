import AppKit
import Foundation

struct Arguments {
    let outputPath: String
    let appName: String

    init() throws {
        var outputPath: String?
        var appName = "NVBeacon"

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                outputPath = iterator.next()
            case "--app-name":
                if let value = iterator.next() {
                    appName = value
                }
            default:
                continue
            }
        }

        guard let outputPath else {
            throw NSError(
                domain: "GenerateDMGBackground",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing required --output argument."]
            )
        }

        self.outputPath = outputPath
        self.appName = appName
    }
}

let arguments = try Arguments()
let canvasSize = NSSize(width: 720, height: 440)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    throw NSError(
        domain: "GenerateDMGBackground",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap image rep."]
    )
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    throw NSError(
        domain: "GenerateDMGBackground",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create drawing context."]
    )
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawText(
    _ string: String,
    font: NSFont,
    color: NSColor,
    in rect: NSRect,
    alignment: NSTextAlignment = .center
) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let backgroundRect = NSRect(origin: .zero, size: canvasSize)
let gradient = NSGradient(colors: [
    color(246, 249, 245),
    color(232, 241, 233),
])!
gradient.draw(in: backgroundRect, angle: -90)

color(63, 123, 74, 0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: -90, y: 240, width: 290, height: 290)).fill()
NSBezierPath(ovalIn: NSRect(x: 510, y: 250, width: 240, height: 240)).fill()

let cardRect = NSRect(x: 36, y: 36, width: 648, height: 368)
let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 28, yRadius: 28)
color(255, 255, 255, 0.82).setFill()
cardPath.fill()

color(177, 198, 180, 0.55).setStroke()
cardPath.lineWidth = 1.2
cardPath.stroke()

let appHaloRect = NSRect(x: 98, y: 126, width: 180, height: 180)
let appHaloPath = NSBezierPath(ovalIn: appHaloRect)
color(74, 163, 92, 0.10).setFill()
appHaloPath.fill()

let applicationsHaloRect = NSRect(x: 442, y: 126, width: 180, height: 180)
let applicationsHaloPath = NSBezierPath(ovalIn: applicationsHaloRect)
color(74, 163, 92, 0.08).setFill()
applicationsHaloPath.fill()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 268, y: 216))
arrow.curve(
    to: NSPoint(x: 468, y: 216),
    controlPoint1: NSPoint(x: 330, y: 216),
    controlPoint2: NSPoint(x: 406, y: 216)
)
color(64, 148, 83, 0.85).setStroke()
arrow.lineWidth = 8
arrow.lineCapStyle = .round
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 468, y: 216))
arrowHead.line(to: NSPoint(x: 440, y: 234))
arrowHead.move(to: NSPoint(x: 468, y: 216))
arrowHead.line(to: NSPoint(x: 440, y: 198))
arrowHead.lineWidth = 8
arrowHead.lineCapStyle = .round
arrowHead.stroke()

drawText(
    "Drag the app into Applications",
    font: .systemFont(ofSize: 28, weight: .semibold),
    color: color(35, 46, 37),
    in: NSRect(x: 120, y: 308, width: 480, height: 36)
)

let footnote = "Menu bar monitoring for remote NVIDIA GPUs over SSH"
drawText(
    footnote,
    font: .systemFont(ofSize: 14, weight: .regular),
    color: color(114, 128, 116),
    in: NSRect(x: 120, y: 62, width: 480, height: 20)
)

NSGraphicsContext.restoreGraphicsState()

let outputURL = URL(fileURLWithPath: arguments.outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    throw NSError(
        domain: "GenerateDMGBackground",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG output."]
    )
}

try pngData.write(to: outputURL)
