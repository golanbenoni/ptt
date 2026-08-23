import AppKit

let outputSize = NSSize(width: 1024, height: 500)
let image = NSImage(size: outputSize)
image.lockFocus()

let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.035, green: 0.075, blue: 0.16, alpha: 1),
    NSColor(calibratedRed: 0.075, green: 0.24, blue: 0.34, alpha: 1),
])!
background.draw(in: NSRect(origin: .zero, size: outputSize), angle: 0)

let glow = NSBezierPath(ovalIn: NSRect(x: 40, y: 20, width: 460, height: 460))
NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.78, alpha: 0.13).setFill()
glow.fill()

let iconURL = URL(fileURLWithPath: "store/android/ptt-icon-512.png")
guard let icon = NSImage(contentsOf: iconURL) else {
    fatalError("Unable to load app icon")
}
icon.draw(in: NSRect(x: 92, y: 78, width: 344, height: 344))

let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 68, weight: .bold),
    .foregroundColor: NSColor.white,
]
let subtitleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.82),
]
NSAttributedString(string: "PTT Talk", attributes: titleStyle)
    .draw(at: NSPoint(x: 500, y: 275))
NSAttributedString(string: "Encrypted transport beta", attributes: subtitleStyle)
    .draw(at: NSPoint(x: 503, y: 222))
NSAttributedString(string: "Cross-platform test audio", attributes: subtitleStyle)
    .draw(at: NSPoint(x: 503, y: 180))

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode feature graphic")
}
try png.write(to: URL(fileURLWithPath: "store/android/ptt-feature-1024x500.png"))
