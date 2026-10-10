import Foundation

/// One-second ride sample (the resolution used by FIT/GPX exports and analysis).
public struct RideSample: Codable, Hashable, Sendable {
    public var t: Double
    public var distance: Double
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double
    public var speed: Double
    public var power: Double
    public var cadence: Double
    public var heartRate: Double?
    public var grade: Double
}

/// Accumulates simulation ticks into 1 Hz samples.
public final class RideRecorder {
    public private(set) var samples: [RideSample] = []
    private var bucketTime = 0.0
    private var bucket = (power: 0.0, cadence: 0.0, speed: 0.0, hr: 0.0, hrTime: 0.0)
    private var elapsed = 0.0

    public init() {}

    public func add(dt: Double, distance: Double, coordinate: GeoCoordinate, elevation: Double, speed: Double,
                    power: Double, cadence: Double, heartRate: Double?, grade: Double) {
        elapsed += dt
        bucketTime += dt
        bucket.power += power * dt
        bucket.cadence += cadence * dt
        bucket.speed += speed * dt
        if let hr = heartRate {
            bucket.hr += hr * dt
            bucket.hrTime += dt
        }
        guard bucketTime >= 1 else { return }
        samples.append(RideSample(t: elapsed.rounded(), distance: distance, latitude: coordinate.latitude,
                                  longitude: coordinate.longitude, elevation: elevation,
                                  speed: bucket.speed / bucketTime, power: bucket.power / bucketTime,
                                  cadence: bucket.cadence / bucketTime,
                                  heartRate: bucket.hrTime > 0 ? bucket.hr / bucket.hrTime : nil, grade: grade))
        bucketTime = 0
        bucket = (0, 0, 0, 0, 0)
    }
}

/// Summary statistics for a ride.
public struct RideMetrics: Codable, Hashable, Sendable {
    public var duration: Double = 0
    public var distance: Double = 0
    public var elevationGain: Double = 0
    public var averageSpeed: Double = 0
    public var maxSpeed: Double = 0
    public var averagePower: Double = 0
    public var maxPower: Double = 0
    public var normalizedPower: Double = 0
    public var intensityFactor: Double = 0
    public var trainingStressScore: Double = 0
    public var kilojoules: Double = 0
    public var averageCadence: Double = 0
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    /// Best average power for standard durations (seconds → watts).
    public var powerCurve: [Int: Double] = [:]
    /// Seconds spent in each Coggan zone (index 0 = Z1).
    public var zoneSeconds: [Double] = Array(repeating: 0, count: 7)

    public init() {}

    /// Human energy expenditure ≈ mechanical work / gross efficiency (~24 %) ≈ kJ in kcal.
    public var calories: Double { kilojoules / (0.24 * 4.184) }
}

public enum PowerAnalysis {
    public static let curveDurations = [5, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]

