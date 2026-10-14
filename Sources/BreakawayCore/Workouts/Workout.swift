import Foundation

/// One block of a structured workout. Power values are fractions of FTP.
public enum WorkoutStep: Codable, Hashable, Sendable {
    case steady(duration: Double, power: Double, cadence: Int?)
    case ramp(duration: Double, from: Double, to: Double, cadence: Int?)
    case intervals(repeats: Int, onDuration: Double, onPower: Double, offDuration: Double, offPower: Double, cadence: Int?)
    case freeRide(duration: Double)

    public var duration: Double {
        switch self {
        case let .steady(d, _, _), let .ramp(d, _, _, _), let .freeRide(d): return d
        case let .intervals(r, on, _, off, _, _): return Double(r) * (on + off)
        }
    }
}

/// A flattened, time-indexed piece of a workout.
public struct WorkoutSegment: Hashable, Sendable {
    public var start: Double
    public var duration: Double
    /// FTP fraction at the start / end of the segment (equal for steady blocks). nil = free ride.
    public var startPower: Double?
    public var endPower: Double?
    public var cadence: Int?
    public var label: String

    public var end: Double { start + duration }

    public func power(at t: Double) -> Double? {
        guard let a = startPower, let b = endPower else { return nil }
        let f = duration > 0 ? min(max((t - start) / duration, 0), 1) : 0
        return a + (b - a) * f
    }
}

public enum WorkoutCategory: String, Codable, CaseIterable, Sendable {
    case test, endurance, tempo, sweetSpot, threshold, vo2max, anaerobic, recovery, custom

    public var displayName: String {
        switch self {
        case .test: return "FTP Tests"
        case .endurance: return "Endurance"
        case .tempo: return "Tempo"
        case .sweetSpot: return "Sweet Spot"
        case .threshold: return "Threshold"
        case .vo2max: return "VO₂ Max"
        case .anaerobic: return "Anaerobic & Sprints"
        case .recovery: return "Recovery"
        case .custom: return "Imported"
        }
    }
}

public struct Workout: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var author: String
    public var summary: String
    public var category: WorkoutCategory
    public var steps: [WorkoutStep]

    public init(id: String, name: String, author: String = "Breakaway", summary: String, category: WorkoutCategory, steps: [WorkoutStep]) {
        self.id = id
        self.name = name
        self.author = author
        self.summary = summary
        self.category = category
        self.steps = steps
    }

    public var duration: Double { steps.reduce(0) { $0 + $1.duration } }

    /// Expanded, time-indexed segments (intervals unrolled).
    public var segments: [WorkoutSegment] {
        var out: [WorkoutSegment] = []
        var t = 0.0
        for step in steps {
            switch step {
            case let .steady(d, p, c):
                out.append(WorkoutSegment(start: t, duration: d, startPower: p, endPower: p, cadence: c, label: "Steady"))
                t += d
            case let .ramp(d, a, b, c):
                out.append(WorkoutSegment(start: t, duration: d, startPower: a, endPower: b, cadence: c, label: b >= a ? "Ramp up" : "Ramp down"))
                t += d
            case let .intervals(r, on, onP, off, offP, c):
                for k in 0..<max(r, 0) {
                    out.append(WorkoutSegment(start: t, duration: on, startPower: onP, endPower: onP, cadence: c, label: "Interval \(k + 1)/\(r)"))
                    t += on
                    if off > 0 {
                        out.append(WorkoutSegment(start: t, duration: off, startPower: offP, endPower: offP, cadence: nil, label: "Recover"))
                        t += off
                    }
                }
            case let .freeRide(d):
                out.append(WorkoutSegment(start: t, duration: d, startPower: nil, endPower: nil, cadence: nil, label: "Free ride"))
                t += d
            }
        }
        return out
    }

    /// Training Stress Score if the workout is ridden exactly as prescribed
    /// (normalised power from the time-weighted mean of p⁴; free ride assumed 60 %).
    public var estimatedTSS: Double {
        var sumP4 = 0.0, total = 0.0
        for s in segments {
            let a = s.startPower ?? 0.6, b = s.endPower ?? 0.6
            let meanP4 = abs(b - a) < 1e-9 ? pow(a, 4) : (pow(b, 5) - pow(a, 5)) / (5 * (b - a))
            sumP4 += meanP4 * s.duration
            total += s.duration
        }
        guard total > 0 else { return 0 }
        let np = pow(sumP4 / total, 0.25)
        return total / 3600 * np * np * 100
    }

    public var maxPower: Double {
        segments.compactMap { s in [s.startPower, s.endPower].compactMap { $0 }.max() }.max() ?? 0
    }
}

/// Tracks progress through a workout during a ride.
public struct WorkoutProgress: Sendable {
    public let workout: Workout
    public let segments: [WorkoutSegment]
    public var elapsed: Double = 0

    public init(workout: Workout) {
        self.workout = workout
        self.segments = workout.segments
    }

    public var isComplete: Bool { elapsed >= workout.duration }

    public var currentIndex: Int? {
        segments.firstIndex { elapsed >= $0.start && elapsed < $0.end }
    }

    public var current: WorkoutSegment? { currentIndex.map { segments[$0] } }

    public var next: WorkoutSegment? {
        guard let i = currentIndex, i + 1 < segments.count else { return nil }
        return segments[i + 1]
    }

    public var remainingInSegment: Double {
        guard let c = current else { return 0 }
        return c.end - elapsed
    }

    /// Target in watts for an FTP, or nil in free-ride blocks / after the end.
    public func targetWatts(ftp: Double) -> Double? {
        guard let c = current, let f = c.power(at: elapsed) else { return nil }
        return (f * ftp).rounded()
    }
}
