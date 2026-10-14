import Foundation

/// The rider + bike system as the physics engine sees it.
public struct PhysicsBody: Sendable {
    /// Rider + bike + kit, kg.
    public var mass: Double
    /// Drag area on the hoods at zero yaw, m².
    public var cda: Double
    /// Tyre rolling-resistance multiplier applied to the surface's base Crr.
    public var crrFactorSmooth: Double
    public var crrFactorRough: Double
    /// Drivetrain efficiency (chain, bearings) used when no gear is specified.
    public var drivetrainEfficiency: Double
    /// Rotational inertia of the wheels expressed as an equivalent extra mass (I / r²).
    public var rotationalMass: Double
    /// Rim depth in metres. Deep rims "sail" in a crosswind and cut drag at yaw.
    public var rimDepth: Double

    public init(mass: Double, cda: Double, crrFactorSmooth: Double = 1, crrFactorRough: Double = 1,
                drivetrainEfficiency: Double = 0.976, rotationalMass: Double = 0.9, rimDepth: Double = 0.04) {
        self.mass = mass
        self.cda = cda
        self.crrFactorSmooth = crrFactorSmooth
        self.crrFactorRough = crrFactorRough
        self.drivetrainEfficiency = drivetrainEfficiency
        self.rotationalMass = rotationalMass
        self.rimDepth = rimDepth
    }

    /// Static rolling-resistance coefficient on a surface (before the speed term).
    public func crr(on surface: Surface) -> Double {
        surface.baseCrr * (surface == .asphalt ? crrFactorSmooth : crrFactorRough)
    }

    /// Drag area at an apparent-wind yaw angle `yaw` (radians) in a given riding position.
    ///
    /// Wind-tunnel sweeps of rider + bike show axial drag rising roughly with sin²β
    /// (more of the body is presented to the flow), while deep rims generate a forward
    /// "sail" component that peaks around 10–15° and fades as the rim stalls.
    public func cda(yaw: Double, posture: RiderPosture = .hoods) -> Double {
        let b = min(abs(yaw), .pi / 2)
        let s = sin(b)
        let rider = cda * posture.dragFactor * (1 + 0.35 * s * s)
        let stall = 0.35   // ~20°
        let sail = rimDepth * 0.16 * sin(min(b, stall) / stall * .pi / 2) * max(0, 1 - max(0, b - stall) / 0.5)
        return max(0.12, rider - sail)
    }
}

/// How the rider sits on the bike. Each position has a different drag area and is
/// animated by the 3D rider.
public enum RiderPosture: String, Codable, Sendable, CaseIterable {
    /// Hands on the brake hoods (reference position).
    case hoods
    /// Hands in the drops: lower torso, ~8 % less drag.
    case drops
    /// Descending tuck, chest on the top tube, not pedalling hard.
    case tuck
    /// Out of the saddle: torso upright and swinging, ~10 % more drag.
    case standing
    /// On time-trial extensions (TT bikes; the frame's drag factor already includes it).
    case aero

    public var dragFactor: Double {
        switch self {
        case .hoods, .aero: return 1.0
        case .drops: return 0.92
        case .tuck: return 0.80
        case .standing: return 1.10
        }
    }
}

/// Everything about the road and air around a rider at one instant.
public struct RideConditions: Sendable {
    /// Rise over run.
    public var grade: Double
    public var surface: Surface
    /// kg/m³.
    public var airDensity: Double
    /// Wind component against the direction of travel, m/s (negative = tailwind).
    public var headwind: Double
    /// Wind component across the direction of travel, m/s (sign = which side it comes from).
    public var crosswind: Double
    /// Fractional drag reduction from riders ahead (0…0.6).
    public var draft: Double
    public var posture: RiderPosture
    /// Drivetrain efficiency for the gear in use.
    public var drivetrainEfficiency: Double?

