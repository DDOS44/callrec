// Draws the app icon into an .iconset folder. Run by scripts/make-app.sh.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./callrec.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data? {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.22
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.52, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "phone.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor(calibratedRed: 0.20, green: 0.83, blue: 0.60, alpha: 1).set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        let w = symbol.size.width, h = symbol.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

for (size, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
                     (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
                     (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")] {
    if let data = draw(size) {
        try? data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
