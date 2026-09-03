import AppKit

let outputSize = NSSize(width: 1200, height: 630)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(outputSize.width),
    pixelsHigh: Int(outputSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Unable to create social preview canvas")
}
bitmap.size = outputSize
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let navy = NSColor(calibratedRed: 0.024, green: 0.086, blue: 0.20, alpha: 1)
let cyan = NSColor(calibratedRed: 0.094, green: 0.847, blue: 0.937, alpha: 1)
let gradient = NSGradient(colors: [
    navy,
    NSColor(calibratedRed: 0.018, green: 0.17, blue: 0.27, alpha: 1),
])!
gradient.draw(in: NSRect(origin: .zero, size: outputSize), angle: 0)

for (index, size) in [520.0, 410.0, 300.0].enumerated() {
    let ring = NSBezierPath(ovalIn: NSRect(x: 700 + (520 - size) / 2, y: 55 + (520 - size) / 2, width: size, height: size))
    ring.lineWidth = index == 0 ? 2 : 1
    NSColor(calibratedRed: 0.094, green: 0.847, blue: 0.937, alpha: 0.14).setStroke()
    ring.stroke()
}

guard let icon = NSImage(contentsOfFile: "website/icon.png") else {
    fatalError("Run scripts/generate-app-icons.swift first")
}
icon.draw(in: NSRect(x: 835, y: 190, width: 250, height: 250))

let eyebrowStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: cyan,
    .kern: 2.8,
]
let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 76, weight: .bold),
    .foregroundColor: NSColor.white,
    .kern: -2.2,
]
let subtitleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 29, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.78),
]

NSAttributedString(string: "PTT TALK", attributes: eyebrowStyle)
    .draw(at: NSPoint(x: 78, y: 500))
NSAttributedString(string: "Private voice.\nReady when your team is.", attributes: titleStyle)
    .draw(in: NSRect(x: 72, y: 230, width: 675, height: 250))
NSAttributedString(string: "Encrypted voice + team messaging  ·  Self-hostable", attributes: subtitleStyle)
    .draw(at: NSPoint(x: 78, y: 152))

NSGraphicsContext.restoreGraphicsState()
guard let renderedImage = bitmap.cgImage,
      let opaqueContext = CGContext(
          data: nil,
          width: Int(outputSize.width),
          height: Int(outputSize.height),
          bitsPerComponent: 8,
          bytesPerRow: Int(outputSize.width) * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fatalError("Unable to create opaque social preview")
}
opaqueContext.draw(renderedImage, in: CGRect(origin: .zero, size: outputSize))
guard let opaqueImage = opaqueContext.makeImage(),
      let png = NSBitmapImageRep(cgImage: opaqueImage).representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode social preview")
}
try png.write(to: URL(fileURLWithPath: "website/og.png"))