    public init(grade: Double = 0, surface: Surface = .asphalt, airDensity: Double = 1.225, headwind: Double = 0,
                crosswind: Double = 0, draft: Double = 0, posture: RiderPosture = .hoods, drivetrainEfficiency: Double? = nil) {
        self.grade = grade
        self.surface = surface
        self.airDensity = airDensity
        self.headwind = headwind
        self.crosswind = crosswind
        self.draft = draft
        self.posture = posture
        self.drivetrainEfficiency = drivetrainEfficiency
    }
}

/// Road-cycling power model after Martin et al. (1998), extended with yaw-dependent
/// drag, wheel-bearing friction (Dahn et al.), speed-dependent rolling losses
/// (tyre hysteresis and surface vibration) and cornering/braking limits:
///
///   P·η = v·( m·g·sin θ + Crr(v)·m·g·cos θ + F_bearing(v) + ½·ρ·CdA(β)·Vₐ·(v + w_h)·(1 − draft) ) + (m + I/r²)·a·v
public enum CyclingPhysics {
    public static let gravity = 9.80665

    /// Air density from altitude, temperature and relative humidity.
    ///
    /// Pressure follows the ISA barometric formula; humid air is lighter than dry air
    /// because water vapour (18 g/mol) displaces nitrogen and oxygen (~29 g/mol).
    public static func airDensity(altitude: Double, temperatureC: Double = 15, relativeHumidity: Double = 0) -> Double {
        let p0 = 101_325.0, t0 = 288.15, lapse = 0.0065
        let altitude = max(-400, min(altitude, 9000))
        let pressure = p0 * pow(1 - lapse * altitude / t0, 5.25588)
        let t = temperatureC + 273.15
        // Buck (1981) saturation vapour pressure, Pa.
        let es = 611.21 * exp((18.678 - temperatureC / 234.5) * (temperatureC / (257.14 + temperatureC)))
        let pv = max(0, min(1, relativeHumidity)) * es
        let pd = pressure - pv
        return pd / (287.058 * t) + pv / (461.495 * t)
    }

    /// Wheel-bearing friction force (Dahn et al., as used by Martin et al. 1998), N.
    public static func bearingForce(speed v: Double) -> Double {
        v > 0.05 ? 0.091 + 0.0087 * v : 0
    }

    /// Rolling-resistance coefficient including the speed-dependent part.
    /// On smooth tarmac it grows slowly with speed (tyre hysteresis); on cobbles and
    /// gravel the bike and rider are shaken harder the faster they go, and that
    /// vibration energy is lost (the "impedance" losses measured on pavé).
    public static func rollingCoefficient(speed v: Double, body: PhysicsBody, surface: Surface) -> Double {
        body.crr(on: surface) * (1 + surface.vibrationLoss * max(0, v))
    }

    /// Apparent-wind yaw angle for a rider at speed `v`.
    public static func yaw(speed v: Double, headwind: Double, crosswind: Double) -> Double {
        atan2(abs(crosswind), max(0.1, v + headwind))
    }

    /// Total resistive force at speed `v` (m/s), excluding braking.
    public static func resistiveForce(speed v: Double, body: PhysicsBody, conditions c: RideConditions) -> Double {
        let theta = atan(c.grade)
        let gravityForce = body.mass * gravity * sin(theta)
        let rolling = v > 0.05 ? rollingCoefficient(speed: v, body: body, surface: c.surface) * body.mass * gravity * cos(theta) : 0
        let axial = v + c.headwind
        let apparent = (axial * axial + c.crosswind * c.crosswind).squareRoot()
        let beta = atan2(abs(c.crosswind), abs(axial) + 1e-6)
        let shelter = 1 - min(max(c.draft, 0), 0.6)
        // Drag acts along the apparent wind; its component along the road is D·cos β = ½ρ·CdA·Vₐ·(v + w_h).
        let aero = 0.5 * c.airDensity * body.cda(yaw: beta, posture: c.posture) * apparent * axial * shelter
        return gravityForce + rolling + bearingForce(speed: v) + aero
    }

