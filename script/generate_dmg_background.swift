#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate_dmg_background.swift <output.png>\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
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
    FileHandle.standardError.write(Data("Unable to create DMG background canvas.\n".utf8))
    exit(1)
}
bitmap.size = canvasSize

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSColor(calibratedRed: 0.953, green: 0.969, blue: 0.988, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 292, y: 218))
arrow.line(to: NSPoint(x: 425, y: 218))
arrow.move(to: NSPoint(x: 402, y: 240))
arrow.line(to: NSPoint(x: 426, y: 218))
arrow.line(to: NSPoint(x: 402, y: 196))
NSColor(calibratedRed: 0.08, green: 0.49, blue: 0.96, alpha: 0.88).setStroke()
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

let instructionStyle = NSMutableParagraphStyle()
instructionStyle.alignment = .center
let instructionAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.32, alpha: 1),
    .paragraphStyle: instructionStyle,
]
NSString(string: "拖动安装").draw(
    in: NSRect(x: 285, y: 164, width: 150, height: 24),
    withAttributes: instructionAttributes
)

let noteAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.49, blue: 0.56, alpha: 1),
    .paragraphStyle: instructionStyle,
]
NSString(string: "开发签名版本首次启动如被拦截，请右键 PhoneMic 并选择“打开”").draw(
    in: NSRect(x: 70, y: 35, width: 580, height: 20),
    withAttributes: noteAttributes
)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to render DMG background.\n".utf8))
    exit(1)
}

do {
    try pngData.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Unable to write DMG background: \(error.localizedDescription)\n".utf8))
    exit(1)
}
