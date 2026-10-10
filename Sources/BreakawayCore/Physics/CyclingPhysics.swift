import Foundation

/// The rider + bike system as the physics engine sees it.
public struct PhysicsBody: Sendable {
    /// Rider + bike + kit, kg.
    public var mass: Double
    /// Drag area, m².
    public var cda: Double
    /// Tyre rolling-resistance multiplier applied to the surface's base Crr.
    public var crrFactorSmooth: Double
    public var crrFactorRough: Double
    /// Drivetrain efficiency (chain, bearings).
    public var drivetrainEfficiency: Double
    /// Rotational inertia expressed as an equivalent extra mass (two wheels ≈ 0.14 kg·m² / r²).
    public var rotationalMass: Double

    public init(mass: Double, cda: Double, crrFactorSmooth: Double = 1, crrFactorRough: Double = 1,
                drivetrainEfficiency: Double = 0.976, rotationalMass: Double = 0.9) {
        self.mass = mass
        self.cda = cda
        self.crrFactorSmooth = crrFactorSmooth
        self.crrFactorRough = crrFactorRough
        self.drivetrainEfficiency = drivetrainEfficiency
        self.rotationalMass = rotationalMass
    }

    public func crr(on surface: Surface) -> Double {
        surface.baseCrr * (surface == .asphalt ? crrFactorSmooth : crrFactorRough)
    }
}

/// Road-cycling power model (Martin et al., 1998), the same physics used by
/// modern indoor-cycling platforms:
///
///   P·η = v · ( m·g·sin θ  +  Crr·m·g·cos θ  +  ½·ρ·CdA·(v + v_wind)²·(1 − draft) ) + m_eff·a·v
public enum CyclingPhysics {
    public static let gravity = 9.80665

    /// Air density from altitude (ISA, 15 °C at sea level).
    public static func airDensity(altitude: Double, temperatureC: Double = 15) -> Double {
        let p0 = 101_325.0, t0 = 288.15, lapse = 0.0065, r = 287.05
        let altitude = max(-400, min(altitude, 9000))
        let pressure = p0 * pow(1 - lapse * altitude / t0, 5.25588)
        return pressure / (r * (temperatureC + 273.15))
    }

    /// Total resistive force at speed `v` (m/s) on a slope `grade` (rise/run).
    public static func resistiveForce(speed v: Double, grade: Double, body: PhysicsBody, surface: Surface,
                                      airDensity rho: Double, headwind: Double = 0, draft: Double = 0) -> Double {
        let theta = atan(grade)
        let gravityForce = body.mass * gravity * sin(theta)
        let rolling = v > 0.05 ? body.crr(on: surface) * body.mass * gravity * cos(theta) : 0
        let air = v + headwind
        let aero = 0.5 * rho * body.cda * air * abs(air) * (1 - min(max(draft, 0), 0.6))
        return gravityForce + rolling + aero
    }

    /// Power (at the pedals) needed to hold a steady speed.
    public static func powerRequired(speed v: Double, grade: Double, body: PhysicsBody, surface: Surface = .asphalt,
                                     airDensity rho: Double = 1.225, headwind: Double = 0, draft: Double = 0) -> Double {
        let f = resistiveForce(speed: v, grade: grade, body: body, surface: surface, airDensity: rho, headwind: headwind, draft: draft)
        return max(0, f * v / body.drivetrainEfficiency)
    }

    /// Steady-state speed for a constant power (bisection — robust on any grade).
    public static func steadySpeed(power: Double, grade: Double, body: PhysicsBody, surface: Surface = .asphalt,
                                   airDensity rho: Double = 1.225, headwind: Double = 0, draft: Double = 0) -> Double {
        var lo = 0.0, hi = 40.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            let net = power * body.drivetrainEfficiency - resistiveForce(speed: mid, grade: grade, body: body, surface: surface,
                                                                         airDensity: rho, headwind: headwind, draft: draft) * mid
            if net > 0 { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Integrates speed over `dt` seconds with the rider producing `power` watts.
    public static func step(speed v: Double, power: Double, grade: Double, dt: Double, body: PhysicsBody, surface: Surface,
                            airDensity rho: Double, headwind: Double = 0, draft: Double = 0, braking: Double = 0) -> Double {
        // Sub-step for stability at large dt.
        let steps = max(1, Int(ceil(dt / 0.05)))
        let h = dt / Double(steps)
        var speed = max(0, v)
        let effectiveMass = body.mass + body.rotationalMass
        for _ in 0..<steps {
            // Propulsive force; below ~1 m/s cap it by a realistic standing-start force.
            let propulsive = min(power * body.drivetrainEfficiency / max(speed, 1.0), 0.9 * body.mass * gravity)
            let resist = resistiveForce(speed: speed, grade: grade, body: body, surface: surface,
                                        airDensity: rho, headwind: headwind, draft: draft)
            let brake = braking * body.mass * 3.0 * (speed > 0.1 ? 1 : 0)
            let a = (propulsive - resist - brake) / effectiveMass
            speed = max(0, speed + a * h)
        }
        return speed
    }
}

/// Aerodynamic shelter from riders ahead, modelled on wind-tunnel and CFD
/// studies of pelotons (Blocken et al. 2018): ~30 % saving one bike length
/// behind a single rider, more deep in a group, fading out by ~12 m.
public enum Drafting {
    /// Fractional drag reduction for a rider `gap` metres behind the wheel ahead,
    /// laterally offset by `lateral` metres, with `ridersAhead` in the group in front.
    public static func reduction(gap: Double, lateral: Double = 0, ridersAhead: Int = 1) -> Double {
        guard gap > 0.2, gap < 14, abs(lateral) < 1.6, ridersAhead > 0 else { return 0 }
        let longitudinal = 0.33 * exp(-(gap - 0.5) / 3.6)
        let lateralFactor = max(0, 1 - pow(abs(lateral) / 1.6, 2))
        let groupBonus = 1 + 0.18 * log(Double(min(ridersAhead, 40)))
        return min(0.55, longitudinal * lateralFactor * groupBonus)
    }
}
