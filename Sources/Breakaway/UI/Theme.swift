import BreakawayCore
import SwiftUI

enum Theme {
    static let background = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let panelRaised = Color(red: 0.15, green: 0.16, blue: 0.20)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.10)
    static let accentSoft = Color(red: 1.0, green: 0.42, blue: 0.10).opacity(0.18)
    static let kom = Color(red: 0.84, green: 0.16, blue: 0.16)
    static let good = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let info = Color(red: 0.25, green: 0.65, blue: 1.0)
    static let secondaryText = Color.white.opacity(0.62)

    static func zone(_ power: Double, ftp: Double) -> Color {
        let c = PowerZone.zone(power: power, ftp: ftp).color
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func color(_ c: KitColor) -> Color { Color(red: c.r, green: c.g, blue: c.b) }

    static func gradeColor(_ grade: Double) -> Color {
        switch grade {
        case ..<0.01: return Color(red: 0.35, green: 0.75, blue: 0.4)
        case ..<0.04: return Color(red: 0.95, green: 0.82, blue: 0.3)
        case ..<0.07: return Color(red: 0.98, green: 0.6, blue: 0.2)
        case ..<0.10: return Color(red: 0.93, green: 0.3, blue: 0.2)
        default: return Color(red: 0.55, green: 0.1, blue: 0.1)
        }
    }
}

extension KitColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }
}

struct StatBlock: View {
    var label: String
    var value: String
    var unit: String = ""
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText) }
            }
        }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .heavy, design: .rounded))
            if let subtitle { Text(subtitle).foregroundStyle(Theme.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PillButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(prominent ? color : color.opacity(0.18), in: Capsule())
            .foregroundStyle(prominent ? Color.black : color)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Small elevation profile used in lists and cards.
struct ProfileSparkline: View {
    let route: Route
    var highlight: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let prof = route.profile(samples: 160)
            let lo = route.minElevation, hi = max(route.maxElevation, lo + 30)
            func pt(_ d: Double, _ e: Double) -> CGPoint {
                CGPoint(x: d / route.length * size.width, y: size.height - (e - lo) / (hi - lo) * size.height * 0.9 - 1)
            }
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            for p in prof { fill.addLine(to: pt(p.distance, p.elevation)) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.65), Theme.accent.opacity(0.08)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            var line = Path()
            for (i, p) in prof.enumerated() {
                if i == 0 { line.move(to: pt(p.distance, p.elevation)) } else { line.addLine(to: pt(p.distance, p.elevation)) }
            }
            ctx.stroke(line, with: .color(Theme.accent), lineWidth: 1.5)
            if let h = highlight {
                let x = h / route.length * size.width
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            }
        }
    }
}

extension View {
    func panelBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
