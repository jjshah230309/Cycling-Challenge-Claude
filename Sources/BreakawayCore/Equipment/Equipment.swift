import Foundation

/// Visual + physical archetype of a frame. Names are original; each frame
/// represents a class of real bikes rather than a specific brand.
public enum FrameStyle: String, Codable, CaseIterable, Sendable {
    case aero, climbing, timeTrial, endurance, gravel, steel, track
}

public enum HandlebarStyle: String, Codable, Sendable {
    case drops, aeroDrops, timeTrialExtensions, flaredDrops, bullhorn
}

public struct KitColor: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    public var hex: UInt32 {
        (UInt32(max(0, min(255, r * 255)).rounded()) << 16) | (UInt32(max(0, min(255, g * 255)).rounded()) << 8) | UInt32(max(0, min(255, b * 255)).rounded())
    }
}

public struct Frame: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var style: FrameStyle
    public var handlebar: HandlebarStyle
    /// Frame, fork, groupset, bars, saddle — everything except wheels, kg.
    public var weight: Double
    /// Multiplier on the rider's drag area (position + frame aerodynamics).
    public var cdaFactor: Double
    /// Rolling-resistance multiplier on rough surfaces (tyre width / compliance).
    public var roughSurfaceFactor: Double
    public var tubeScale: Double
    public var color: KitColor
    public var accent: KitColor
    public var unlockLevel: Int
    public var blurb: String
}

public struct Wheelset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var rimDepthMM: Double
    public var rearDisc: Bool
    public var tyreWidthMM: Double
    /// Pair weight, kg.
    public var weight: Double
    /// Change in drag area, m² (negative = faster).
    public var cdaDelta: Double
    public var crrSmoothFactor: Double
    public var crrRoughFactor: Double
    public var knobbly: Bool
    public var unlockLevel: Int
    public var blurb: String
}

public enum Garage {
    public static let frames: [Frame] = [
        Frame(id: "allroad", name: "Allroad Endurance", style: .endurance, handlebar: .drops, weight: 7.6,
              cdaFactor: 1.03, roughSurfaceFactor: 0.88, tubeScale: 1.0,
              color: KitColor(hex: 0x2F6FDE), accent: KitColor(hex: 0xF2F2F2), unlockLevel: 1,
              blurb: "Relaxed geometry and compliant stays. A dependable all-rounder."),
        Frame(id: "summit", name: "Summit SL", style: .climbing, handlebar: .drops, weight: 6.1,
              cdaFactor: 1.0, roughSurfaceFactor: 1.0, tubeScale: 0.85,
              color: KitColor(hex: 0xD7263D), accent: KitColor(hex: 0x1B1B1E), unlockLevel: 1,
              blurb: "Featherweight climbing frame with skinny round tubes. Built for the Stelvio."),
        Frame(id: "apex", name: "Apex Aero", style: .aero, handlebar: .aeroDrops, weight: 7.0,
              cdaFactor: 0.955, roughSurfaceFactor: 1.05, tubeScale: 1.3,
              color: KitColor(hex: 0x111111), accent: KitColor(hex: 0x00D1B2), unlockLevel: 3,
              blurb: "Truncated-aerofoil tubes and an integrated cockpit. Fastest road bike on the flat."),
        Frame(id: "velocity", name: "Velocity TT", style: .timeTrial, handlebar: .timeTrialExtensions, weight: 8.4,
              cdaFactor: 0.80, roughSurfaceFactor: 1.1, tubeScale: 1.45,
              color: KitColor(hex: 0xF5F5F5), accent: KitColor(hex: 0xE63946), unlockLevel: 6,
              blurb: "Low, long and narrow. Unbeatable against the clock, a handful on hairpins."),
        Frame(id: "nomad", name: "Nomad Gravel", style: .gravel, handlebar: .flaredDrops, weight: 8.6,
              cdaFactor: 1.06, roughSurfaceFactor: 0.72, tubeScale: 1.1,
              color: KitColor(hex: 0x6B8F71), accent: KitColor(hex: 0xE9C46A), unlockLevel: 2,
              blurb: "Wide clearance and stable handling. Floats over the Arenberg cobbles."),
        Frame(id: "heritage", name: "Heritage Steel", style: .steel, handlebar: .drops, weight: 9.4,
              cdaFactor: 1.04, roughSurfaceFactor: 0.85, tubeScale: 0.7,
              color: KitColor(hex: 0x1D3557), accent: KitColor(hex: 0xC0C0C0), unlockLevel: 4,
              blurb: "Lugged steel tubes and polished silver. Ride like it's 1985."),
        Frame(id: "piste", name: "Piste Track", style: .track, handlebar: .bullhorn, weight: 7.2,
              cdaFactor: 0.94, roughSurfaceFactor: 1.15, tubeScale: 1.2,
              color: KitColor(hex: 0xFFB703), accent: KitColor(hex: 0x023047), unlockLevel: 8,
              blurb: "Stiff, aggressive pursuit geometry. Single gear, maximum attitude."),
    ]

