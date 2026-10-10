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

    public init(route: Route, laps: Int = 1, mode: RideMode, profile: RiderProfile, botCount: Int = 12,
                workout: Workout? = nil, personalBests: [String: Double] = [:], seed: UInt64 = 42) {
        self.route = route
        self.laps = route.isLoop ? max(1, laps) : 1
        self.mode = mode
        self.profile = profile
        self.personalBests = personalBests
        totalDistance = route.length * Double(self.laps)
        playerBody = profile.physicsBody()
        player = RiderState(id: "player", name: profile.name, nationCode: profile.nationCode, isPlayer: true, isPacer: false,
                            distance: 0, speed: 0, power: 0, cadence: 0, heartRate: nil, lateral: 0.9, draft: 0,
                            weightKg: profile.weightKg, kit: profile.kit, bike: profile.bike, build: profile.build)
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
            let state = RiderState(id: "bot-\(i)", name: s.name, nationCode: s.nation, isPlayer: false, isPacer: s.pacer,
                                   distance: startDistance, speed: mode == .race ? 0 : 8, power: 0, cadence: 0, heartRate: nil,
                                   lateral: rng.range(-2.2, 2.2), draft: 0, weightKg: weight, kit: kit, bike: botProfile.bike,
                                   build: [.slim, .regular, .sprinter][i % 3])
            bots.append(state)
            botBodies.append(botProfile.physicsBody())
            brains.append(BotBrain(targetWkg: s.wkg, variability: s.pacer ? 0.02 : rng.range(0.04, 0.09),
                                   climbBias: rng.range(-0.5, 1.0), sprintWkg: rng.range(11, 17), isPacer: s.pacer,
                                   laneTarget: rng.range(-2, 2), rng: SplitMix64(seed: rng.next())))
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
        // Smart trainers model the rider's CdA themselves; hand them a realistic wind-resistance coefficient.
        let cw = 0.5 * CyclingPhysics.airDensity(altitude: sample.elevation) * playerBody.cda
        return .simulation(gradePercent: (effective * 10).rounded() / 10, crr: playerBody.crr(on: sample.surface),
                           windSpeed: 0, windResistance: cw)
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

        // --- Drafting (computed from positions at the start of the step) ---
        let everyone = [player] + bots
        let drafts = everyone.map { rider -> Double in
            guard mode != .timeTrial || !rider.isPlayer else { return 0 }
            return draftFor(rider, among: everyone)
        }

        // --- Player ---
        let s = route.sample(at: player.distance)
        let rho = CyclingPhysics.airDensity(altitude: s.elevation)
        player.power = max(0, input.power)
        player.cadence = input.cadence
        player.heartRate = input.heartRate
        player.draft = drafts[0]
        player.speed = CyclingPhysics.step(speed: player.speed, power: player.power, grade: s.grade, dt: dt, body: playerBody,
                                           surface: s.surface, airDensity: rho, draft: player.draft)
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

    private func advanceAnimation(_ r: inout RiderState, dt: Double) {
        r.crankAngle = (r.crankAngle + r.cadence / 60 * 2 * .pi * dt).truncatingRemainder(dividingBy: 2 * .pi)
        r.wheelAngle = (r.wheelAngle + r.speed / 0.336 * dt).truncatingRemainder(dividingBy: 2 * .pi)
    }

    private func draftFor(_ rider: RiderState, among all: [RiderState]) -> Double {
        var nearestGap = Double.infinity, nearestLateral = 0.0, ahead = 0
        for other in all where other.id != rider.id && other.finishTime == nil {
            let gap = other.distance - rider.distance
            guard gap > 0.2, gap < 14 else { continue }
            ahead += 1
            if gap < nearestGap {
                nearestGap = gap
                nearestLateral = other.lateral - rider.lateral
            }
        }
        guard ahead > 0 else { return 0 }
        return Drafting.reduction(gap: nearestGap, lateral: nearestLateral, ridersAhead: ahead)
    }

    /// Riders drift onto the wheel in front when close enough to draft, otherwise hold a lane.
    private func laneFor(_ rider: RiderState, among all: [RiderState]) -> Double {
        var best: RiderState?
        for other in all where other.id != rider.id {
            let gap = other.distance - rider.distance
            if gap > 0.8, gap < 18, best.map({ gap < $0.distance - rider.distance }) ?? true {
                best = other
            }
        }
        var target = best?.lateral ?? (rider.isPlayer ? 0.9 : rider.lateral)
        // Don't ride through anyone alongside.
        for other in all where other.id != rider.id && abs(other.distance - rider.distance) < 1.8 {
            if abs(other.lateral - target) < 0.75 {
                target = other.lateral + (target >= other.lateral ? 0.8 : -0.8)
            }
        }
        return max(-2.6, min(2.6, target))
    }

    private func stepBot(_ i: Int, dt: Double, draft: Double, everyone: [RiderState]) {
        var bot = bots[i]
        guard bot.finishTime == nil else {
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
                } else if s.grade > 0.04, brain.rng.nextUnit() < dt / 240 {
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
        if mode == .race, elapsed < 3 { power = 0 } // neutral start countdown

        let rho = CyclingPhysics.airDensity(altitude: s.elevation)
        bot.power = max(0, power)
        bot.draft = draft
        bot.speed = CyclingPhysics.step(speed: bot.speed, power: bot.power, grade: s.grade, dt: dt, body: body,
                                        surface: s.surface, airDensity: rho, draft: draft)
        bot.distance += bot.speed * dt
        bot.cadence = bot.power < 15 ? 0 : max(65, min(105, 88 - s.grade * 120 + brain.noise * 6))
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