    /// Legacy convenience: still-air resistive force.
    public static func resistiveForce(speed v: Double, grade: Double, body: PhysicsBody, surface: Surface,
                                      airDensity rho: Double, headwind: Double = 0, draft: Double = 0) -> Double {
        resistiveForce(speed: v, body: body, conditions: RideConditions(grade: grade, surface: surface, airDensity: rho,
                                                                         headwind: headwind, draft: draft))
    }

    /// Power (at the pedals) needed to hold a steady speed.
    public static func powerRequired(speed v: Double, body: PhysicsBody, conditions c: RideConditions) -> Double {
        let f = resistiveForce(speed: v, body: body, conditions: c)
        return max(0, f * v / (c.drivetrainEfficiency ?? body.drivetrainEfficiency))
    }

    public static func powerRequired(speed v: Double, grade: Double, body: PhysicsBody, surface: Surface = .asphalt,
                                     airDensity rho: Double = 1.225, headwind: Double = 0, draft: Double = 0) -> Double {
        powerRequired(speed: v, body: body, conditions: RideConditions(grade: grade, surface: surface, airDensity: rho,
                                                                       headwind: headwind, draft: draft))
    }

    /// Steady-state speed for a constant power (bisection — robust on any grade).
    public static func steadySpeed(power: Double, body: PhysicsBody, conditions c: RideConditions) -> Double {
        let eta = c.drivetrainEfficiency ?? body.drivetrainEfficiency
        var lo = 0.0, hi = 40.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            let net = power * eta - resistiveForce(speed: mid, body: body, conditions: c) * mid
            if net > 0 { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    public static func steadySpeed(power: Double, grade: Double, body: PhysicsBody, surface: Surface = .asphalt,
                                   airDensity rho: Double = 1.225, headwind: Double = 0, draft: Double = 0) -> Double {
        steadySpeed(power: power, body: body, conditions: RideConditions(grade: grade, surface: surface, airDensity: rho,
                                                                        headwind: headwind, draft: draft))
    }

    /// Hard braking deceleration available on a surface, m/s² (dry road, both brakes).
    public static func maxBraking(on surface: Surface) -> Double {
        switch surface {
        case .asphalt: return 6.0
        case .gravel: return 3.5
        case .cobbles: return 4.0
        }
    }

    /// Integrates speed over `dt` seconds with the rider producing `power` watts.
    ///
    /// `speedLimit` is the fastest the rider can safely go here (corners ahead); above it
    /// they stop pedalling and brake, up to the surface's braking limit.
    public static func step(speed v: Double, power: Double, dt: Double, body: PhysicsBody, conditions c: RideConditions,
                            speedLimit: Double = .infinity) -> (speed: Double, braking: Bool) {
        // Sub-step for stability at large dt.
        let steps = max(1, Int(ceil(dt / 0.05)))
        let h = dt / Double(steps)
        var speed = max(0, v)
        var braked = false
        let effectiveMass = body.mass + body.rotationalMass
        let eta = c.drivetrainEfficiency ?? body.drivetrainEfficiency
        for _ in 0..<steps {
            let overLimit = speed > speedLimit + 0.05
            // Propulsive force; below ~1 m/s cap it by a realistic standing-start force.
            let propulsive = overLimit ? 0 : min(power * eta / max(speed, 1.0), 0.9 * body.mass * gravity)
            let resist = resistiveForce(speed: speed, body: body, conditions: c)
            var a = (propulsive - resist) / effectiveMass
            if overLimit {
                braked = true
                // Brake just hard enough to reach the limit, never harder than the tyres allow.
                let needed = (speed - speedLimit) / max(h, 0.1) + max(0, a)
                a -= min(maxBraking(on: c.surface), max(0, needed))
            }
            speed = max(0, speed + a * h)
        }
        return (speed, braked)
    }

    /// Legacy convenience used by tools and older call sites.
    public static func step(speed v: Double, power: Double, grade: Double, dt: Double, body: PhysicsBody, surface: Surface,
                            airDensity rho: Double, headwind: Double = 0, draft: Double = 0, braking: Double = 0) -> Double {
        let c = RideConditions(grade: grade, surface: surface, airDensity: rho, headwind: headwind, draft: draft)
        let limit = braking > 0 ? max(0, v - braking * 3.0 * dt) : .infinity
        return step(speed: v, power: power, dt: dt, body: body, conditions: c, speedLimit: limit).speed
    }
}

/// Aerodynamic shelter from riders ahead, modelled on wind-tunnel and CFD
/// studies of pelotons (Blocken et al. 2013, 2018): ~30 % saving one bike length
/// behind a single rider, more deep in a group, fading out by ~12–15 m. In a
/// crosswind the wake is carried downwind, so the sheltered spot moves to the side
/// of the wheel ahead — which is why echelons form.
public enum Drafting {
    /// Fractional drag reduction for a rider `gap` metres behind the wheel ahead,
    /// laterally offset by `lateral` metres from the centre of that rider's wake,
    /// with `ridersAhead` in the group in front.
    public static func reduction(gap: Double, lateral: Double = 0, ridersAhead: Int = 1) -> Double {
        guard gap > 0.2, gap < 14, abs(lateral) < 1.6, ridersAhead > 0 else { return 0 }
        let longitudinal = 0.33 * exp(-(gap - 0.5) / 3.6)
        let lateralFactor = max(0, 1 - pow(abs(lateral) / 1.6, 2))
        let groupBonus = 1 + 0.18 * log(Double(min(ridersAhead, 40)))
        return min(0.55, longitudinal * lateralFactor * groupBonus)
    }

    /// How far the wake of a rider `gap` metres ahead has drifted sideways at apparent
    /// yaw `yaw` (radians), metres. Positive = towards the side the wind blows to.
    public static func wakeOffset(gap: Double, yaw: Double) -> Double {
        gap * tan(min(abs(yaw), 0.7))
    }

    /// The small push the *leading* rider gets from a wheel-sucker right behind
    /// (the follower fills the low-pressure wake): ~2–3 % at half a wheel.
    public static func leaderBenefit(gapBehind: Double, lateral: Double = 0) -> Double {
        guard gapBehind > 0.2, gapBehind < 3, abs(lateral) < 0.8 else { return 0 }
        return 0.03 * exp(-(gapBehind - 0.3) / 0.9) * (1 - abs(lateral) / 0.8)
    }
}

/// How fast a bike can be ridden round a bend, and how early the rider brakes for it.
public enum Cornering {
    /// Usable lateral grip as a fraction of g (a confident but safe lean: ~35° on dry tarmac).
    public static func lateralGrip(on surface: Surface) -> Double {
        switch surface {
        case .asphalt: return 0.70
        case .cobbles: return 0.50
        case .gravel: return 0.45
        }
    }

    /// Comfortable braking used when planning for a corner ahead, m/s².
    public static func plannedBraking(on surface: Surface) -> Double {
        switch surface {
        case .asphalt: return 4.0
        case .cobbles: return 2.8
        case .gravel: return 2.4
        }
    }

    /// Maximum steady speed through a bend of radius `radius` metres:  v = √(μ·g·r).
    public static func cornerSpeed(radius: Double, surface: Surface) -> Double {
        (lateralGrip(on: surface) * CyclingPhysics.gravity * max(radius, 1)).squareRoot()
    }

    /// Bike lean angle for speed and path curvature: φ = atan(v²·κ / g).
    public static func leanAngle(speed: Double, curvature: Double) -> Double {
        atan(speed * speed * curvature / CyclingPhysics.gravity)
    }
}

/// Weather on the course.
public struct Weather: Codable, Hashable, Sendable {
    /// Mean wind speed at 10 m, m/s.
    public var windSpeed: Double
    /// Direction the wind blows *from*, degrees clockwise from north.
    public var windFromDegrees: Double
    /// Gust strength as a fraction of the mean wind.
    public var gustiness: Double
    /// Sea-level temperature, °C (falls 6.5 °C per km of altitude).
    public var temperatureC: Double
    /// Relative humidity 0…1.
    public var humidity: Double

    public init(windSpeed: Double, windFromDegrees: Double, gustiness: Double = 0.25, temperatureC: Double = 18, humidity: Double = 0.55) {
        self.windSpeed = windSpeed
        self.windFromDegrees = windFromDegrees
        self.gustiness = gustiness
        self.temperatureC = temperatureC
        self.humidity = humidity
    }

    public static let calm = Weather(windSpeed: 0, windFromDegrees: 0, gustiness: 0, temperatureC: 15, humidity: 0)

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case calm, typical, windy

        public var displayName: String {
            switch self {
            case .calm: return "Still air"
            case .typical: return "Typical breeze"
            case .windy: return "Windy"
            }
        }
    }

    /// Weather typical of the route's region and season (deterministic per route).
    public static func preset(_ preset: Preset, for route: Route) -> Weather {
        var rng = SplitMix64(seed: UInt64(route.id.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }.magnitude))
        let biome = route.record.biome
        // Prevailing directions: westerlies in northern Europe, sea breezes on the coast.
        let baseDir: Double
        switch biome {
        case .coastal: baseDir = 200
        case .alpine: baseDir = rng.range(0, 360)
        default: baseDir = 250
        }
        let dir = (baseDir + rng.range(-40, 40)).truncatingRemainder(dividingBy: 360)
        let temp: Double
        switch biome {
        case .coastal: temp = 22
        case .alpine: temp = 24
        case .urban: temp = 21
        default: temp = 17
        }
        switch preset {
        case .calm: return Weather(windSpeed: 0, windFromDegrees: dir, gustiness: 0, temperatureC: temp, humidity: 0.5)
        case .typical: return Weather(windSpeed: rng.range(2.5, 4.5), windFromDegrees: dir, gustiness: 0.3, temperatureC: temp, humidity: 0.55)
        case .windy: return Weather(windSpeed: rng.range(8, 10), windFromDegrees: dir, gustiness: 0.4, temperatureC: temp - 3, humidity: 0.6)
        }
    }