    public static let wheels: [Wheelset] = [
        Wheelset(id: "alloy", name: "Alloy Trainer 25", rimDepthMM: 25, rearDisc: false, tyreWidthMM: 28, weight: 1.75,
                 cdaDelta: 0.004, crrSmoothFactor: 1.0, crrRoughFactor: 0.95, knobbly: false, unlockLevel: 1,
                 blurb: "Bombproof box-section alloy rims."),
        Wheelset(id: "climber", name: "Carbon Climber 32", rimDepthMM: 32, rearDisc: false, tyreWidthMM: 26, weight: 1.22,
                 cdaDelta: 0.002, crrSmoothFactor: 0.97, crrRoughFactor: 1.05, knobbly: false, unlockLevel: 2,
                 blurb: "Ultralight shallow carbon. Every gram counts on 10% ramps."),
        Wheelset(id: "aero50", name: "Carbon Aero 50", rimDepthMM: 50, rearDisc: false, tyreWidthMM: 28, weight: 1.45,
                 cdaDelta: -0.006, crrSmoothFactor: 0.95, crrRoughFactor: 1.0, knobbly: false, unlockLevel: 1,
                 blurb: "The sweet spot of weight and aerodynamics."),
        Wheelset(id: "deep80", name: "Deep Section 80", rimDepthMM: 80, rearDisc: false, tyreWidthMM: 28, weight: 1.78,
                 cdaDelta: -0.011, crrSmoothFactor: 0.95, crrRoughFactor: 1.05, knobbly: false, unlockLevel: 5,
                 blurb: "Deep rims that hum at 50 km/h."),
        Wheelset(id: "disc", name: "Disc + 80 TT", rimDepthMM: 80, rearDisc: true, tyreWidthMM: 25, weight: 2.05,
                 cdaDelta: -0.016, crrSmoothFactor: 0.94, crrRoughFactor: 1.15, knobbly: false, unlockLevel: 6,
                 blurb: "Full rear disc for the race of truth."),
        Wheelset(id: "gravel40", name: "Gravel 40 Tubeless", rimDepthMM: 30, rearDisc: false, tyreWidthMM: 40, weight: 1.72,
                 cdaDelta: 0.009, crrSmoothFactor: 1.12, crrRoughFactor: 0.7, knobbly: true, unlockLevel: 2,
                 blurb: "Low-pressure 40 mm rubber. Slow on tarmac, magic on cobbles."),
    ]

    public static func frame(id: String) -> Frame { frames.first { $0.id == id } ?? frames[0] }
    public static func wheelset(id: String) -> Wheelset { wheels.first { $0.id == id } ?? wheels[0] }
}

/// A frame + wheelset combination.
public struct BikeSetup: Codable, Hashable, Sendable {
    public var frameID: String
    public var wheelsID: String

    public init(frameID: String = "allroad", wheelsID: String = "aero50") {
        self.frameID = frameID
        self.wheelsID = wheelsID
    }

    public var frame: Frame { Garage.frame(id: frameID) }
    public var wheels: Wheelset { Garage.wheelset(id: wheelsID) }
    public var weight: Double { frame.weight + wheels.weight }

    /// Relative ratings 0–100 for the garage UI.
    public var aeroRating: Double {
        let cda = 0.32 * frame.cdaFactor + wheels.cdaDelta
        return max(0, min(100, (0.34 - cda) / (0.34 - 0.24) * 100))
    }

    public var climbRating: Double {
        max(0, min(100, (12.0 - weight) / (12.0 - 7.2) * 100))
    }

    public var roughRating: Double {
        let f = frame.roughSurfaceFactor * wheels.crrRoughFactor
        return max(0, min(100, (1.2 - f) / (1.2 - 0.5) * 100))
    }
}
