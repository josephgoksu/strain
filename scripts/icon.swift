// Draws the app icon. Run from the repo root: swift scripts/icon.swift
// A white gauge needle swinging into the red, on a heat gradient (indigo → magenta → amber) with film grain.
import AppKit

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let detail = px > 32  // grain and highlight turn to mush at 16/32 px
    let s = CGFloat(px) / 1024  // Apple's 1024 grid: 824 pt body, 100 pt margin
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    srgb(0x2A1B5E).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Heat builds from the cool top-left to the hot bottom-right.
    NSGradient(colors: [srgb(0x2A1B5E), srgb(0x8E1F7E), srgb(0xE0405A), srgb(0xFFA62B)],
               atLocations: [0, 0.42, 0.72, 1], colorSpace: .sRGB)!.draw(in: squircle, angle: -45)

    if detail {
        // Soft top highlight, like native macOS icons.
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSGradient(starting: .white.withAlphaComponent(0.22), ending: .white.withAlphaComponent(0))!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Gauge: a 240° arc with ticks, needle pointing into the hot zone.
    let c = NSPoint(x: body.midX, y: body.midY - 40 * s), r = 270 * s
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: -30, endAngle: 210)
    arc.lineWidth = 46 * s
    arc.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.35).setStroke()
    arc.stroke()
    let hot = NSBezierPath()
    hot.appendArc(withCenter: c, radius: r, startAngle: -30, endAngle: 40)
    hot.lineWidth = 46 * s
    hot.lineCapStyle = .round
    NSColor.white.setStroke()
    hot.stroke()
    for deg in stride(from: 210.0, through: 50, by: -40) where detail {  // no ticks in the hot zone
        let a = deg * .pi / 180, inner = r - 80 * s, outer = r - 52 * s
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
        tick.line(to: NSPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
        tick.lineWidth = 14 * s
        tick.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        tick.stroke()
    }
    NSGraphicsContext.saveGraphicsState()
    let needleShadow = NSShadow()
    needleShadow.shadowColor = .black.withAlphaComponent(0.3)
    needleShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    needleShadow.shadowBlurRadius = 16 * s
    needleShadow.set()
    let a = 15.0 * .pi / 180, len = r - 40 * s
    let needle = NSBezierPath()
    needle.move(to: c)
    needle.line(to: NSPoint(x: c.x + len * cos(a), y: c.y + len * sin(a)))
    needle.lineWidth = 34 * s
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 48 * s, y: c.y - 48 * s, width: 96 * s, height: 96 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    srgb(0x8E1F7E).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 18 * s, y: c.y - 18 * s, width: 36 * s, height: 36 * s)).fill()
    NSGraphicsContext.current = nil

    if detail { grain(rep, inside: body.insetBy(dx: 2 * s, dy: 2 * s)) }
    return rep.representation(using: .png, properties: [:])!
}

/// Film grain: seeded per-pixel noise (±6%) on opaque body pixels, so every run gives the same icon.
func grain(_ rep: NSBitmapImageRep, inside rect: NSRect) {
    guard let data = rep.bitmapData else { return }
    var seed: UInt64 = 0x5EED_5EED
    let h = rep.pixelsHigh, bpr = rep.bytesPerRow
    for y in 0..<h {
        for x in 0..<rep.pixelsWide {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let p = data + y * bpr + x * 4
            guard p[3] == 255, rect.contains(NSPoint(x: CGFloat(x), y: CGFloat(h - 1 - y))) else { continue }
            let n = Int(seed >> 59) - 16  // -16…15, about ±6% of 255
            for ch in 0..<3 { p[ch] = UInt8(clamping: Int(p[ch]) + n) }
        }
    }
}

let set = URL(fileURLWithPath: "Strain.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! draw(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! draw(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "Resources/Strain.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: set)
try! draw(1024).write(to: URL(fileURLWithPath: "docs/icon.png"))
try! draw(32).write(to: URL(fileURLWithPath: "docs/icon-32.png"))
print("Wrote Resources/Strain.icns, docs/icon.png, docs/icon-32.png")
