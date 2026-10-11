import Foundation

public enum RideMode: String, Codable, CaseIterable, Sendable {
    case freeRide, groupRide, race, timeTrial, workout

    public var displayName: String {
        switch self {
        case .freeRide: return "Free Ride"
        case .groupRide: return "Group Ride"
        case .race: return "Race"
        case .timeTrial: return "Time Trial"
        case .workout: return "Workout"
        }
    }

    public var blurb: String {
        switch self {
        case .freeRide: return "Explore the route at your own pace with riders around you."
        case .groupRide: return "Hold the wheel of pace partners riding at a steady W/kg."
        case .race: return "Mass start against AI riders matched to your ability. Sprint for the line."
        case .timeTrial: return "Alone against the clock. No drafting — chase your personal best."
        case .workout: return "Structured intervals with ERG control while you ride the route."
        }
    }

    public var symbolName: String {
        switch self {
        case .freeRide: return "bicycle"
        case .groupRide: return "person.3.fill"
        case .race: return "flag.checkered"
        case .timeTrial: return "stopwatch"
        case .workout: return "chart.bar.fill"
        }
    }
}

/// Everything the world and HUD need to know about one rider.
public struct RiderState: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var nationCode: String
    public var isPlayer: Bool
    public var isPacer: Bool
    /// Total distance from the start line (keeps growing across laps).
    public var distance: Double
    public var speed: Double
    public var power: Double
    public var cadence: Double
    public var heartRate: Double?
    /// Metres right of the road centreline.
    public var lateral: Double
    public var draft: Double
    public var weightKg: Double
    public var kit: Kit
    public var bike: BikeSetup
    public var build: AvatarBuild
    public var finishTime: Double?
    /// Crank angle in radians, advanced from cadence (for animation).
    public var crankAngle: Double = 0
    /// Wheel rotation in radians (for animation).
    public var wheelAngle: Double = 0
    /// Riding position (drives drag and the 3D pose).
    public var posture: RiderPosture = .hoods
    /// True while braking for a bend ahead.
    public var isBraking = false
    /// Chainring and sprocket in use.
    public var gearFront = 50
    public var gearRear = 17
    /// W′ balance as a fraction of capacity (1 = fresh, 0 = empty).
    public var wPrime: Double = 1
    /// Apparent-wind yaw angle, radians, and the wind components felt (m/s).
    public var yaw: Double = 0
    public var headwind: Double = 0
    public var crosswind: Double = 0

    public var wattsPerKg: Double { power / max(weightKg, 30) }

    public init(id: String, name: String, nationCode: String, isPlayer: Bool, isPacer: Bool, distance: Double,
                speed: Double, power: Double, cadence: Double, heartRate: Double?, lateral: Double, draft: Double,
                weightKg: Double, kit: Kit, bike: BikeSetup, build: AvatarBuild, finishTime: Double? = nil) {
        self.id = id
        self.name = name
        self.nationCode = nationCode
        self.isPlayer = isPlayer
        self.isPacer = isPacer
        self.distance = distance
        self.speed = speed
        self.power = power
        self.cadence = cadence
        self.heartRate = heartRate
        self.lateral = lateral
        self.draft = draft
        self.weightKg = weightKg
        self.kit = kit
        self.bike = bike
        self.build = build
        self.finishTime = finishTime
    }
}

public struct PlayerInput: Sendable {
    public var power: Double
    public var cadence: Double
    public var heartRate: Double?

    public init(power: Double, cadence: Double, heartRate: Double? = nil) {
        self.power = power
        self.cadence = cadence
        self.heartRate = heartRate
    }
}

/// What the smart trainer should be doing right now.
public enum TrainerTarget: Equatable, Sendable {
    case none
    case erg(watts: Double)
    case simulation(gradePercent: Double, crr: Double, windSpeed: Double, windResistance: Double)
}

public struct ClimbEffort: Codable, Hashable, Sendable {
    public var climbName: String
    public var seconds: Double
    public var averagePower: Double
    public var lap: Int
    public var isPersonalBest: Bool
}

public enum RideEvent: Equatable, Sendable {
    case climbStarted(name: String, category: String, length: Double, averageGrade: Double)
    case climbFinished(name: String, seconds: Double, personalBest: Bool, previousBest: Double?)
    case lapCompleted(lap: Int, seconds: Double)
    case surfaceChanged(name: String, surface: Surface)
    case workoutStep(label: String, targetWatts: Double?)
    case workoutComplete
    case finished(position: Int?, seconds: Double)
    case passed(name: String)
}

