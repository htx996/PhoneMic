#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources/macOS", isDirectory: true)
let iconset = resources.appendingPathComponent("PhoneMic.iconset", isDirectory: true)
let preview = root.appendingPathComponent("outputs/PhoneMicMac-icon-preview.png")
let iosAppIconSet = root.appendingPathComponent("Apps/iOS/PhoneMicIOS/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let iosPreview = root.appendingPathComponent("outputs/PhoneMicIOS-icon-preview.png")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iosAppIconSet, withIntermediateDirectories: true)

struct IconSize {
    let filename: String
    let points: CGFloat
    let scale: CGFloat

    var pixels: Int { Int(points * scale) }
}

let sizes: [IconSize] = [
    .init(filename: "icon_16x16.png", points: 16, scale: 1),
    .init(filename: "icon_16x16@2x.png", points: 16, scale: 2),
    .init(filename: "icon_32x32.png", points: 32, scale: 1),
    .init(filename: "icon_32x32@2x.png", points: 32, scale: 2),
    .init(filename: "icon_128x128.png", points: 128, scale: 1),
    .init(filename: "icon_128x128@2x.png", points: 128, scale: 2),
    .init(filename: "icon_256x256.png", points: 256, scale: 1),
    .init(filename: "icon_256x256@2x.png", points: 256, scale: 2),
    .init(filename: "icon_512x512.png", points: 512, scale: 1),
    .init(filename: "icon_512x512@2x.png", points: 512, scale: 2),
]

let iosSizes: [IconSize] = [
    .init(filename: "PhoneMicIcon-iphone-2020-2x.png", points: 20, scale: 2),
    .init(filename: "PhoneMicIcon-iphone-2020-3x.png", points: 20, scale: 3),
    .init(filename: "PhoneMicIcon-iphone-2929-2x.png", points: 29, scale: 2),
    .init(filename: "PhoneMicIcon-iphone-2929-3x.png", points: 29, scale: 3),
    .init(filename: "PhoneMicIcon-iphone-4040-2x.png", points: 40, scale: 2),
    .init(filename: "PhoneMicIcon-iphone-4040-3x.png", points: 40, scale: 3),
    .init(filename: "PhoneMicIcon-iphone-6060-2x.png", points: 60, scale: 2),
    .init(filename: "PhoneMicIcon-iphone-6060-3x.png", points: 60, scale: 3),
    .init(filename: "PhoneMicIcon-ios-marketing-10241024-1x.png", points: 1024, scale: 1),
]

func roundedRectPath(rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

func drawIcon(size: Int, fullBleed: Bool = false) -> NSBitmapImageRep {
    let canvas = CGFloat(size)
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        fatalError("Unable to create bitmap")
    }

    bitmap.size = NSSize(width: canvas, height: canvas)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create graphics context")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    (fullBleed ? NSColor(calibratedRed: 0.02, green: 0.47, blue: 0.96, alpha: 1) : NSColor.clear).setFill()
    NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

    let templateScale = canvas / 1024.0
    let iconInset = (fullBleed ? 0.0 : 100.0) * templateScale
    let iconExtent = (fullBleed ? 1024.0 : 824.0) * templateScale
    let cornerRadius = (fullBleed ? 0.0 : 185.0) * templateScale
    let shadowOffset = 20.0 * templateScale
    let iconRect = CGRect(
        x: iconInset,
        y: iconInset,
        width: iconExtent,
        height: iconExtent
    )

    let context = graphicsContext.cgContext
    context.saveGState()
    if !fullBleed {
        context.setShadow(
            offset: CGSize(width: 0, height: -shadowOffset),
            blur: 28.0 * templateScale,
            color: NSColor.black.withAlphaComponent(0.20).cgColor
        )
    }

    let basePath = roundedRectPath(rect: iconRect, radius: cornerRadius)
    context.addPath(basePath)
    context.clip()

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(calibratedRed: 0.08, green: 0.78, blue: 0.96, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.02, green: 0.47, blue: 0.96, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.03, green: 0.32, blue: 0.86, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0.0, 0.58, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.midX, y: iconRect.minY),
        options: []
    )

    context.restoreGState()

    context.saveGState()
    context.addPath(basePath)
    context.clip()

    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor.white.withAlphaComponent(0.34).cgColor,
            NSColor.white.withAlphaComponent(0.12).cgColor,
            NSColor.white.withAlphaComponent(0.00).cgColor,
        ] as CFArray,
        locations: [0.0, 0.42, 1.0]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.midX, y: iconRect.minY + iconRect.height * 0.20),
        options: []
    )

    let waveLineWidth = max(2, canvas * 0.033)
    let waveRect = CGRect(
        x: iconRect.minX + iconRect.width * 0.18,
        y: iconRect.minY + iconRect.height * 0.37,
        width: iconRect.width * 0.64,
        height: iconRect.height * 0.42
    )
    let waveColor = NSColor(calibratedRed: 0.36, green: 0.95, blue: 0.98, alpha: 1)
    waveColor.setStroke()
    NSColor.white.withAlphaComponent(0.98).setFill()

    for index in 0..<3 {
        let inset = CGFloat(index) * waveRect.width * 0.145
        let yOffset = CGFloat(index) * waveRect.height * -0.12
        let rect = waveRect.insetBy(dx: inset, dy: inset + yOffset)
        let path = NSBezierPath()
        path.lineWidth = waveLineWidth
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.curve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            controlPoint1: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY),
            controlPoint2: CGPoint(x: rect.maxX - rect.width * 0.28, y: rect.maxY)
        )
        path.stroke()
    }

    let micStemWidth = canvas * 0.030
    let micCapsule = CGRect(
        x: iconRect.midX - iconRect.width * 0.070,
        y: iconRect.minY + iconRect.height * 0.30,
        width: iconRect.width * 0.14,
        height: iconRect.height * 0.29
    )
    let micBody = NSBezierPath(roundedRect: micCapsule, xRadius: micCapsule.width * 0.48, yRadius: micCapsule.width * 0.48)
    micBody.fill()

    let micArcRect = CGRect(
        x: iconRect.midX - iconRect.width * 0.17,
        y: iconRect.minY + iconRect.height * 0.27,
        width: iconRect.width * 0.34,
        height: iconRect.height * 0.28
    )
    let micArc = NSBezierPath()
    micArc.lineWidth = micStemWidth
    micArc.lineCapStyle = .round
    micArc.appendArc(
        withCenter: CGPoint(x: micArcRect.midX, y: micArcRect.midY),
        radius: micArcRect.width * 0.50,
        startAngle: 205,
        endAngle: 335,
        clockwise: true
    )
    micArc.stroke()

    let stem = NSBezierPath(roundedRect: CGRect(
        x: iconRect.midX - micStemWidth / 2,
        y: iconRect.minY + iconRect.height * 0.19,
        width: micStemWidth,
        height: iconRect.height * 0.15
    ), xRadius: micStemWidth / 2, yRadius: micStemWidth / 2)
    stem.fill()

    let foot = NSBezierPath(roundedRect: CGRect(
        x: iconRect.midX - iconRect.width * 0.13,
        y: iconRect.minY + iconRect.height * 0.17,
        width: iconRect.width * 0.26,
        height: iconRect.height * 0.042
    ), xRadius: iconRect.height * 0.021, yRadius: iconRect.height * 0.021)
    foot.fill()

    if !fullBleed {
        let border = NSBezierPath(roundedRect: iconRect.insetBy(dx: canvas * 0.006, dy: canvas * 0.006), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = max(1, canvas * 0.006)
        NSColor.white.withAlphaComponent(0.32).setStroke()
        border.stroke()
    }

    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PhoneMicIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG"])
    }
    try png.write(to: url)
}

func flattenedRGB(_ source: NSBitmapImageRep) -> NSBitmapImageRep {
    guard
        let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.pixelsWide,
            pixelsHigh: source.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        fatalError("Unable to create RGB bitmap")
    }

    output.size = source.size
    for y in 0..<source.pixelsHigh {
        for x in 0..<source.pixelsWide {
            let color = source.colorAt(x: x, y: y) ?? .clear
            output.setColor(color.withAlphaComponent(1), atX: x, y: y)
        }
    }
    return output
}

for size in sizes {
    let image = drawIcon(size: size.pixels)
    try writePNG(image, to: iconset.appendingPathComponent(size.filename))
}

try writePNG(drawIcon(size: 1024), to: preview)

for size in iosSizes {
    let image = drawIcon(size: size.pixels, fullBleed: true)
    try writePNG(flattenedRGB(image), to: iosAppIconSet.appendingPathComponent(size.filename))
}

try writePNG(flattenedRGB(drawIcon(size: 1024, fullBleed: true)), to: iosPreview)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", resources.appendingPathComponent("PhoneMic.icns").path
]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "PhoneMicIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}
