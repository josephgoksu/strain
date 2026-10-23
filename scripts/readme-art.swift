// Draws the README hero and GitHub social card from panel snapshots. Run from the repo root:
//   swift scripts/readme-art.swift <cpu.png> <memory.png> <controls.png>
// Snapshots come from `Strain --snapshot out.png --meter=cpu --dark` etc. Writes docs/hero.png and docs/social.png.
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

let args = CommandLine.arguments.dropFirst().map { NSImage(contentsOfFile: $0)! }
guard args.count == 3 else { fatalError("usage: readme-art.swift <cpu.png> <memory.png> <controls.png>") }
let icon = NSImage(contentsOfFile: "docs/icon.png")!

// Hero: three panels, the middle one raised, on the heat gradient.
let hero = canvas(2400, 1300) { r in
    heat.draw(in: r, angle: -30)
    let w: CGFloat = 640, h = w * args[0].size.height / args[0].size.width
    let xs: [CGFloat] = [140, 880, 1620], lift: [CGFloat] = [0, 60, 0]
    for (i, img) in args.enumerated() { panel(img, in: NSRect(x: xs[i], y: (r.height - h) / 2 - 30 + lift[i], width: w, height: h)) }
}
try! hero.write(to: URL(fileURLWithPath: "docs/hero.png"))

// Social card, GitHub's 1280×640: icon, name, one line, one panel.
let social = canvas(1280, 640) { r in
    heat.draw(in: r, angle: -30)
    icon.draw(in: NSRect(x: 40, y: 330, width: 260, height: 260))
    text("Strain", size: 92, weight: .bold, at: NSPoint(x: 80, y: 200))
    text("What's straining your Mac,", size: 36, weight: .medium, alpha: 0.92, at: NSPoint(x: 84, y: 140))
    text("in plain English.", size: 36, weight: .medium, alpha: 0.92, at: NSPoint(x: 84, y: 96))
    let w: CGFloat = 470, h = w * args[0].size.height / args[0].size.width
    panel(args[0], in: NSRect(x: 740, y: 40 - (h - 560), width: w, height: h))
}
try! social.write(to: URL(fileURLWithPath: "docs/social.png"))
print("wrote docs/hero.png, docs/social.png")