/// AI rider behaviour.
struct BotBrain {
    var targetWkg: Double
    var variability: Double
    var climbBias: Double
    var sprintWkg: Double
    var isPacer: Bool
    var noise: Double = 0
    var attackRemaining: Double = 0
    var laneTarget: Double
    var rng: SplitMix64
    var cp: Double = 250
    var wPrime = WPrimeBalance(cp: 250)
    var drivetrain = Drivetrain.forFrame(.endurance)
    var postureTime: Double = 0
    var standPhase: Double = 0

    mutating func gaussian() -> Double {
        let u1 = max(rng.nextUnit(), 1e-12), u2 = rng.nextUnit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// Deterministic RNG so rides with the same seed replay identically (and tests are stable).
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * nextUnit() }
}

/// The ride: physics for the player and AI riders, drafting, laps, timed climbs,
/// workouts, trainer control targets and recording. UI-agnostic and deterministic.
public final class RideSimulation {
    public let route: Route
    public let laps: Int
    public let mode: RideMode
    public let profile: RiderProfile
    public let totalDistance: Double
    public private(set) var player: RiderState
    public private(set) var bots: [RiderState] = []
    public private(set) var elapsed: Double = 0
    public private(set) var isFinished = false
    public private(set) var workout: WorkoutProgress?
    public private(set) var completedClimbs: [ClimbEffort] = []
    public private(set) var activeClimb: (climb: Climb, startTime: Double, startEnergy: Double)?
    public private(set) var lapTimes: [Double] = []
    public let recorder = RideRecorder()

    /// Trainer difficulty (0–1): fraction of the real gradient the trainer simulates.
    public var trainerDifficulty: Double = 0.5
    /// Wind, temperature and humidity on the course.
    public let weather: Weather
    /// Riders brake for bends they can't take at full speed (descents, hairpins, city corners).
    public var cornerBraking = true
    public var ergEnabled = true
    /// Personal bests (seconds) keyed by `"<routeID>#<climb name>"`.
    public var personalBests: [String: Double]

    private var playerBody: PhysicsBody
    private var botBodies: [PhysicsBody] = []
    private var brains: [BotBrain] = []
    private var pendingEvents: [RideEvent] = []
    private var lastLapIndex = 0
    private var lastSurfaceName: String?
    private var lastWorkoutIndex: Int?
    private var playerEnergy = 0.0
    private var lastStandingPosition: Int?
    private var gust = 1.0
    private var weatherRNG: SplitMix64
    private let exposure: Double
    private var playerDrivetrain: Drivetrain
    private var playerWPrime: WPrimeBalance
    private var playerPostureTime: Double = 0

    public init(route: Route, laps: Int = 1, mode: RideMode, profile: RiderProfile, botCount: Int = 12,
                workout: Workout? = nil, personalBests: [String: Double] = [:], weather: Weather = .calm, seed: UInt64 = 42) {
        self.route = route
        self.weather = weather
        weatherRNG = SplitMix64(seed: seed &+ 0x5EED)
        exposure = Weather.exposure(route.record.biome)
        playerDrivetrain = Drivetrain.forFrame(profile.bike.frame.style)
        playerWPrime = WPrimeBalance(cp: profile.ftp, capacity: 20_000)
        self.laps = route.isLoop ? max(1, laps) : 1
        self.mode = mode
        self.profile = profile
        self.personalBests = personalBests
        totalDistance = route.length * Double(self.laps)
        playerBody = profile.physicsBody()
        player = RiderState(id: "player", name: profile.name, nationCode: profile.nationCode, isPlayer: true, isPacer: false,
                            distance: 0, speed: 0, power: 0, cadence: 0, heartRate: nil, lateral: 0.9, draft: 0,
                            weightKg: profile.weightKg, kit: profile.kit, bike: profile.bike, build: profile.build)
        player.posture = profile.bike.frame.style == .timeTrial ? .aero : .hoods
        if let workout { self.workout = WorkoutProgress(workout: workout) }
        spawnBots(count: mode == .timeTrial ? 0 : botCount, seed: seed)
    }

