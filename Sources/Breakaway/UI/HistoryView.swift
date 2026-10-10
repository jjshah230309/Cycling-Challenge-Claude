import BreakawayCore
import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                if model.history.isEmpty {
                    Text("No rides yet — your activities will appear here.").foregroundStyle(Theme.secondaryText)
                }
                ForEach(model.history) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: r.mode.symbolName).foregroundStyle(Theme.accent)
                            Text(r.routeName).font(.headline).lineLimit(1)
                        }
                        let d = Units.distance(r.metrics.distance, model.profile.units)
                        Text("\(r.date.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f", d.value)) \(d.unit) · \(Units.clock(r.metrics.duration))")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .tag(r.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { model.deleteRide(r) }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            if let id = selection ?? model.history.first?.id, let ride = model.history.first(where: { $0.id == id }) {
                RideDetailView(ride: ride).id(ride.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 40)).foregroundStyle(Theme.secondaryText)
                    Text("Ride to build your history").foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RideDetailView: View {
    @EnvironmentObject var model: AppModel
    let ride: RideSummary
    @State private var samples: [RideSample] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ride.routeName).font(.system(size: 26, weight: .heavy, design: .rounded))
                        Text("\(ride.mode.displayName)\(ride.workoutName.map { " · \($0)" } ?? "") · \(ride.date.formatted(date: .complete, time: .shortened))")
                            .foregroundStyle(Theme.secondaryText)
                        if let p = ride.finishPosition {
                            Label("Finished \(p) of \(ride.riders)", systemImage: p <= 3 ? "medal.fill" : "flag.checkered").foregroundStyle(Theme.accent)
                        }
                    }
                    Spacer()
                    Menu("Export") {
                        Button("FIT (Strava, Garmin, TrainingPeaks)") { model.export(ride, as: .fit) }
                        Button("GPX") { model.export(ride, as: .gpx) }
                        Button("TCX") { model.export(ride, as: .tcx) }
                    }
                    .frame(width: 110)
                }
                MetricsGrid(metrics: ride.metrics, units: model.profile.units, ftp: ride.ftpAtTime, weight: ride.weightAtTime)
                if !samples.isEmpty {
                    Card {
                        VStack(alignment: .leading) {
                            Text("Power, heart rate & elevation").font(.headline)
                            RideTraceChart(samples: samples, ftp: ride.ftpAtTime).frame(height: 240)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card {
                        VStack(alignment: .leading) {
                            Text("Power curve").font(.headline)
                            PowerCurveChart(curve: ride.metrics.powerCurve).frame(height: 180)
                        }
                    }
                    Card {
                        VStack(alignment: .leading) {
                            Text("Time in zone").font(.headline)
                            ZoneChart(zoneSeconds: ride.metrics.zoneSeconds).frame(height: 180)
                        }
                    }
                }
                if !ride.climbs.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Climbs").font(.headline)
                            ForEach(Array(ride.climbs.enumerated()), id: \.offset) { _, c in
                                HStack {
                                    Text(c.climbName)
                                    if c.isPersonalBest { Text("PB").font(.caption.bold()).foregroundStyle(.black).padding(.horizontal, 6).background(Theme.good, in: Capsule()) }
                                    Spacer()
                                    Text("\(Int(c.averagePower)) W").foregroundStyle(Theme.secondaryText)
                                    Text(Units.clock(c.seconds)).bold().monospacedDigit().frame(width: 80, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear { samples = Storage.loadSamples(for: ride.id) }
    }
}

struct MetricsGrid: View {
    let metrics: RideMetrics
    let units: UnitSystem
    let ftp: Double
    let weight: Double

    var body: some View {
        let d = Units.distance(metrics.distance, units)
        let e = Units.elevation(metrics.elevationGain, units)
        let v = Units.speed(metrics.averageSpeed, units)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 6), alignment: .leading, spacing: 14) {
            StatBlock(label: "Distance", value: String(format: "%.2f", d.value), unit: d.unit)
            StatBlock(label: "Time", value: Units.clock(metrics.duration))
            StatBlock(label: "Elevation", value: "\(Int(e.value))", unit: e.unit)
            StatBlock(label: "Avg speed", value: String(format: "%.1f", v.value), unit: v.unit)
            StatBlock(label: "Avg power", value: "\(Int(metrics.averagePower))", unit: "W")
            StatBlock(label: "Norm. power", value: "\(Int(metrics.normalizedPower))", unit: "W")
            StatBlock(label: "W/kg (NP)", value: String(format: "%.2f", metrics.normalizedPower / max(weight, 30)))
            StatBlock(label: "IF", value: String(format: "%.2f", metrics.intensityFactor))
            StatBlock(label: "TSS", value: "\(Int(metrics.trainingStressScore))")
            StatBlock(label: "Work", value: "\(Int(metrics.kilojoules))", unit: "kJ")
            StatBlock(label: "Max power", value: "\(Int(metrics.maxPower))", unit: "W")
            StatBlock(label: "Avg HR", value: metrics.averageHeartRate.map { "\(Int($0))" } ?? "—", unit: "bpm")
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct RideTraceChart: View {
    let samples: [RideSample]
    let ftp: Double

    struct P: Identifiable { let id: Int; let t: Double; let power: Double; let hr: Double?; let elevation: Double }

    var body: some View {
        // Downsample to ~600 points with 10 s smoothing for readability.
        let step = max(1, samples.count / 600)
        let pts: [P] = stride(from: 0, to: samples.count, by: step).map { i in
            let lo = max(0, i - 5), hi = min(samples.count, i + 5)
            let window = samples[lo..<hi]
            let avg = window.map(\.power).reduce(0, +) / Double(max(window.count, 1))
            return P(id: i, t: samples[i].t / 60, power: avg, hr: samples[i].heartRate, elevation: samples[i].elevation)
        }
        let eMin = pts.map(\.elevation).min() ?? 0, eMax = max(pts.map(\.elevation).max() ?? 1, eMin + 1)
        let pMax = max(pts.map(\.power).max() ?? 100, ftp * 1.2)
        Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("min", p.t), y: .value("Elevation", (p.elevation - eMin) / (eMax - eMin) * pMax * 0.6))
                    .foregroundStyle(Color.white.opacity(0.08))
            }
            ForEach(pts) { p in
                LineMark(x: .value("min", p.t), y: .value("Power", p.power), series: .value("s", "Power"))
                    .foregroundStyle(Theme.accent)
            }
            ForEach(pts.filter { $0.hr != nil }) { p in
                LineMark(x: .value("min", p.t), y: .value("HR", p.hr ?? 0), series: .value("s", "HR"))
                    .foregroundStyle(Color.red.opacity(0.8))
            }
            RuleMark(y: .value("FTP", ftp)).foregroundStyle(.white.opacity(0.3)).lineStyle(StrokeStyle(dash: [4, 4]))
        }
        .chartXAxisLabel("minutes")
        .chartYScale(domain: 0...pMax)
    }
}

struct PowerCurveChart: View {
    let curve: [Int: Double]

    var body: some View {
        let pts = curve.sorted { $0.key < $1.key }
        Chart(pts, id: \.key) { item in
            BarMark(x: .value("Duration", label(item.key)), y: .value("Watts", item.value))
                .foregroundStyle(Theme.accent.gradient)
                .annotation(position: .top) { Text("\(Int(item.value))").font(.caption2) }
        }
    }

    private func label(_ s: Int) -> String { s < 60 ? "\(s)s" : (s < 3600 ? "\(s / 60)m" : "\(s / 3600)h") }
}

struct ZoneChart: View {
    let zoneSeconds: [Double]

    var body: some View {
        Chart(PowerZone.allCases, id: \.self) { z in
            BarMark(x: .value("Zone", "Z\(z.rawValue)"), y: .value("Minutes", (zoneSeconds.indices.contains(z.rawValue - 1) ? zoneSeconds[z.rawValue - 1] : 0) / 60))
                .foregroundStyle(Theme.color(z.color))
        }
        .chartYAxisLabel("min")
    }
}