    /// Temperature at an altitude, °C.
    public func temperature(at altitude: Double) -> Double { temperatureC - 0.0065 * max(0, altitude) }

    public func airDensity(at altitude: Double) -> Double {
        CyclingPhysics.airDensity(altitude: altitude, temperatureC: temperature(at: altitude), relativeHumidity: humidity)
    }

    /// Fraction of the 10 m wind felt at rider height (log wind profile) for a landscape.
    /// Forests and towns shelter the road; open cols and coasts are exposed.
    public static func exposure(_ biome: RouteRecord.Biome) -> Double {
        switch biome {
        case .alpine: return 0.72
        case .coastal: return 0.75
        case .lakes: return 0.70
        case .countryside: return 0.66
        case .urban: return 0.42
        case .forest: return 0.35
        }
    }

    /// Wind at rider height relative to a direction of travel: (headwind, crosswind) in m/s.
    /// `direction` is the unit east/north travel vector; `gust` scales the mean wind.
    public func components(direction: LocalPoint, exposure: Double, gust: Double = 1) -> (head: Double, cross: Double) {
        let from = windFromDegrees * .pi / 180
        // Unit vector pointing where the wind comes FROM (east, north).
        let fx = sin(from), fy = cos(from)
        let w = windSpeed * exposure * max(0, gust)
        let head = w * (fx * direction.x + fy * direction.y)
        let cross = w * (fx * direction.y - fy * direction.x)   // + = from the rider's right
        return (head, cross)
    }
}

