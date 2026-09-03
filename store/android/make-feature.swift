import AppKit

let outputSize = NSSize(width: 1024, height: 500)
let image = NSImage(size: outputSize)
image.lockFocus()

let navy = NSColor(calibratedRed: 0.024, green: 0.086, blue: 0.20, alpha: 1)
let cyan = NSColor(calibratedRed: 0.094, green: 0.847, blue: 0.937, alpha: 1)
let background = NSGradient(colors: [
    navy,
    NSColor(calibratedRed: 0.026, green: 0.20, blue: 0.30, alpha: 1),
])!
background.draw(in: NSRect(origin: .zero, size: outputSize), angle: 0)

for (index, size) in [440.0, 340.0, 250.0].enumerated() {
    let ring = NSBezierPath(ovalIn: NSRect(x: 30 + (440 - size) / 2, y: 30 + (440 - size) / 2, width: size, height: size))
    ring.lineWidth = index == 0 ? 2 : 1
    NSColor(calibratedRed: 0.094, green: 0.847, blue: 0.937, alpha: 0.12).setStroke()
    ring.stroke()
}

let iconURL = URL(fileURLWithPath: "store/android/ptt-icon-512.png")
guard let icon = NSImage(contentsOf: iconURL) else {
    fatalError("Unable to load app icon")
}
icon.draw(in: NSRect(x: 104, y: 92, width: 316, height: 316))

let eyebrowStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
    .foregroundColor: cyan,
    .kern: 2.4,
]
let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .bold),
    .foregroundColor: NSColor.white,
    .kern: -2.0,
]
let subtitleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 31, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
]
let detailStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 19, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.68),
]

NSAttributedString(string: "PRIVATE TEAM COMMUNICATION", attributes: eyebrowStyle)
    .draw(at: NSPoint(x: 505, y: 360))
NSAttributedString(string: "PTT Talk", attributes: titleStyle)
    .draw(at: NSPoint(x: 500, y: 270))
NSAttributedString(string: "Private voice. Instant coordination.", attributes: subtitleStyle)
    .draw(at: NSPoint(x: 503, y: 218))
NSAttributedString(string: "ENCRYPTED  ·  CROSS-PLATFORM  ·  SELF-HOSTABLE", attributes: detailStyle)
    .draw(at: NSPoint(x: 504, y: 168))

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode feature graphic")
}
try png.write(to: URL(fileURLWithPath: "store/android/ptt-feature-1024x500.png"))
