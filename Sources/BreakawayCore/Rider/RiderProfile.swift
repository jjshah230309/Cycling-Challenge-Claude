import Foundation

public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric, imperial
}

public enum AvatarBuild: String, Codable, CaseIterable, Sendable {
    case slim, regular, sprinter
}

public struct Kit: Codable, Hashable, Sendable {
    public var jersey: KitColor
    public var jerseyAccent: KitColor
    public var shorts: KitColor
    public var helmet: KitColor
    public var skin: KitColor

    public init(jersey: KitColor, jerseyAccent: KitColor, shorts: KitColor, helmet: KitColor, skin: KitColor) {
        self.jersey = jersey
        self.jerseyAccent = jerseyAccent
        self.shorts = shorts
        self.helmet = helmet
        self.skin = skin
    }

    public static let `default` = Kit(jersey: KitColor(hex: 0xF4D35E), jerseyAccent: KitColor(hex: 0x0D3B66),
                                      shorts: KitColor(hex: 0x141414), helmet: KitColor(hex: 0xFAFAFA),
                                      skin: KitColor(hex: 0xC68E6A))

    /// Famous jersey palettes (classification jerseys and world champion bands).
    public static let presets: [(name: String, kit: Kit)] = [
        ("Yellow", .default),
        ("Rainbow Bands", Kit(jersey: KitColor(hex: 0xFAFAFA), jerseyAccent: KitColor(hex: 0x1E88E5), shorts: KitColor(hex: 0x141414), helmet: KitColor(hex: 0xFAFAFA), skin: KitColor(hex: 0xC68E6A))),
        ("Maglia Rosa", Kit(jersey: KitColor(hex: 0xF4A7C0), jerseyAccent: KitColor(hex: 0x2B2B2B), shorts: KitColor(hex: 0x141414), helmet: KitColor(hex: 0xF4A7C0), skin: KitColor(hex: 0xE0AC8B))),
        ("Polka Dot", Kit(jersey: KitColor(hex: 0xFFFFFF), jerseyAccent: KitColor(hex: 0xD62828), shorts: KitColor(hex: 0x141414), helmet: KitColor(hex: 0xD62828), skin: KitColor(hex: 0x8D5A3B))),
        ("Green Points", Kit(jersey: KitColor(hex: 0x2A9D8F), jerseyAccent: KitColor(hex: 0xFFFFFF), shorts: KitColor(hex: 0x141414), helmet: KitColor(hex: 0x2A9D8F), skin: KitColor(hex: 0xF1C27D))),
        ("La Roja", Kit(jersey: KitColor(hex: 0xC1121F), jerseyAccent: KitColor(hex: 0xFDF0D5), shorts: KitColor(hex: 0x141414), helmet: KitColor(hex: 0x111111), skin: KitColor(hex: 0x5C3A21))),
    ]
}

/// The rider's persistent profile.
public struct RiderProfile: Codable, Hashable, Sendable {
    public var name: String
    public var weightKg: Double
    public var heightCm: Double
    public var ftp: Double
    public var maxHeartRate: Double
    public var units: UnitSystem
    public var build: AvatarBuild
    public var kit: Kit
    public var bike: BikeSetup
    public var xp: Int
    public var totalDistanceMeters: Double
    public var totalClimbMeters: Double
    public var totalRideSeconds: Double
    public var nationCode: String

    public init(name: String = "Rider", weightKg: Double = 72, heightCm: Double = 178, ftp: Double = 240,
                maxHeartRate: Double = 186, units: UnitSystem = .metric, build: AvatarBuild = .regular,
                kit: Kit = .default, bike: BikeSetup = BikeSetup(), xp: Int = 0, totalDistanceMeters: Double = 0,
                totalClimbMeters: Double = 0, totalRideSeconds: Double = 0, nationCode: String = "GB") {
        self.name = name
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.ftp = ftp
        self.maxHeartRate = maxHeartRate
        self.units = units
        self.build = build
        self.kit = kit
        self.bike = bike
        self.xp = xp
        self.totalDistanceMeters = totalDistanceMeters
        self.totalClimbMeters = totalClimbMeters
        self.totalRideSeconds = totalRideSeconds
        self.nationCode = nationCode
    }