/// W′ balance (Skiba / Froncioni–Clarke differential model): the finite work a rider can
/// do above critical power, drained by efforts over CP and recovered exponentially below it.
public struct WPrimeBalance: Codable, Hashable, Sendable {
    /// Critical power, W (≈ FTP).
    public var cp: Double
    /// Capacity above CP, J.
    public var capacity: Double
    public private(set) var balance: Double

    public init(cp: Double, capacity: Double = 20_000) {
        self.cp = max(50, cp)
        self.capacity = max(1000, capacity)
        balance = self.capacity
    }

    public var fraction: Double { balance / capacity }

    public mutating func update(power: Double, dt: Double) {
        if power > cp {
            balance -= (power - cp) * dt
        } else {
            balance += (capacity - balance) * (cp - power) / capacity * dt
        }
        balance = min(capacity, max(0, balance))
    }
}

/// Chainrings, cassette and the gear in use. Gives realistic cadence for a speed and
/// the (small) efficiency differences between gears.
public struct Drivetrain: Codable, Hashable, Sendable {
    public var chainrings: [Int]
    public var cassette: [Int]
    public var front: Int
    public var rear: Int
    /// Wheel circumference, m (700×28c).
    public var circumference: Double

    public init(chainrings: [Int], cassette: [Int], circumference: Double = 2.136) {
        self.chainrings = chainrings
        self.cassette = cassette
        self.circumference = circumference
        front = chainrings.count - 1
        rear = cassette.count / 2
    }