    // MARK: - Bots

    private static let botNames: [(String, String)] = [
        ("A. Moreau", "FR"), ("L. Bianchi", "IT"), ("J. Van Aert", "BE"), ("M. Kowalski", "PL"), ("S. García", "ES"),
        ("T. Andersen", "DK"), ("K. Müller", "DE"), ("R. Silva", "PT"), ("E. Novak", "SI"), ("H. Tanaka", "JP"),
        ("C. O'Brien", "IE"), ("D. Jansen", "NL"), ("P. Rossi", "IT"), ("N. Dubois", "FR"), ("O. Larsen", "NO"),
        ("B. Mwangi", "KE"), ("F. Herrera", "CO"), ("G. Thomas", "GB"), ("I. Petrov", "BG"), ("V. Horvat", "HR"),
        ("Z. Uwase", "RW"), ("M. Tremblay", "CA"), ("A. Nguyen", "AU"), ("E. Schmid", "CH"), ("R. Kelly", "US"),
        ("L. Svensson", "SE"), ("J. Martín", "ES"), ("T. Laine", "FI"), ("S. Moreno", "AR"), ("Y. Cohen", "IL"),
    ]

    private static let pacerLevels: [(name: String, wkg: Double)] = [
        ("Pace · 1.5 W/kg", 1.5), ("Pace · 2.2 W/kg", 2.2), ("Pace · 2.8 W/kg", 2.8), ("Pace · 3.4 W/kg", 3.4), ("Pace · 4.0 W/kg", 4.0),
    ]

    private func spawnBots(count: Int, seed: UInt64) {
        var rng = SplitMix64(seed: seed ^ UInt64(route.id.utf8.reduce(0) { $0 &* 31 &+ Int($1) }.magnitude))
        let ftpWkg = profile.wattsPerKg
        // Longer efforts are ridden at a lower fraction of FTP.
        let expectedMinutes = totalDistance / 1000 / 30 * 60 * (1 + route.elevationGain / max(totalDistance, 1) * 12)
        let intensity = expectedMinutes > 60 ? 0.82 : (expectedMinutes > 25 ? 0.9 : 0.97)
        let kits = Kit.presets.map(\.kit)
        let frames = Garage.frames.filter { $0.style != .timeTrial }

        var specs: [(name: String, nation: String, wkg: Double, pacer: Bool, start: Double)] = []
        if mode == .groupRide {
            for p in RideSimulation.pacerLevels {
                specs.append((p.name, "", p.wkg, true, rng.range(-30, 60)))
            }
        }
        let total = max(0, count - specs.count)
        for i in 0..<total {
            let n = RideSimulation.botNames[i % RideSimulation.botNames.count]
            let ability = rng.range(0.82, 1.14)
            let start: Double
            switch mode {
            case .race: start = -Double(i / 4) * 2.2 - rng.range(0, 1.5)   // grid behind the line
            default: start = rng.range(-250, 400)
            }
            specs.append((n.0, n.1, ftpWkg * ability * intensity, false, start))
        }
        for (i, s) in specs.enumerated() {
            let weight = rng.range(58, 82)
            let height = 165 + (weight - 58) * 0.9 + rng.range(-4, 4)
            var botProfile = RiderProfile(weightKg: weight, heightCm: height)
            let frame = frames[Int(rng.next() % UInt64(frames.count))]
            botProfile.bike = BikeSetup(frameID: frame.id, wheelsID: ["aero50", "deep80", "climber", "alloy"][Int(rng.next() % 4)])
            var kit = kits[i % kits.count]
            if !s.pacer {
                kit.jersey = KitColor(rng.range(0.1, 0.95), rng.range(0.1, 0.95), rng.range(0.1, 0.95))
                kit.jerseyAccent = KitColor(rng.range(0, 1), rng.range(0, 1), rng.range(0, 1))
                kit.skin = [KitColor(hex: 0xF1C27D), KitColor(hex: 0xC68E6A), KitColor(hex: 0x8D5A3B), KitColor(hex: 0x5C3A21), KitColor(hex: 0xE0AC8B)][i % 5]
            } else {
                kit.jersey = KitColor(hex: 0x00C2FF)
                kit.jerseyAccent = KitColor(hex: 0xFFFFFF)
            }
            let startDistance = route.isLoop ? s.start : max(0, s.start)
            var state = RiderState(id: "bot-\(i)", name: s.name, nationCode: s.nation, isPlayer: false, isPacer: s.pacer,
                                   distance: startDistance, speed: mode == .race ? 0 : 8, power: 0, cadence: 0, heartRate: nil,
                                   lateral: rng.range(-2.2, 2.2), draft: 0, weightKg: weight, kit: kit, bike: botProfile.bike,
                                   build: [.slim, .regular, .sprinter][i % 3])
            var brain = BotBrain(targetWkg: s.wkg, variability: s.pacer ? 0.02 : rng.range(0.04, 0.09),
                                 climbBias: rng.range(-0.5, 1.0), sprintWkg: rng.range(11, 17), isPacer: s.pacer,
                                 laneTarget: rng.range(-2, 2), rng: SplitMix64(seed: rng.next()))
            // Critical power ≈ the FTP this rider's target is a fraction of; W′ 14–26 kJ.
            brain.cp = s.pacer ? s.wkg * weight * 1.25 : s.wkg / intensity * weight
            brain.wPrime = WPrimeBalance(cp: brain.cp, capacity: rng.range(14_000, 26_000))
            brain.drivetrain = Drivetrain.forFrame(frame.style)
            brain.standPhase = rng.range(0, 60)
            state.gearFront = brain.drivetrain.frontTeeth
            state.gearRear = brain.drivetrain.rearTeeth
            bots.append(state)
            botBodies.append(botProfile.physicsBody())
            brains.append(brain)
        }
    }

