// Draws the app icon and writes Resources/AppIcon.icns. Run: swift Tools/make-icon.swift
import AppKit

func draw(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Body on Apple's icon grid: 824 pt squircle centred in 1024, with a soft drop shadow.
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24 * s; shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.set()
    NSColor.black.setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.14, alpha: 1), ending: NSColor(white: 0.03, alpha: 1))!.draw(in: body, angle: -90)

    // Monitor: thin grey outline and stand, dark screen with a faint wash of colour.
    let grey = NSColor(white: 0.78, alpha: 1)
    grey.setFill()
    NSBezierPath(roundedRect: r(482, 262, 60, 70), xRadius: 6 * s, yRadius: 6 * s).fill()
    NSBezierPath(roundedRect: r(402, 246, 220, 26), xRadius: 13 * s, yRadius: 13 * s).fill()
    let screen = NSBezierPath(roundedRect: r(232, 338, 560, 370), xRadius: 34 * s, yRadius: 34 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 1), NSColor(red: 0.30, green: 0.17, blue: 0.34, alpha: 1)])!
        .draw(in: screen, angle: -35)
    grey.setStroke(); screen.lineWidth = 20 * s; screen.stroke()

    // Small sun, soft white.
    let cfg = NSImage.SymbolConfiguration(pointSize: 150 * s, weight: .medium).applying(.init(paletteColors: [NSColor(white: 0.92, alpha: 1)]))
    if let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sun.size
        sun.draw(in: NSRect(x: 512 * s - sz.width / 2, y: 523 * s - sz.height / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: dir.appending(path: name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! draw(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
