// Draws the app icon and writes Resources/AppIcon.icns.  Usage: swift scripts/make-icon.swift
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024) // everything below is in a 1024 pt canvas

    // macOS icon grid: an 824 pt rounded square centred in the canvas, with a soft drop shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill(); tile.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1), NSColor(red: 0.20, green: 0.16, blue: 0.62, alpha: 1)])!
        .draw(in: tile, angle: -90)

    // Three windows folded into a stack: back two peek out above the front one.
    func window(_ rect: NSRect, alpha: CGFloat, titleBar: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        NSColor.white.withAlphaComponent(alpha).setFill(); path.fill()
        ctx.restoreGState()
        guard titleBar else { return }
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 44 + CGFloat(i) * 56, y: rect.maxY - 80, width: 36, height: 36)).fill()
        }
        NSColor(white: 0, alpha: 0.10).setFill()
        for (i, w) in [0.62, 0.44].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 44, y: rect.maxY - 170 - CGFloat(i) * 62, width: (rect.width - 88) * w, height: 28),
                         xRadius: 14, yRadius: 14).fill()
        }
    }
    window(NSRect(x: 322, y: 560, width: 380, height: 200), alpha: 0.38, titleBar: false)
    window(NSRect(x: 272, y: 480, width: 480, height: 240), alpha: 0.62, titleBar: false)
    window(NSRect(x: 222, y: 250, width: 580, height: 400), alpha: 1, titleBar: true)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try draw(size * scale).representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
let out = root.appending(path: "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try draw(1024).representation(using: .png, properties: [:])!.write(to: root.appending(path: "Resources/AppIcon.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
