import BreakawayCore
import SwiftUI

/// Home screen: pick a route, a mode and go.
struct RideSetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var devices: DeviceManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "Ride", subtitle: "Real roads, real gradients — from the Alpe to the Worlds.")
                if let summary = model.lastFinishedRide {
                    LastRideBanner(summary: summary)
                }
                if let route = model.selectedRoute {
                    FeaturedRouteCard(route: route)
                }
                modePicker
                optionsRow
                startRow
                Text("FEATURED ROUTES").font(.caption.bold()).foregroundStyle(Theme.secondaryText).padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(model.allRouteRecords, id: \.id) { rec in
                        if let route = model.route(id: rec.id) {
                            RouteTile(route: route, selected: rec.id == model.selectedRouteID)
                                .onTapGesture { model.selectedRouteID = rec.id }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(RideMode.allCases, id: \.self) { mode in
                Button {
                    model.mode = mode
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: mode.symbolName).font(.system(size: 18, weight: .semibold))
                        Text(mode.displayName).font(.system(size: 14, weight: .bold))
                        Text(mode.blurb).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .padding(12)
                    .background(model.mode == mode ? Theme.accentSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.mode == mode ? Theme.accent : Theme.stroke, lineWidth: model.mode == mode ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var optionsRow: some View {
        Card {
            HStack(spacing: 28) {
                if let route = model.selectedRoute, route.isLoop {
                    Stepper(value: $model.laps, in: 1...20) {
                        VStack(alignment: .leading) {
                            Text("Laps").font(.caption).foregroundStyle(Theme.secondaryText)
                            let d = Units.distance(route.length * Double(model.laps), model.profile.units)
                            Text("\(model.laps) × \(String(format: "%.1f", Units.distance(route.length, model.profile.units).value)) = \(String(format: "%.1f", d.value)) \(d.unit)")
                                .font(.headline).monospacedDigit()
                        }
                    }
                    .frame(width: 230)
                }
                if model.mode != .timeTrial {
                    VStack(alignment: .leading) {
                        Text("AI riders: \(model.botCount)").font(.caption).foregroundStyle(Theme.secondaryText)
                        Slider(value: Binding(get: { Double(model.botCount) }, set: { model.botCount = Int($0) }), in: 0...40, step: 1)
                            .frame(width: 200)
                    }
                }
                if model.mode == .workout {
                    Picker("Workout", selection: Binding(get: { model.selectedWorkoutID ?? "sweetspot-3x12" }, set: { model.selectedWorkoutID = $0 })) {
                        ForEach(model.allWorkouts) { w in
                            Text("\(w.name) · \(Int(w.duration / 60)) min").tag(w.id)
                        }
                    }
                    .frame(width: 300)
                }
                Spacer()
            }
        }
    }

    private var startRow: some View {
        HStack(spacing: 14) {
            Button {
                model.startRide()
            } label: {
                Label("Start \(model.mode.displayName)", systemImage: "play.fill").frame(minWidth: 180)
            }
            .buttonStyle(PillButtonStyle())
            .keyboardShortcut(.defaultAction)

            VStack(alignment: .leading, spacing: 2) {
                if devices.hasHardwarePower || devices.paired[.trainer] != nil || devices.paired[.powerMeter] != nil {
                    Label(devicesSummary, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else {
                    Label("No trainer paired — riding with virtual power (↑/↓ to change watts)", systemImage: "keyboard")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .font(.callout)
            Spacer()
        }
    }

    private var devicesSummary: String {
        DeviceRole.allCases.compactMap { devices.paired[$0]?.name }.joined(separator: " · ")
    }
}

struct LastRideBanner: View {
    @EnvironmentObject var model: AppModel
    let summary: RideSummary

    var body: some View {
        Card {
            HStack(spacing: 24) {
                Image(systemName: summary.finishPosition == 1 ? "trophy.fill" : "flag.checkered")
                    .font(.system(size: 28)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last ride · \(summary.routeName)").font(.headline)
                    Text(summary.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                let d = Units.distance(summary.metrics.distance, model.profile.units)
                StatBlock(label: "Distance", value: String(format: "%.1f", d.value), unit: d.unit)
                StatBlock(label: "Time", value: Units.clock(summary.metrics.duration))
                StatBlock(label: "Avg power", value: "\(Int(summary.metrics.averagePower))", unit: "W")
                StatBlock(label: "XP", value: "+\(summary.xpEarned)", color: Theme.accent)
                Spacer()
                Button("Export FIT") { model.export(summary, as: .fit) }.buttonStyle(PillButtonStyle(prominent: false))
                Button {
                    model.lastFinishedRide = nil
                } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

struct FeaturedRouteCard: View {
    @EnvironmentObject var model: AppModel
    let route: Route

    var body: some View {
        Card(padding: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(route.record.flag).font(.system(size: 22))
                        Text(route.record.event.uppercased()).font(.caption.bold()).foregroundStyle(Theme.accent)
                        QualityBadge(quality: route.record.quality)
                    }
                    Text(route.name).font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text(route.record.location).foregroundStyle(Theme.secondaryText)
                    Text(route.record.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    RouteStatsRow(route: route)
                    if let main = route.climbs.max(by: { $0.elevationGain < $1.elevationGain }) {
                        let pb = model.personalBest(routeID: route.id, climb: main.name)
                        Label(pb.map { "Your PB on \(main.name): \(Units.clock($0))" } ?? "No time set on \(main.name) yet",
                              systemImage: "stopwatch").font(.callout).foregroundStyle(pb == nil ? Theme.secondaryText : Theme.good)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                RouteMapView(route: route)
                    .frame(width: 320, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(14)
            }
        }
    }
}

struct QualityBadge: View {
    let quality: RouteRecord.DataQuality

    var body: some View {
        let color: Color = quality == .verified ? Theme.good : (quality == .approximate ? .orange : Theme.info)
        Text(quality.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .help(quality == .approximate
                  ? "Traced over the course's named roads, but the exact street sequence could not be confirmed. Import the organiser's official GPX for a perfect copy."
                  : "Road geometry from OpenStreetMap and elevation from Copernicus EU-DEM / SRTM.")
    }
}

struct RouteStatsRow: View {
    @EnvironmentObject var model: AppModel
    let route: Route

    var body: some View {
        let u = model.profile.units
        let d = Units.distance(route.length, u)
        let e = Units.elevation(route.elevationGain, u)
        let top = Units.elevation(route.maxElevation, u)
        HStack(spacing: 22) {
            StatBlock(label: route.isLoop ? "Lap" : "Distance", value: String(format: "%.1f", d.value), unit: d.unit)
            StatBlock(label: "Climbing", value: "\(Int(e.value))", unit: e.unit)
            StatBlock(label: "Summit", value: "\(Int(top.value))", unit: e.unit)
            StatBlock(label: "Max grade", value: String(format: "%.1f", route.maxGrade * 100), unit: "%", color: Theme.gradeColor(route.maxGrade))
            if let off = route.record.official?.averageGradePercent {
                StatBlock(label: "Avg grade", value: String(format: "%.1f", off), unit: "%")
            }
        }
    }
}

struct RouteTile: View {
    @EnvironmentObject var model: AppModel
    let route: Route
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(route.record.flag)
                Text(route.record.category.displayName.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                if let c = route.climbs.map(\.category).min(), c <= .cat2 {
                    Text(c.label).font(.system(size: 10, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.kom, in: Capsule())
                }
            }
            Text(route.name).font(.system(size: 15, weight: .bold)).lineLimit(2)
            ProfileSparkline(route: route).frame(height: 46)
            let d = Units.distance(route.length, model.profile.units)
            let e = Units.elevation(route.elevationGain, model.profile.units)
            Text("\(String(format: "%.1f", d.value)) \(d.unit) · \(Int(e.value)) \(e.unit)\(route.isLoop ? " · circuit" : "")")
                .font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .padding(12)
        .background(selected ? Theme.accentSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
    }
}
