// Draws the Breakaway app icon into an .iconset directory (used by build-app.sh).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.55, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.9, green: 0.25, blue: 0.08, alpha: 1)])?
        .draw(in: bg, angle: -90)
    // Mountain silhouette.
    let m = NSBezierPath()
    m.move(to: NSPoint(x: rect.minX, y: rect.minY + s * 0.18))
    m.line(to: NSPoint(x: rect.minX + s * 0.30, y: rect.minY + s * 0.52))
    m.line(to: NSPoint(x: rect.minX + s * 0.42, y: rect.minY + s * 0.40))
    m.line(to: NSPoint(x: rect.minX + s * 0.62, y: rect.minY + s * 0.66))
    m.line(to: NSPoint(x: rect.maxX, y: rect.minY + s * 0.26))
    m.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    m.line(to: NSPoint(x: rect.minX, y: rect.minY))
    m.close()
    NSColor(white: 0, alpha: 0.22).setFill()
    m.fill()
    if let sym = NSImage(systemSymbolName: "bicycle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: s * 0.42, weight: .bold)) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = s * 0.62, h = w * sym.size.height / max(sym.size.width, 1)
        tinted.draw(in: NSRect(x: (s - w) / 2, y: s * 0.30, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        if let data = draw(size * scale) { try data.write(to: out.appendingPathComponent(name)) }
    }
}