    public static func forFrame(_ style: FrameStyle) -> Drivetrain {
        switch style {
        case .climbing: return Drivetrain(chainrings: [34, 50], cassette: [11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30, 34])
        case .gravel: return Drivetrain(chainrings: [42], cassette: [10, 11, 12, 13, 15, 17, 19, 21, 24, 28, 33, 38, 44])
        case .timeTrial: return Drivetrain(chainrings: [44, 56], cassette: [11, 12, 13, 14, 15, 16, 17, 19, 21, 23, 25, 28])
        case .track: return Drivetrain(chainrings: [39, 53], cassette: [11, 12, 13, 14, 15, 17, 19, 21, 23, 25, 28])
        case .steel: return Drivetrain(chainrings: [39, 52], cassette: [12, 13, 14, 15, 16, 17, 19, 21, 23, 26])
        default: return Drivetrain(chainrings: [36, 52], cassette: [11, 12, 13, 14, 15, 17, 19, 21, 24, 27, 30])
        }
    }

    public var frontTeeth: Int { chainrings[front] }
    public var rearTeeth: Int { cassette[rear] }
    public var ratio: Double { Double(frontTeeth) / Double(rearTeeth) }

    /// Metres travelled per crank revolution.
    public var development: Double { ratio * circumference }

    public func cadence(speed: Double) -> Double { speed / development * 60 }

    /// Chain efficiency: small sprockets articulate the chain through larger angles,
    /// and cross-chaining adds friction.
    public var efficiency: Double {
        var e = 0.986 - 0.13 / Double(rearTeeth)
        let n = cassette.count
        if chainrings.count > 1 {
            if front == chainrings.count - 1 && rear >= n - 2 { e -= 0.006 }
            if front == 0 && rear <= 1 { e -= 0.006 }
        }
        return e
    }

    /// Shifts towards the gear that gives `target` rpm at `speed`, with hysteresis so a
    /// rider doesn't hunt between neighbouring cogs. Front shifts only on big changes.
    public mutating func shift(speed: Double, target: Double) {
        guard speed > 0.5 else {
            front = 0
            rear = cassette.count - 2
            return
        }
        let current = abs(cadence(speed: speed) - target)
        var best = (front: front, rear: rear, err: current)
        for f in chainrings.indices {
            for r in cassette.indices {
                // Avoid the worst cross-chain combinations.
                if chainrings.count > 1 && ((f == chainrings.count - 1 && r == cassette.count - 1) || (f == 0 && r == 0)) { continue }
                var g = self
                g.front = f
                g.rear = r
                var err = abs(g.cadence(speed: speed) - target)
                if f != front { err += 7 }          // front shifts are a bigger deal
                if err < best.err { best = (f, r, err) }
            }
        }
        if current - best.err > 6 || current > 22 {
            if best.front != front {
                front = best.front
                rear = best.rear
            } else {
                // One sprocket at a time, like a real rider.
                rear += best.rear > rear ? 1 : (best.rear < rear ? -1 : 0)
            }
        }
    }
}
