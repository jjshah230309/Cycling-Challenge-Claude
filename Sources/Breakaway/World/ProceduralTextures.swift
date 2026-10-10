import AppKit
import BreakawayCore
import CoreGraphics
import CoreText
import Foundation

/// Textures drawn at runtime with Core Graphics, so the app ships no image assets.
enum ProceduralTextures {
    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func cg(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private static func speckle(_ ctx: CGContext, w: Int, h: Int, count: Int, colors: [UInt32], size: ClosedRange<Double>,
                                alpha: ClosedRange<Double>, seed: UInt64, rect: CGRect? = nil) {
        var r = SceneRandom(seed: seed)
        let area = rect ?? CGRect(x: 0, y: 0, width: w, height: h)
        for _ in 0..<count {
            let s = r.range(size.lowerBound, size.upperBound)
            ctx.setFillColor(cg(r.pick(colors), CGFloat(r.range(alpha.lowerBound, alpha.upperBound))))
            ctx.fillEllipse(in: CGRect(x: area.minX + r.range(0, Double(area.width)), y: area.minY + r.range(0, Double(area.height)),
                                       width: s, height: s))
        }
    }

    // MARK: Road surfaces (u across the 11 m carriageway + verges, v along 9 m)

    static let verge: CGFloat = (5.5 - 3.6) / 11.0

    static func asphalt(urban: Bool) -> CGImage {
        let w = 512, h = 512
        let ctx = context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        ctx.setFillColor(cg(urban ? 0x8A8A86 : 0x7B6A55))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        speckle(ctx, w: w, h: h, count: 2500, colors: urban ? [0x9A9A96, 0x6E6E6A] : [0x6B5A45, 0x8E7B62, 0x5E7046], size: 1...4, alpha: 0.4...0.9, seed: 1)
        let tarRect = CGRect(x: W * verge, y: 0, width: W * (1 - 2 * verge), height: H)
        ctx.setFillColor(cg(0x3C3D40))
        ctx.fill(tarRect)
        speckle(ctx, w: w, h: h, count: 9000, colors: [0x2E2F31, 0x4A4B4F, 0x56575B, 0x333438], size: 0.8...2.6, alpha: 0.5...1, seed: 2, rect: tarRect)
        // Repair patches.
        var r = SceneRandom(seed: 3)
        for _ in 0..<5 {
            ctx.setFillColor(cg(r.pick([0x333436, 0x45464A]), 0.55))
            ctx.fill(CGRect(x: tarRect.minX + r.range(0, Double(tarRect.width) - 80), y: r.range(0, Double(H) - 90),
                            width: r.range(30, 90), height: r.range(40, 120)))
        }
        // Edge lines and centre dashes.
        ctx.setFillColor(cg(0xE8E8E2, 0.92))
        let line = W * 0.12 / 11
        ctx.fill(CGRect(x: tarRect.minX + W * 0.15 / 11, y: 0, width: line, height: H))
        ctx.fill(CGRect(x: tarRect.maxX - W * 0.15 / 11 - line, y: 0, width: line, height: H))
        ctx.fill(CGRect(x: W / 2 - line / 2, y: H * 0.1, width: line, height: H / 3))
        return ctx.makeImage()!
    }

    static func cobbles() -> CGImage {
        let w = 512, h = 512
        let ctx = context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        ctx.setFillColor(cg(0x6F6450))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        speckle(ctx, w: w, h: h, count: 3000, colors: [0x5C6E3E, 0x7D6E52, 0x4F4535], size: 1...5, alpha: 0.5...1, seed: 7)
        let road = CGRect(x: W * verge * 0.6, y: 0, width: W * (1 - 1.2 * verge), height: H)
        ctx.setFillColor(cg(0x4B443A))
        ctx.fill(road)
        var r = SceneRandom(seed: 11)
        let stone: CGFloat = W / 11 * 0.16   // ~16 cm setts
        var y: CGFloat = 0
        var row = 0
        while y < H {
            var x = road.minX + (row % 2 == 0 ? 0 : stone / 2)
            while x < road.maxX {
                let shade = [0x8C8478, 0x7A7368, 0x9C9284, 0x6B655C, 0x857A6A][Int(r.unit() * 5)]
                ctx.setFillColor(cg(UInt32(shade)))
                let jitter = CGFloat(r.range(-1.5, 1.5))
                let rect = CGRect(x: x + 1.5 + jitter, y: y + 1.5, width: stone - 3, height: stone * 0.9 - 3)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.fillPath()
                ctx.setFillColor(cg(0xFFFFFF, 0.08))
                ctx.fill(CGRect(x: rect.minX + 2, y: rect.maxY - 4, width: rect.width - 4, height: 2))
                x += stone
            }
            y += stone * 0.9
            row += 1
        }
        return ctx.makeImage()!
    }

    static func gravel() -> CGImage {
        let w = 512, h = 512
        let ctx = context(w, h)
        ctx.setFillColor(cg(0xB59E7A))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        speckle(ctx, w: w, h: h, count: 14000, colors: [0x9C8664, 0xCDB894, 0x8A7556, 0xE0D0B0], size: 1...3.5, alpha: 0.5...1, seed: 13)
        return ctx.makeImage()!
    }

    /// Greyscale detail multiplied over terrain vertex colours.
    static func groundDetail() -> CGImage {
        let w = 512, h = 512
        let ctx = context(w, h)
        ctx.setFillColor(cg(0xE6E6E6))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        speckle(ctx, w: w, h: h, count: 26000, colors: [0xFFFFFF, 0xC8C8C8, 0xB0B0B0, 0xF2F2F2], size: 1...4, alpha: 0.3...0.8, seed: 21)
        return ctx.makeImage()!
    }

    // MARK: Sky

    static func sky(biome: RouteRecord.Biome) -> CGImage {
        let w = 1024, h = 512
        let ctx = context(w, h)
        let (zenith, horizon, ground): (UInt32, UInt32, UInt32)
        switch biome {
        case .coastal, .lakes: (zenith, horizon, ground) = (0x2C6DB5, 0xCFE6F5, 0x8FA9B8)
        case .urban: (zenith, horizon, ground) = (0x4A78B0, 0xDCE4EA, 0x9AA4A8)
        case .alpine: (zenith, horizon, ground) = (0x1F5DA8, 0xD9ECF7, 0x8AA0AE)
        default: (zenith, horizon, ground) = (0x3A73B8, 0xE2EEF2, 0x98AE9E)
        }
        let colors = [cg(ground), cg(horizon), cg(horizon), cg(zenith)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.47, 0.53, 1])!
        // CG origin is bottom-left: y = 0 is the bottom of the equirectangular image (nadir).
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        // Sun glow.
        let sun = CGPoint(x: CGFloat(w) * 0.30, y: CGFloat(h) * 0.72)
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [cg(0xFFF8E0, 0.95), cg(0xFFF2C0, 0.25), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 0.15, 1])!
        ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 140, options: [])
        // Wispy clouds.
        var r = SceneRandom(seed: 5)
        for _ in 0..<70 {
            let cx = r.range(0, Double(w)), cy = r.range(Double(h) * 0.56, Double(h) * 0.82)
            let rw = r.range(30, 140), rh = r.range(6, 20)
            ctx.setFillColor(cg(0xFFFFFF, CGFloat(r.range(0.05, 0.22))))
            ctx.fillEllipse(in: CGRect(x: cx, y: cy, width: rw, height: rh))
        }
        return ctx.makeImage()!
    }

    // MARK: Signage

    enum BannerStyle { case kom, finish, start, sector, lap }

    static func banner(_ text: String, style: BannerStyle, width: Int = 1024, height: Int = 160) -> CGImage {
        let ctx = context(width, height)
        let W = CGFloat(width), H = CGFloat(height)
        switch style {
        case .kom:
            ctx.setFillColor(cg(0xFFFFFF))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.setFillColor(cg(0xD62828))
            var y: CGFloat = 12
            var row = 0
            while y < H {
                var x: CGFloat = row % 2 == 0 ? 12 : 40
                while x < W {
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: 26, height: 26))
                    x += 56
                }
                y += 34
                row += 1
            }
        case .finish, .start, .lap:
            let sq = H / 4
            for i in 0..<Int(W / sq) + 1 {
                for j in 0..<4 {
                    ctx.setFillColor(cg((i + j) % 2 == 0 ? 0x111111 : 0xFFFFFF))
                    ctx.fill(CGRect(x: CGFloat(i) * sq, y: CGFloat(j) * sq, width: sq, height: sq))
                }
            }
        case .sector:
            ctx.setFillColor(cg(0x1D3557))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        // Text plate.
        let plate = CGRect(x: W * 0.12, y: H * 0.16, width: W * 0.76, height: H * 0.68)
        ctx.setFillColor(style == .kom ? cg(0xD62828) : (style == .sector ? cg(0xF4D35E) : cg(0x0D3B66)))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        drawText(text, in: ctx, rect: plate, color: style == .sector ? 0x1D3557 : 0xFFFFFF, maxSize: H * 0.48)
        return ctx.makeImage()!
    }

    static func marker(_ lines: [String], accent: UInt32) -> CGImage {
        let w = 256, h = 320
        let ctx = context(w, h)
        ctx.setFillColor(cg(0xF7F7F2))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(cg(accent))
        ctx.fill(CGRect(x: 0, y: CGFloat(h) * 0.72, width: CGFloat(w), height: CGFloat(h) * 0.28))
        let rowH = CGFloat(h) * 0.7 / CGFloat(max(lines.count, 1))
        for (i, l) in lines.enumerated() {
            let rect = CGRect(x: 8, y: CGFloat(h) * 0.7 - rowH * CGFloat(i + 1), width: CGFloat(w) - 16, height: rowH)
            drawText(l, in: ctx, rect: rect, color: 0x1A1A1A, maxSize: rowH * 0.7)
        }
        return ctx.makeImage()!
    }

    static func drawText(_ text: String, in ctx: CGContext, rect: CGRect, color: UInt32, maxSize: CGFloat) {
        var size = maxSize
        var line: CTLine
        var bounds: CGRect
        repeat {
            let font = NSFont.systemFont(ofSize: size, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(color),
            ]
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            size *= 0.92
        } while bounds.width > rect.width * 0.94 && size > 8
        ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, ctx)
    }
}