    public var wattsPerKg: Double { ftp / max(weightKg, 30) }

    /// Rider frontal drag area on the hoods, scaled by body surface area (Du Bois).
    public var baseCdA: Double {
        let bsa = 0.007184 * pow(weightKg, 0.425) * pow(heightCm, 0.725)
        let reference = 0.007184 * pow(72.0, 0.425) * pow(178.0, 0.725)
        return 0.320 * bsa / reference
    }

    public func physicsBody(for bike: BikeSetup? = nil) -> PhysicsBody {
        let b = bike ?? self.bike
        let kitWeight = 1.2 // shoes, helmet, bottles
        return PhysicsBody(mass: weightKg + b.weight + kitWeight,
                           cda: baseCdA * b.frame.cdaFactor + b.wheels.cdaDelta,
                           crrFactorSmooth: b.wheels.crrSmoothFactor,
                           crrFactorRough: b.frame.roughSurfaceFactor * b.wheels.crrRoughFactor,
                           rotationalMass: 0.55 * b.wheels.weight)
    }

    // MARK: - Progression

    public static func xpForLevel(_ level: Int) -> Int {
        guard level > 1 else { return 0 }
        return Int(750 * pow(Double(level - 1), 1.55))
    }

    public var level: Int {
        var l = 1
        while RiderProfile.xpForLevel(l + 1) <= xp && l < 60 { l += 1 }
        return l
    }

    public var levelProgress: Double {
        let lo = RiderProfile.xpForLevel(level), hi = RiderProfile.xpForLevel(level + 1)
        return hi > lo ? Double(xp - lo) / Double(hi - lo) : 1
    }
}

/// Coggan power zones.
public enum PowerZone: Int, CaseIterable, Codable, Sendable {
    case recovery = 1, endurance, tempo, threshold, vo2max, anaerobic, neuromuscular

    public static func zone(power: Double, ftp: Double) -> PowerZone {
        guard ftp > 0 else { return .recovery }
        switch power / ftp {
        case ..<0.56: return .recovery
        case ..<0.76: return .endurance
        case ..<0.91: return .tempo
        case ..<1.06: return .threshold
        case ..<1.21: return .vo2max
        case ..<1.51: return .anaerobic
        default: return .neuromuscular
        }
    }

    public var name: String {
        switch self {
        case .recovery: return "Recovery"
        case .endurance: return "Endurance"
        case .tempo: return "Tempo"
        case .threshold: return "Threshold"
        case .vo2max: return "VO₂ Max"
        case .anaerobic: return "Anaerobic"
        case .neuromuscular: return "Neuromuscular"
        }
    }

    /// Zone colours (grey → blue → green → yellow → orange → red → purple).
    public var color: KitColor {
        switch self {
        case .recovery: return KitColor(hex: 0x9E9E9E)
        case .endurance: return KitColor(hex: 0x2F80ED)
        case .tempo: return KitColor(hex: 0x27AE60)
        case .threshold: return KitColor(hex: 0xF2C94C)
        case .vo2max: return KitColor(hex: 0xF2994A)
        case .anaerobic: return KitColor(hex: 0xEB5757)
        case .neuromuscular: return KitColor(hex: 0x9B51E0)
        }
    }
}

public enum Units {
    public static func speed(_ ms: Double, _ u: UnitSystem) -> (value: Double, unit: String) {
        u == .metric ? (ms * 3.6, "km/h") : (ms * 2.236_936, "mph")
    }

    public static func distance(_ m: Double, _ u: UnitSystem) -> (value: Double, unit: String) {
        u == .metric ? (m / 1000, "km") : (m / 1609.344, "mi")
    }

    public static func elevation(_ m: Double, _ u: UnitSystem) -> (value: Double, unit: String) {
        u == .metric ? (m, "m") : (m * 3.280_84, "ft")
    }

    public static func weight(_ kg: Double, _ u: UnitSystem) -> (value: Double, unit: String) {
        u == .metric ? (kg, "kg") : (kg * 2.204_62, "lb")
    }

    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
