import Foundation

public enum WorkoutLibrary {
    private static func m(_ minutes: Double) -> Double { minutes * 60 }

    public static let all: [Workout] = [
        Workout(id: "ramp-test", name: "Ramp FTP Test", summary: "One-minute steps of +6 % FTP until you can't hold the target. Your new FTP is 75 % of your best one-minute power.",
                category: .test, steps: [
                    .ramp(duration: m(5), from: 0.40, to: 0.60, cadence: 90),
                    .intervals(repeats: 20, onDuration: 60, onPower: 0.0, offDuration: 0, offPower: 0, cadence: nil),
                ].rampTestExpanded()),
        Workout(id: "ftp20", name: "20-Minute FTP Test", summary: "Classic protocol: openers, a 5-minute blowout, then 20 minutes all-out. FTP = 95 % of the 20-minute average.",
                category: .test, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.70, cadence: 90),
                    .intervals(repeats: 3, onDuration: 60, onPower: 1.10, offDuration: 60, offPower: 0.55, cadence: 100),
                    .steady(duration: m(5), power: 0.55, cadence: nil),
                    .steady(duration: m(5), power: 1.05, cadence: nil),
                    .steady(duration: m(10), power: 0.50, cadence: nil),
                    .freeRide(duration: m(20)),
                    .ramp(duration: m(10), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "endurance-60", name: "Endurance Hour", summary: "Steady zone-2 aerobic base with a few cadence lifts.",
                category: .endurance, steps: [
                    .ramp(duration: m(8), from: 0.45, to: 0.65, cadence: 88),
                    .steady(duration: m(12), power: 0.68, cadence: 90),
                    .steady(duration: m(3), power: 0.70, cadence: 105),
                    .steady(duration: m(12), power: 0.68, cadence: 90),
                    .steady(duration: m(3), power: 0.70, cadence: 105),
                    .steady(duration: m(14), power: 0.68, cadence: 90),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "tempo-3x15", name: "Tempo 3×15", summary: "Muscular endurance at the top of zone 3.",
                category: .tempo, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.75, cadence: 90),
                    .intervals(repeats: 3, onDuration: m(15), onPower: 0.85, offDuration: m(4), offPower: 0.55, cadence: 88),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "sweetspot-3x12", name: "Sweet Spot 3×12", summary: "The most time-efficient FTP builder: 88–94 % of FTP.",
                category: .sweetSpot, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.75, cadence: 90),
                    .intervals(repeats: 3, onDuration: m(12), onPower: 0.91, offDuration: m(4), offPower: 0.55, cadence: 90),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "threshold-2x20", name: "Threshold 2×20", summary: "Two blocks right on FTP — the benchmark threshold session.",
                category: .threshold, steps: [
                    .ramp(duration: m(12), from: 0.45, to: 0.80, cadence: 90),
                    .intervals(repeats: 2, onDuration: m(20), onPower: 0.98, offDuration: m(6), offPower: 0.55, cadence: 92),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "over-unders", name: "Over-Unders 4×8", summary: "Alternate 2 minutes under and 1 minute over FTP to teach lactate clearance.",
                category: .threshold, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.80, cadence: 90),
                    .intervals(repeats: 4, onDuration: m(2), onPower: 0.92, offDuration: m(1), offPower: 1.08, cadence: 95),
                    .steady(duration: m(4), power: 0.55, cadence: nil),
                    .intervals(repeats: 4, onDuration: m(2), onPower: 0.92, offDuration: m(1), offPower: 1.08, cadence: 95),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "vo2-5x3", name: "VO₂ Max 5×3", summary: "Five three-minute efforts at 115 % with equal recovery.",
                category: .vo2max, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.80, cadence: 90),
                    .intervals(repeats: 5, onDuration: m(3), onPower: 1.15, offDuration: m(3), offPower: 0.50, cadence: 100),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "30-30s", name: "30/30s", summary: "Rønnestad-style micro-intervals: 3 sets of 10×30 s hard / 30 s easy.",
                category: .vo2max, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.80, cadence: 90),
                    .intervals(repeats: 10, onDuration: 30, onPower: 1.25, offDuration: 30, offPower: 0.55, cadence: 105),
                    .steady(duration: m(5), power: 0.50, cadence: nil),
                    .intervals(repeats: 10, onDuration: 30, onPower: 1.25, offDuration: 30, offPower: 0.55, cadence: 105),
                    .steady(duration: m(5), power: 0.50, cadence: nil),
                    .intervals(repeats: 10, onDuration: 30, onPower: 1.25, offDuration: 30, offPower: 0.55, cadence: 105),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "tabata", name: "Tabata", summary: "20 seconds flat out, 10 seconds rest, eight times. Then do it again.",
                category: .anaerobic, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.80, cadence: 90),
                    .intervals(repeats: 8, onDuration: 20, onPower: 1.70, offDuration: 10, offPower: 0.40, cadence: 110),
                    .steady(duration: m(6), power: 0.50, cadence: nil),
                    .intervals(repeats: 8, onDuration: 20, onPower: 1.70, offDuration: 10, offPower: 0.40, cadence: 110),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "sprints", name: "Sprint Power", summary: "Eight standing-start sprints with long recoveries.",
                category: .anaerobic, steps: [
                    .ramp(duration: m(12), from: 0.45, to: 0.75, cadence: 90),
                    .intervals(repeats: 8, onDuration: 12, onPower: 2.2, offDuration: m(4) - 12, offPower: 0.50, cadence: nil),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "pyramid", name: "Pyramid", summary: "1-2-3-4-3-2-1 minutes climbing from sweet spot to VO₂.",
                category: .vo2max, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.80, cadence: 90),
                    .steady(duration: m(1), power: 1.20, cadence: 100), .steady(duration: m(1), power: 0.55, cadence: nil),
                    .steady(duration: m(2), power: 1.12, cadence: 100), .steady(duration: m(2), power: 0.55, cadence: nil),
                    .steady(duration: m(3), power: 1.05, cadence: 95), .steady(duration: m(3), power: 0.55, cadence: nil),
                    .steady(duration: m(4), power: 0.98, cadence: 95), .steady(duration: m(3), power: 0.55, cadence: nil),
                    .steady(duration: m(3), power: 1.05, cadence: 95), .steady(duration: m(2), power: 0.55, cadence: nil),
                    .steady(duration: m(2), power: 1.12, cadence: 100), .steady(duration: m(1), power: 0.55, cadence: nil),
                    .steady(duration: m(1), power: 1.20, cadence: 100),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "alpe-sim", name: "Alpe d'Huez Simulation", summary: "Pace the 21 hairpins: 50 minutes of rising sweet-spot to threshold. Best ridden on the Alpe d'Huez route.",
                category: .sweetSpot, steps: [
                    .ramp(duration: m(10), from: 0.45, to: 0.75, cadence: 90),
                    .steady(duration: m(15), power: 0.86, cadence: 80),
                    .steady(duration: m(15), power: 0.90, cadence: 78),
                    .steady(duration: m(15), power: 0.94, cadence: 76),
                    .steady(duration: m(5), power: 1.02, cadence: 85),
                    .ramp(duration: m(8), from: 0.60, to: 0.40, cadence: nil),
                ]),
        Workout(id: "recovery", name: "Recovery Spin", summary: "Thirty easy minutes to flush the legs.",
                category: .recovery, steps: [
                    .ramp(duration: m(5), from: 0.40, to: 0.50, cadence: 90),
                    .steady(duration: m(20), power: 0.50, cadence: 92),
                    .ramp(duration: m(5), from: 0.50, to: 0.40, cadence: nil),
                ]),
    ]

    public static func workout(id: String) -> Workout? { all.first { $0.id == id } }
}

private extension Array where Element == WorkoutStep {
    /// Builds the 1-minute +6 % staircase of the ramp test (the placeholder
    /// interval step in the definition marks where the staircase goes).
    func rampTestExpanded() -> [WorkoutStep] {
        var out: [WorkoutStep] = []
        for step in self {
            if case let .intervals(repeats, on, _, _, _, _) = step {
                for k in 0..<repeats {
                    out.append(.steady(duration: on, power: 0.60 + 0.06 * Double(k), cadence: nil))
                }
            } else {
                out.append(step)
            }
        }
        return out
    }
}
