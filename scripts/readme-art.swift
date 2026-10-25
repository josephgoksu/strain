// Draws the README hero and GitHub social card from panel snapshots. Run from the repo root:
//   swift scripts/readme-art.swift <apps.png> <controls.png> <clean.png>
// Snapshots come from `Strain --snapshot out.png --tab=apps --dark` etc. Writes docs/hero.png and docs/social.png.
import AppKit

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The icon's heat gradient (indigo → magenta → red → amber), so the art reads as one brand.
let heat = NSGradient(colors: [srgb(0x2A1B5E), srgb(0x8E1F7E), srgb(0xE0405A), srgb(0xFFA62B)],
                      atLocations: [0, 0.45, 0.78, 1], colorSpace: .sRGB)!

func canvas(_ w: Int, _ h: Int, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

/// A panel screenshot as a floating window: rounded, hairline border, soft shadow.
func panel(_ image: NSImage, in rect: NSRect) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 40
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.18).setStroke()
    path.lineWidth = 2
    path.stroke()
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, at p: NSPoint) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                 .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
}

let paths = Array(CommandLine.arguments.dropFirst())
guard paths.count == 3 else { fatalError("usage: readme-art.swift <apps.png> <controls.png> <clean.png>") }
let shots = paths.map { NSImage(contentsOfFile: $0)! }
let icon = NSImage(contentsOfFile: "docs/icon.png")!

/// Centered single line of white text.
func centered(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, midX: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
    let w = (s as NSString).size(withAttributes: attrs).width
    (s as NSString).draw(at: NSPoint(x: midX - w / 2, y: y), withAttributes: attrs)
}

// Hero: name and promise on top, three panels below, each with what it's for.
let captions = ["Names the culprit", "Switches, fixes, displays", "Frees what tools rebuild"]
let hero = canvas(2400, 1560) { r in
    heat.draw(in: r, angle: -30)
    icon.draw(in: NSRect(x: r.midX - 330, y: 1300, width: 150, height: 150))
    text("Strain", size: 120, weight: .bold, at: NSPoint(x: r.midX - 150, y: 1300))
    centered("What's slowing your Mac, in plain English. Plus the switches you reach for.", size: 44, weight: .medium, alpha: 0.9, midX: r.midX, y: 1205)
    let w: CGFloat = 660, h = w * shots[0].size.height / shots[0].size.width
    let xs: [CGFloat] = [105, 870, 1635], lift: [CGFloat] = [0, 40, 0]
    for (i, img) in shots.enumerated() {
        let y = 80 + lift[i]
        panel(img, in: NSRect(x: xs[i], y: y, width: w, height: h))
        centered(captions[i], size: 34, weight: .semibold, alpha: 0.95, midX: xs[i] + w / 2, y: y + h + 22)
    }
}
try! hero.write(to: URL(fileURLWithPath: "docs/hero.png"))

// Social card, GitHub's 1280×640: icon, name, one line, the Apps panel.
let social = canvas(1280, 640) { r in
    heat.draw(in: r, angle: -30)
    icon.draw(in: NSRect(x: 64, y: 380, width: 200, height: 200))
    text("Strain", size: 104, weight: .bold, at: NSPoint(x: 72, y: 220))
    text("What's slowing your Mac,", size: 38, weight: .medium, alpha: 0.92, at: NSPoint(x: 78, y: 150))
    text("in plain English.", size: 38, weight: .medium, alpha: 0.92, at: NSPoint(x: 78, y: 104))
    let w: CGFloat = 470, h = w * shots[0].size.height / shots[0].size.width
    panel(shots[0], in: NSRect(x: 730, y: 40 - (h - 560), width: w, height: h))
}
try! social.write(to: URL(fileURLWithPath: "docs/social.png"))
print("wrote docs/hero.png, docs/social.png")
