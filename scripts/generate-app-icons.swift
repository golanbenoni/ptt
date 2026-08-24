#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvas: CGFloat = 1024
private let navy = CGColor(
    red: CGFloat(0x06) / 255,
    green: CGFloat(0x16) / 255,
    blue: CGFloat(0x33) / 255,
    alpha: 1
)
private let cyan = CGColor(
    red: CGFloat(0x18) / 255,
    green: CGFloat(0xD8) / 255,
    blue: CGFloat(0xEF) / 255,
    alpha: 1
)
private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

private struct IconOutput {
    let path: String
    let size: Int
    let transparent: Bool
    let compactMark: Bool
}

private func roundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color)
    context.fillPath()
}

private func drawMark(in context: CGContext, compact: Bool) {
    context.saveGState()
    if compact {
        context.translateBy(x: canvas / 2, y: canvas / 2)
        context.scaleBy(x: 0.84, y: 0.84)
        context.translateBy(x: -canvas / 2, y: -canvas / 2)
    }

    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 300, y: 676))
    tail.addLine(to: CGPoint(x: 246, y: 842))
    tail.addLine(to: CGPoint(x: 452, y: 704))
    tail.closeSubpath()
    context.addPath(tail)
    context.setFillColor(cyan)
    context.fillPath()

    roundedRect(
        context,
        CGRect(x: 196, y: 220, width: 632, height: 500),
        radius: 154,
        color: cyan
    )
    roundedRect(context, CGRect(x: 342, y: 388, width: 78, height: 190), radius: 39, color: white)
    roundedRect(context, CGRect(x: 473, y: 326, width: 78, height: 312), radius: 39, color: white)
    roundedRect(context, CGRect(x: 604, y: 388, width: 78, height: 190), radius: 39, color: white)
    context.restoreGState()
}

private func render(_ output: IconOutput, root: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let alphaInfo: CGImageAlphaInfo = output.transparent ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil,
        width: output.size,
        height: output.size,
        bitsPerComponent: 8,
        bytesPerRow: output.size * 4,
        space: colorSpace,
        bitmapInfo: alphaInfo.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    if !output.transparent {
        context.setFillColor(navy)
        context.fill(CGRect(x: 0, y: 0, width: output.size, height: output.size))
    }
    let scale = CGFloat(output.size) / canvas
    context.translateBy(x: 0, y: CGFloat(output.size))
    context.scaleBy(x: scale, y: -scale)
    drawMark(in: context, compact: output.compactMark)

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let destinationUrl = root.appendingPathComponent(output.path)
    try FileManager.default.createDirectory(
        at: destinationUrl.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        destinationUrl as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private let iosIconSizes: [(String, Int)] = [
    ("icon-20@1x.png", 20),
    ("icon-20@2x.png", 40),
    ("icon-20@3x.png", 60),
    ("icon-29@1x.png", 29),
    ("icon-29@2x.png", 58),
    ("icon-29@3x.png", 87),
    ("icon-40@1x.png", 40),
    ("icon-40@2x.png", 80),
    ("icon-40@3x.png", 120),
    ("icon-60@2x.png", 120),
    ("icon-60@3x.png", 180),
    ("icon-76@1x.png", 76),
    ("icon-76@2x.png", 152),
    ("icon-83.5@2x.png", 167),
    ("icon-1024.png", 1024),
]

private let androidForegroundSizes: [(String, Int)] = [
    ("mipmap-mdpi/ic_launcher_foreground.png", 108),
    ("mipmap-hdpi/ic_launcher_foreground.png", 162),
    ("mipmap-xhdpi/ic_launcher_foreground.png", 216),
    ("mipmap-xxhdpi/ic_launcher_foreground.png", 324),
    ("mipmap-xxxhdpi/ic_launcher_foreground.png", 432),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ios/TalkApp").path) else {
    fatalError("Run this script from the PTT repository root.")
}

private var outputs = [
    IconOutput(path: "artwork/ptt-app-icon-master.png", size: 1024, transparent: false, compactMark: false),
    IconOutput(path: "artwork/ptt-app-icon-source.png", size: 1254, transparent: false, compactMark: false),
    IconOutput(path: "artwork/ptt-app-icon-foreground.png", size: 1024, transparent: true, compactMark: true),
    IconOutput(path: "artwork/ptt-app-icon-foreground-source.png", size: 1254, transparent: true, compactMark: true),
    IconOutput(path: "store/android/ptt-icon-512.png", size: 512, transparent: false, compactMark: false),
]
outputs += iosIconSizes.map {
    IconOutput(
        path: "ios/TalkApp/TalkApp/Assets.xcassets/AppIcon.appiconset/\($0.0)",
        size: $0.1,
        transparent: false,
        compactMark: false
    )
}
outputs += androidForegroundSizes.map {
    IconOutput(
        path: "android/talk/src/main/res/\($0.0)",
        size: $0.1,
        transparent: true,
        compactMark: true
    )
}

for output in outputs {
    try render(output, root: root)
}
print("Generated \(outputs.count) flat PTT Talk app-icon assets.")