    // MARK: - Queries

    public var lapDistance: Double { route.normalize(player.distance) }

    public var currentLap: Int { min(laps, Int(player.distance / route.length) + 1) }

    public var sample: TrackSample { route.sample(at: player.distance) }

    public var remainingDistance: Double { max(0, totalDistance - player.distance) }

    public var progress: Double { min(1, player.distance / totalDistance) }

    /// All riders, leader first.
    public var standings: [RiderState] {
        ([player] + bots).sorted { a, b in
            if let fa = a.finishTime, let fb = b.finishTime { return fa < fb }
            if a.finishTime != nil { return true }
            if b.finishTime != nil { return false }
            return a.distance > b.distance
        }
    }

    public var playerPosition: Int { (standings.firstIndex { $0.isPlayer } ?? 0) + 1 }

    public func drainEvents() -> [RideEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    public var trainerTarget: TrainerTarget {
        if mode == .workout, ergEnabled, let w = workout, let target = w.targetWatts(ftp: profile.ftp) {
            return .erg(watts: target)
        }
        let g = sample.grade * 100
        let effective = g >= 0 ? g * trainerDifficulty : g * trainerDifficulty * 0.5
        // Smart trainers compute air drag as ½·cw·(v + wind)²: hand them the rider's real drag
        // coefficient for the current position, yaw and shelter, and the headwind being felt.
        let p = player
        let cw = 0.5 * weather.airDensity(at: sample.elevation) * playerBody.cda(yaw: p.yaw, posture: p.posture) * (1 - p.draft)
        let crr = CyclingPhysics.rollingCoefficient(speed: p.speed, body: playerBody, surface: sample.surface)
        return .simulation(gradePercent: (effective * 10).rounded() / 10, crr: (crr * 10_000).rounded() / 10_000,
                           windSpeed: (p.headwind * 1000).rounded() / 1000, windResistance: (cw * 100).rounded() / 100)
    }

    // MARK: - Simulation step

    public func step(dt: Double, input: PlayerInput) {
        guard dt > 0, !isFinished else { return }
        let dt = min(dt, 0.25)
        elapsed += dt

        // --- Workout clock ---
        if var w = workout {
            w.elapsed += dt
            let idx = w.currentIndex
            if idx != lastWorkoutIndex {
                lastWorkoutIndex = idx
                if let seg = w.current {
                    pendingEvents.append(.workoutStep(label: seg.label, targetWatts: w.targetWatts(ftp: profile.ftp)))
                } else if w.isComplete {
                    pendingEvents.append(.workoutComplete)
                }
            }
            workout = w
        }

        // --- Wind gusts (Ornstein–Uhlenbeck around the mean, ~8 s correlation) ---
        if weather.windSpeed > 0 {
            let tau = 8.0
            let u1 = max(weatherRNG.nextUnit(), 1e-12), u2 = weatherRNG.nextUnit()
            let n = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            gust += -(gust - 1) / tau * dt + weather.gustiness * sqrt(2 * dt / tau) * n
            gust = max(0.2, min(2.2, gust))
        }
        updateWind(&player)
        for i in bots.indices { updateWind(&bots[i]) }

        // --- Drafting (computed from positions at the start of the step) ---
        let everyone = [player] + bots
        let drafts = everyone.map { rider -> Double in
            guard mode != .timeTrial || !rider.isPlayer else { return 0 }
            return draftFor(rider, among: everyone)
        }

        // --- Player ---
        let s = route.sample(at: player.distance)
        player.power = max(0, input.power)
        player.heartRate = input.heartRate
        player.draft = drafts[0]
        playerWPrime.cp = profile.ftp
        playerWPrime.update(power: player.power, dt: dt)
        player.wPrime = playerWPrime.fraction
        playerPostureTime += dt
        let playerPosture = RideSimulation.choosePosture(current: player.posture, held: playerPostureTime, speed: player.speed,
                                                         power: player.power, ftp: profile.ftp, grade: s.grade,
                                                         braking: player.isBraking, timeTrialBike: profile.bike.frame.style == .timeTrial,
                                                         clock: elapsed)
        if playerPosture != player.posture {
            player.posture = playerPosture
            playerPostureTime = 0
        }
        let playerConditions = RideConditions(grade: s.grade, surface: s.surface, airDensity: weather.airDensity(at: s.elevation),
                                              headwind: player.headwind, crosswind: player.crosswind, draft: player.draft,
                                              posture: player.posture, drivetrainEfficiency: playerDrivetrain.efficiency)
        let playerStep = CyclingPhysics.step(speed: player.speed, power: player.power, dt: dt, body: playerBody,
                                             conditions: playerConditions, speedLimit: speedLimit(at: player.distance))
        player.speed = playerStep.speed
        player.isBraking = playerStep.braking
        // Cadence from the sensor when there is one; otherwise from the virtual gear.
        playerDrivetrain.shift(speed: player.speed, target: input.cadence > 0 ? input.cadence : 88)
        if input.cadence > 0 {
            player.cadence = input.cadence
        } else {
            player.cadence = player.power > 10 ? min(130, playerDrivetrain.cadence(speed: player.speed)) : 0
        }
        player.gearFront = playerDrivetrain.frontTeeth
        player.gearRear = playerDrivetrain.rearTeeth
        let before = player.distance
        player.distance += player.speed * dt
        advanceAnimation(&player, dt: dt)
        player.lateral += (laneFor(player, among: everyone) - player.lateral) * min(1, dt * 0.8)
        playerEnergy += player.power * dt

        // --- Bots ---
        for i in bots.indices {
            stepBot(i, dt: dt, draft: drafts[i + 1], everyone: everyone)
        }

        // --- Bookkeeping ---
        trackClimbs(from: before, to: player.distance)
        trackLaps()
        trackSurface()
        trackOvertakes()
        let after = route.sample(at: player.distance)
        recorder.add(dt: dt, distance: player.distance, coordinate: after.coordinate, elevation: after.elevation,
                     speed: player.speed, power: player.power, cadence: player.cadence, heartRate: player.heartRate, grade: after.grade)

        if player.distance >= totalDistance {
            player.distance = totalDistance
            player.finishTime = elapsed
            isFinished = true
            pendingEvents.append(.finished(position: mode == .race ? playerPosition : nil, seconds: elapsed))
        }
    }

    private func speedLimit(at distance: Double) -> Double {
        cornerBraking ? route.safeSpeed(at: distance) : .infinity
    }

    /// Wind felt at rider height along and across the road at the rider's position.
    private func updateWind(_ r: inout RiderState) {
        guard weather.windSpeed > 0 else {
            r.headwind = 0
            r.crosswind = 0
            r.yaw = 0
            return
        }
        let w = weather.components(direction: route.direction(at: r.distance), exposure: exposure, gust: gust)
        r.headwind = w.head
        r.crosswind = w.cross
        r.yaw = CyclingPhysics.yaw(speed: r.speed, headwind: w.head, crosswind: w.cross)
    }

    /// Picks the riding position a real rider would use. Positions are held for at
    /// least ~1.5 s so riders don't flicker between them.
    static func choosePosture(current: RiderPosture, held: Double, speed: Double, power: Double, ftp: Double,
                              grade: Double, braking: Bool, timeTrialBike: Bool, clock: Double) -> RiderPosture {
        let ftp = max(ftp, 80)
        let desired: RiderPosture
        // Out of the saddle on steep ramps, in rhythm: ~12 s of every 45 s.
        let standWindow = (clock.truncatingRemainder(dividingBy: 45)) < 12
        if power > 1.6 * ftp && speed < 19 {
            desired = .standing                                     // attack or sprint
        } else if grade > 0.075 && power > 0.75 * ftp && standWindow && speed < 7 {
            desired = .standing
        } else if grade < -0.03 && speed > 12 && power < 0.35 * ftp && !braking {
            desired = .tuck
        } else if timeTrialBike {
            desired = grade > 0.05 || braking ? .hoods : .aero
        } else if braking || (speed > 11 && power > 0.6 * ftp && grade < 0.03) {
            desired = .drops
        } else {
            desired = .hoods
        }
        if desired == current { return current }
        // Sprints and braking can't wait; other changes are held a moment.
        if desired == .standing && power > 1.6 * ftp { return desired }
        if braking && current == .tuck { return desired }
        return held > 1.5 ? desired : current
    }

    private func advanceAnimation(_ r: inout RiderState, dt: Double) {
        if r.cadence > 0 {
            r.crankAngle = (r.crankAngle + r.cadence / 60 * 2 * .pi * dt).truncatingRemainder(dividingBy: 2 * .pi)
        } else {
            // Freewheeling riders bring the cranks level (3 and 9 o'clock).
            let level = r.crankAngle < .pi ? Double.pi / 2 : 3 * Double.pi / 2
            r.crankAngle += (level - r.crankAngle) * min(1, dt * 3)
        }
        r.wheelAngle = (r.wheelAngle + r.speed / 0.336 * dt).truncatingRemainder(dividingBy: 2 * .pi)
    }

    /// Lateral position of the centre of the wake of a rider `gap` metres ahead. In a
    /// crosswind from the right (+) the wake is carried to the left (−), and vice versa.
    private func wakeCentre(of other: RiderState, gap: Double, for rider: RiderState) -> Double {
        let drift = Drafting.wakeOffset(gap: gap, yaw: rider.yaw)
        return other.lateral - (rider.crosswind >= 0 ? 1 : -1) * drift
    }

    private func draftFor(_ rider: RiderState, among all: [RiderState]) -> Double {
        var best = 0.0, ahead = 0, leader = 0.0
        for other in all where other.id != rider.id && other.finishTime == nil {
            let gap = other.distance - rider.distance
            if gap < -0.2, gap > -3 {
                leader = max(leader, Drafting.leaderBenefit(gapBehind: -gap, lateral: other.lateral - rider.lateral))
            }
            guard gap > 0.2, gap < 14 else { continue }
            ahead += 1
        }
        guard ahead > 0 else { return leader }
        for other in all where other.id != rider.id && other.finishTime == nil {
            let gap = other.distance - rider.distance
            guard gap > 0.2, gap < 14 else { continue }
            let offset = rider.lateral - wakeCentre(of: other, gap: gap, for: rider)
            best = max(best, Drafting.reduction(gap: gap, lateral: offset, ridersAhead: ahead))
        }
        return min(0.6, best + leader)
    }

    /// Riders drift into the wake of the wheel in front when close enough to draft (the
    /// downwind side in a crosswind, so echelons form), pass slower riders blocking
    /// their line, and otherwise hold a lane.
    private func laneFor(_ rider: RiderState, among all: [RiderState]) -> Double {
        var best: RiderState?
        for other in all where other.id != rider.id && other.finishTime == nil {
            let gap = other.distance - rider.distance
            if gap > 0.8, gap < 18, best.map({ gap < $0.distance - rider.distance }) ?? true {
                best = other
            }
        }
        var target = rider.isPlayer ? 0.9 : rider.lateral
        if let b = best {
            let gap = b.distance - rider.distance
            target = wakeCentre(of: b, gap: gap, for: rider)
            // Coming up fast on a wheel: swing out and go round it.
            if gap < 4, rider.speed > b.speed + 0.4 {
                let side: Double = b.lateral > 0.3 ? -1 : 1
                target = b.lateral + side * 1.0
            }
        }
        // Don't ride through anyone alongside.
        for other in all where other.id != rider.id && abs(other.distance - rider.distance) < 1.8 {
            if abs(other.lateral - target) < 0.75 {
                target = other.lateral + (target >= other.lateral ? 0.8 : -0.8)
            }
        }
        return max(-2.7, min(2.7, target))
    }

    private func stepBot(_ i: Int, dt: Double, draft: Double, everyone: [RiderState]) {
        var bot = bots[i]
        guard bot.finishTime == nil else {
            bot.posture = .hoods
            bot.speed = max(0, bot.speed - 2 * dt)
            bot.power = 0
            bot.cadence = 0
            bot.distance += bot.speed * dt
            bots[i] = bot
            return
        }
        var brain = brains[i]
        let s = route.sample(at: bot.distance)
        let body = botBodies[i]

        // Ornstein–Uhlenbeck fluctuation around the target power.
        brain.noise += -brain.noise * dt / 20 + 0.35 * sqrt(dt) * brain.gaussian() * 0.3
        var power = brain.targetWkg * bot.weightKg * (1 + brain.variability * brain.noise * 3)

        if s.grade > 0.02 {
            power *= 1 + brain.climbBias * 0.08 * min(s.grade, 0.1) / 0.1
        } else if s.grade < -0.025 {
            power *= max(0.1, 1 + s.grade * 8)   // soft-pedal descents
        }
        if !brain.isPacer {
            if mode == .race {
                if brain.attackRemaining > 0 {
                    brain.attackRemaining -= dt
                    power *= 1.35
                    // Out of matches: the attack fizzles.
                    if brain.wPrime.fraction < 0.25 { brain.attackRemaining = 0 }
                } else if s.grade > 0.04, brain.wPrime.fraction > 0.6, brain.rng.nextUnit() < dt / 240 {
                    brain.attackRemaining = brain.rng.range(15, 40)
                }
                let toGo = totalDistance - bot.distance
                if toGo < 1200 { power *= 1 + (1200 - toGo) / 1200 * 0.35 }
                if toGo < 280 { power = max(power, brain.sprintWkg * bot.weightKg) }
            }
            // Riders a little ahead of the player ease up so groups form naturally in non-race modes.
            if mode == .freeRide || mode == .groupRide || mode == .workout {
                let gapToPlayer = bot.distance - player.distance
                if gapToPlayer > 20, gapToPlayer < 120 { power *= 0.93 }
                if gapToPlayer < -20, gapToPlayer > -120 { power *= 1.05 }
            }
        }
        // An empty W′ tank forces a rider back below critical power until it refills.
        if brain.wPrime.fraction < 0.08 { power = min(power, 0.93 * brain.cp) }
        if mode == .race, elapsed < 3 { power = 0 } // neutral start countdown
        // No point pedalling into a corner they are braking for.
        let limit = speedLimit(at: bot.distance)
        if bot.speed > limit - 0.3 { power *= 0.2 }

        bot.power = max(0, power)
        bot.draft = draft
        brain.wPrime.update(power: bot.power, dt: dt)
        bot.wPrime = brain.wPrime.fraction
        brain.postureTime += dt
        let posture = RideSimulation.choosePosture(current: bot.posture, held: brain.postureTime, speed: bot.speed, power: bot.power,
                                                   ftp: brain.cp, grade: s.grade, braking: bot.isBraking,
                                                   timeTrialBike: bot.bike.frame.style == .timeTrial, clock: elapsed + brain.standPhase)
        if posture != bot.posture {
            bot.posture = posture
            brain.postureTime = 0
        }
        let conditions = RideConditions(grade: s.grade, surface: s.surface, airDensity: weather.airDensity(at: s.elevation),
                                        headwind: bot.headwind, crosswind: bot.crosswind, draft: draft, posture: bot.posture,
                                        drivetrainEfficiency: brain.drivetrain.efficiency)
        let result = CyclingPhysics.step(speed: bot.speed, power: bot.power, dt: dt, body: body, conditions: conditions, speedLimit: limit)
        bot.speed = result.speed
        bot.isBraking = result.braking
        // Riders can't ride through each other: a rider boxed in right behind a slower
        // wheel has to ease off until there's room to pass.
        for other in everyone where other.id != bot.id && other.finishTime == nil {
            let gap = other.distance - bot.distance
            if gap > 0, gap < 2.1, abs(other.lateral - bot.lateral) < 0.6 {
                bot.speed = min(bot.speed, other.speed + max(0, gap - 1.75) * 2)
            }
        }
        bot.distance += bot.speed * dt
        // Cadence from the gear: spin on the flat, grind a little on climbs, stomp when standing.
        let targetCadence = bot.posture == .standing ? 72 : (s.grade > 0.05 ? 80 : 91) + brain.noise * 4
        brain.drivetrain.shift(speed: bot.speed, target: targetCadence)
        bot.gearFront = brain.drivetrain.frontTeeth
        bot.gearRear = brain.drivetrain.rearTeeth
        bot.cadence = bot.power < 15 || bot.isBraking ? 0 : max(40, min(125, brain.drivetrain.cadence(speed: bot.speed)))
        advanceAnimation(&bot, dt: dt)
        brain.laneTarget = laneFor(bot, among: everyone)
        bot.lateral += (brain.laneTarget - bot.lateral) * min(1, dt * 0.5)

        if bot.distance >= totalDistance, mode == .race {
            bot.finishTime = elapsed
        } else if !route.isLoop, bot.distance >= totalDistance {
            bot.finishTime = elapsed
        } else if route.isLoop, mode != .race {
            // Endless circuits for non-race modes: keep riding.
            if bot.distance > totalDistance + route.length { bot.distance -= route.length }
        }
        bots[i] = bot
        brains[i] = brain
    }

    // MARK: - Bookkeeping

    private func trackClimbs(from before: Double, to after: Double) {
        let d0 = route.normalize(before)
        let lapWrapped = route.isLoop && route.normalize(after) < d0
        let d1 = lapWrapped ? route.normalize(after) + route.length : route.normalize(after)

        if let active = activeClimb, d1 >= active.climb.endDistance || lapWrapped {
            let secs = elapsed - active.startTime
            let key = "\(route.id)#\(active.climb.name)"
            let previous = personalBests[key]
            let isPB = previous.map { secs < $0 } ?? true
            if isPB { personalBests[key] = secs }
            let avgP = (playerEnergy - active.startEnergy) / max(secs, 1)
            completedClimbs.append(ClimbEffort(climbName: active.climb.name, seconds: secs, averagePower: avgP,
                                               lap: currentLap, isPersonalBest: isPB))
            pendingEvents.append(.climbFinished(name: active.climb.name, seconds: secs, personalBest: isPB, previousBest: previous))
            activeClimb = nil
        }
        if activeClimb == nil {
            let start = lapWrapped ? 0 : d0
            let end = route.normalize(after)
            if let c = route.climbs.first(where: { $0.startDistance >= start && $0.startDistance <= end && end < $0.endDistance })
                ?? (elapsed < 0.5 ? route.climbs.first(where: { $0.startDistance <= end && end < $0.endDistance && $0.startDistance < 30 }) : nil) {
                activeClimb = (c, elapsed, playerEnergy)
                pendingEvents.append(.climbStarted(name: c.name, category: c.category.label, length: c.length, averageGrade: c.averageGrade))
            }
        }
    }

    private func trackLaps() {
        guard route.isLoop else { return }
        let lapIndex = Int(player.distance / route.length)
        if lapIndex > lastLapIndex, lapIndex <= laps {
            lastLapIndex = lapIndex
            let lapTime = elapsed - lapTimes.reduce(0, +)
            lapTimes.append(lapTime)
            if lapIndex < laps {
                pendingEvents.append(.lapCompleted(lap: lapIndex, seconds: lapTime))
            }
        }
    }

    private func trackSurface() {
        let section = route.surfaceSection(at: player.distance)
        if section?.name != lastSurfaceName {
            lastSurfaceName = section?.name
            if let section {
                pendingEvents.append(.surfaceChanged(name: section.name, surface: section.surface))
            }
        }
    }

    private func trackOvertakes() {
        guard mode == .race else { return }
        let pos = playerPosition
        if let last = lastStandingPosition, pos < last, let passed = standings.dropFirst(pos).first {
            pendingEvents.append(.passed(name: passed.name))
        }
        lastStandingPosition = pos
    }
}