    /// Normalized Power: 30 s rolling average, raised to the 4th power, averaged, 4th root.
    public static func normalizedPower(_ watts: [Double]) -> Double {
        guard watts.count >= 30 else { return watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count) }
        var sum = watts[0..<30].reduce(0, +)
        var acc = pow(sum / 30, 4)
        var n = 1.0
        for i in 30..<watts.count {
            sum += watts[i] - watts[i - 30]
            acc += pow(sum / 30, 4)
            n += 1
        }
        return pow(acc / n, 0.25)
    }

    /// Best rolling average for a window length (seconds, 1 Hz samples).
    public static func bestAverage(_ watts: [Double], window: Int) -> Double? {
        guard window > 0, watts.count >= window else { return nil }
        var sum = watts[0..<window].reduce(0, +)
        var best = sum
        for i in window..<watts.count {
            sum += watts[i] - watts[i - window]
            best = max(best, sum)
        }
        return best / Double(window)
    }

    public static func metrics(samples: [RideSample], ftp: Double) -> RideMetrics {
        var m = RideMetrics()
        guard let first = samples.first, let last = samples.last else { return m }
        let watts = samples.map(\.power)
        m.duration = last.t - first.t + 1
        m.distance = last.distance
        for (a, b) in zip(samples, samples.dropFirst()) where b.elevation > a.elevation {
            m.elevationGain += b.elevation - a.elevation
        }
        m.averageSpeed = m.duration > 0 ? m.distance / m.duration : 0
        m.maxSpeed = samples.map(\.speed).max() ?? 0
        m.averagePower = watts.reduce(0, +) / Double(watts.count)
        m.maxPower = watts.max() ?? 0
        m.normalizedPower = normalizedPower(watts)
        if ftp > 0 {
            m.intensityFactor = m.normalizedPower / ftp
            m.trainingStressScore = m.duration * m.normalizedPower * m.intensityFactor / (ftp * 3600) * 100
        }
        m.kilojoules = watts.reduce(0, +) / 1000
        let pedalling = samples.filter { $0.cadence > 0 }
        m.averageCadence = pedalling.isEmpty ? 0 : pedalling.map(\.cadence).reduce(0, +) / Double(pedalling.count)
        let hrs = samples.compactMap(\.heartRate)
        if !hrs.isEmpty {
            m.averageHeartRate = hrs.reduce(0, +) / Double(hrs.count)
            m.maxHeartRate = hrs.max()
        }
        for d in curveDurations {
            if let best = bestAverage(watts, window: d) { m.powerCurve[d] = best }
        }
        for w in watts {
            m.zoneSeconds[PowerZone.zone(power: w, ftp: ftp).rawValue - 1] += 1
        }
        return m
    }
}

/// A completed ride as stored in the rider's history.
public struct RideSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var routeID: String
    public var routeName: String
    public var mode: RideMode
    public var laps: Int
    public var workoutName: String?
    public var finishPosition: Int?
    public var riders: Int
    public var completed: Bool
    public var metrics: RideMetrics
    public var climbs: [ClimbEffort]
    public var xpEarned: Int
    public var ftpAtTime: Double
    public var weightAtTime: Double

    public init(id: UUID = UUID(), date: Date, routeID: String, routeName: String, mode: RideMode, laps: Int,
                workoutName: String?, finishPosition: Int?, riders: Int, completed: Bool, metrics: RideMetrics,
                climbs: [ClimbEffort], xpEarned: Int, ftpAtTime: Double, weightAtTime: Double) {
        self.id = id
        self.date = date
        self.routeID = routeID
        self.routeName = routeName
        self.mode = mode
        self.laps = laps
        self.workoutName = workoutName
        self.finishPosition = finishPosition
        self.riders = riders
        self.completed = completed
        self.metrics = metrics
        self.climbs = climbs
        self.xpEarned = xpEarned
        self.ftpAtTime = ftpAtTime
        self.weightAtTime = weightAtTime
    }

    /// XP: 20 per km, 1 per metre climbed, bonuses for finishing structured work and podiums.
    public static func xp(distance: Double, climb: Double, completedWorkout: Bool, position: Int?) -> Int {
        var xp = Int(distance / 1000 * 20) + Int(climb)
        if completedWorkout { xp += 150 }
        if let p = position, p <= 3 { xp += [300, 200, 100][p - 1] }
        return xp
    }
}

public extension RideSimulation {
    /// Builds the history entry for this ride.
    func makeSummary(date: Date = Date()) -> RideSummary {
        let metrics = PowerAnalysis.metrics(samples: recorder.samples, ftp: profile.ftp)
        let completedWorkout = workout?.isComplete ?? false
        let position = mode == .race && isFinished ? playerPosition : nil
        return RideSummary(date: date, routeID: route.id, routeName: route.name, mode: mode, laps: laps,
                           workoutName: workout?.workout.name, finishPosition: position, riders: bots.count + 1,
                           completed: isFinished, metrics: metrics, climbs: completedClimbs,
                           xpEarned: RideSummary.xp(distance: metrics.distance, climb: metrics.elevationGain,
                                                    completedWorkout: completedWorkout, position: position),
                           ftpAtTime: profile.ftp, weightAtTime: profile.weightKg)
    }
}
