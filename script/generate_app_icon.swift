#!/usr/bin/env swift

import AppKit
import Foundation

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsURL = rootURL.appendingPathComponent("assets", isDirectory: true)
let iconsetURL = assetsURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let sourcePNGURL = assetsURL.appendingPathComponent("AppIcon.png")

try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func fillRoundedRect(_ rect: NSRect, radius: CGFloat, color fillColor: NSColor) {
    fillColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func strokeRoundedRect(_ rect: NSRect, radius: CGFloat, color strokeColor: NSColor, width: CGFloat) {
    strokeColor.setStroke()
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
    path.lineWidth = width
    path.stroke()
}

func drawShadow(color shadowColor: NSColor, blur: CGFloat, offset: NSSize, drawing: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    drawing()
    NSGraphicsContext.restoreGraphicsState()
}

func drawLine(_ rect: NSRect, color lineColor: NSColor) {
    fillRoundedRect(rect, radius: rect.height / 2, color: lineColor)
}

func drawIconArtwork() {
    let baseRect = NSRect(x: 92, y: 92, width: 840, height: 840)
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 190, yRadius: 190)

    drawShadow(color: color(0, 0, 0, 0.28), blur: 44, offset: NSSize(width: 0, height: -24)) {
        color(31, 57, 72).setFill()
        basePath.fill()
    }

    NSGraphicsContext.saveGraphicsState()
    basePath.addClip()
    NSGradient(colors: [
        color(88, 138, 163),
        color(36, 74, 94),
        color(17, 36, 52)
    ])?.draw(in: basePath, angle: 115)
    fillRoundedRect(NSRect(x: 150, y: 640, width: 720, height: 210), radius: 110, color: color(255, 255, 255, 0.16))
    fillRoundedRect(NSRect(x: 162, y: 164, width: 700, height: 190), radius: 96, color: color(0, 0, 0, 0.12))
    NSGraphicsContext.restoreGraphicsState()

    strokeRoundedRect(baseRect, radius: 190, color: color(255, 255, 255, 0.24), width: 5)

    let pageRect = NSRect(x: 306, y: 196, width: 412, height: 618)
    drawShadow(color: color(0, 0, 0, 0.25), blur: 30, offset: NSSize(width: 0, height: -16)) {
        fillRoundedRect(pageRect, radius: 48, color: color(247, 251, 255))
    }
    strokeRoundedRect(pageRect, radius: 48, color: color(255, 255, 255, 0.72), width: 3)

    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: 604, y: 814))
    foldPath.line(to: NSPoint(x: 718, y: 814))
    foldPath.line(to: NSPoint(x: 718, y: 700))
    foldPath.close()
    color(218, 231, 240).setFill()
    foldPath.fill()
    color(183, 202, 216, 0.85).setStroke()
    foldPath.lineWidth = 3
    foldPath.stroke()

    drawLine(NSRect(x: 370, y: 674, width: 216, height: 20), color: color(136, 158, 174, 0.55))
    drawLine(NSRect(x: 370, y: 614, width: 274, height: 18), color: color(136, 158, 174, 0.46))
    fillRoundedRect(NSRect(x: 360, y: 551, width: 298, height: 44), radius: 17, color: color(255, 209, 70, 0.76))
    drawLine(NSRect(x: 380, y: 565, width: 252, height: 17), color: color(84, 94, 102, 0.74))
    drawLine(NSRect(x: 370, y: 497, width: 244, height: 18), color: color(136, 158, 174, 0.42))
    drawLine(NSRect(x: 370, y: 438, width: 286, height: 18), color: color(136, 158, 174, 0.37))

    let bubbleRect = NSRect(x: 558, y: 238, width: 264, height: 174)
    drawShadow(color: color(0, 0, 0, 0.20), blur: 24, offset: NSSize(width: 0, height: -12)) {
        fillRoundedRect(bubbleRect, radius: 46, color: color(255, 220, 94))
    }
    let tailPath = NSBezierPath()
    tailPath.move(to: NSPoint(x: 610, y: 246))
    tailPath.line(to: NSPoint(x: 672, y: 246))
    tailPath.line(to: NSPoint(x: 632, y: 190))
    tailPath.close()
    color(255, 220, 94).setFill()
    tailPath.fill()
    strokeRoundedRect(bubbleRect, radius: 46, color: color(255, 241, 164, 0.82), width: 3)

    drawLine(NSRect(x: 618, y: 345, width: 126, height: 16), color: color(99, 80, 27, 0.72))
    drawLine(NSRect(x: 618, y: 304, width: 160, height: 16), color: color(99, 80, 27, 0.56))
}

func makeIcon(size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
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
    ) else {
        throw NSError(domain: "SimplePDFIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap"])
    }

    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIconArtwork()
    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()

    return bitmap
}

func savePNG(size: Int, filename: String) throws {
    let bitmap = try makeIcon(size: size)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SimplePDFIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    try data.write(to: iconsetURL.appendingPathComponent(filename))
    if size == 1024 {
        try data.write(to: sourcePNGURL)
    }
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for variant in variants {
    try savePNG(size: variant.0, filename: variant.1)
}

print(iconsetURL.path)
