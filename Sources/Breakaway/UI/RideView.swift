import BreakawayCore
import SwiftUI

struct RideView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: RideController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer = controller.renderer {
                SceneViewContainer(renderer: renderer).ignoresSafeArea()
            }
            switch controller.phase {
            case let .loading(progress, label):
                LoadingOverlay(route: controller.simulation.route, progress: progress, label: label)
            case let .countdown(n):
                hud
                Text("\(n)")
                    .font(.system(size: 160, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 20)
                    .transition(.scale)
                    .id(n)
            case .riding:
                hud
            case .paused:
                hud
                PauseOverlay(controller: controller)
            case .finished:
                if let s = controller.summary {
                    RideSummaryOverlay(summary: s, controller: controller)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: controller.phase)
    }

    @ViewBuilder private var hud: some View {
        if controller.showHUD {
            RideHUD(controller: controller, hud: controller.hud, profile: controller.simulation.profile)
        }
    }
}

// MARK: - HUD

struct RideHUD: View {
    @ObservedObject var controller: RideController
    let hud: HUDState
    let profile: RiderProfile
    var showsControls = true

    var body: some View {
        let u = profile.units
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                powerPanel
                Spacer()
                VStack(spacing: 8) {
                    centrePanel(u)
                    ForEach(controller.toasts) { t in ToastView(toast: t) }
                    if let c = hud.climb { ClimbBanner(climb: c, units: u) }
                }
                Spacer()
                RiderList(riders: hud.nearby, mode: controller.simulation.mode)
            }
            if let w = hud.workout {
                HStack {
                    WorkoutPanel(workout: w, hud: hud, controller: controller)
                    Spacer()
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                MiniMap(route: controller.simulation.route, hud: hud)
                    .frame(width: 190, height: 150)
                    .hudPanel()
                ProfileStrip(route: controller.simulation.route, hud: hud)
                    .frame(height: 110)
                    .hudPanel()
                gradePanel
            }
            if showsControls { controlsHint }
        }
        .padding(16)
    }

    private var powerPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(hud.power3s.rounded()))")
                    .font(.system(size: 56, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("W").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            }
            Capsule().fill(Theme.zone(hud.power3s, ftp: profile.ftp)).frame(width: 150, height: 5)
            HStack(spacing: 16) {
                StatBlock(label: "W/kg", value: String(format: "%.1f", hud.wattsPerKg))
                StatBlock(label: "Cadence", value: "\(Int(hud.cadence))", unit: "rpm")
                StatBlock(label: "HR", value: hud.heartRate.map { "\(Int($0))" } ?? "—", unit: "bpm", color: hud.heartRate == nil ? .white.opacity(0.5) : .red)
            }
            HStack(spacing: 16) {
                StatBlock(label: "Avg", value: "\(Int(hud.averagePower))", unit: "W")
                StatBlock(label: "Draft", value: "\(Int(hud.draft * 100))", unit: "%", color: hud.draft > 0.05 ? Theme.info : .white)
            }
            if hud.usingVirtualPower {
                Label("Virtual power · ↑↓ to change", systemImage: "keyboard").font(.caption2).foregroundStyle(.white.opacity(0.65))
            } else if !hud.trainerStatus.isEmpty {
                Label(hud.trainerStatus, systemImage: "bicycle").font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(14)
        .hudPanel()
    }

    private func centrePanel(_ u: UnitSystem) -> some View {
        let v = Units.speed(hud.speed, u)
        let toGo = Units.distance(max(0, hud.totalDistance - hud.distance), u)
        let done = Units.distance(hud.distance, u)
        let climbed = Units.elevation(hud.climbed, u)
        return HStack(spacing: 22) {
            StatBlock(label: "Speed", value: String(format: "%.1f", v.value), unit: v.unit)
            StatBlock(label: "Distance", value: String(format: "%.2f", done.value), unit: done.unit)
            StatBlock(label: "To go", value: String(format: "%.2f", toGo.value), unit: toGo.unit)
            StatBlock(label: "Time", value: Units.clock(hud.elapsed))
            StatBlock(label: "Climbed", value: "\(Int(climbed.value))", unit: climbed.unit)
            if hud.laps > 1 { StatBlock(label: "Lap", value: "\(hud.lap)/\(hud.laps)") }
            if controller.simulation.mode == .race { StatBlock(label: "Position", value: "\(hud.position)/\(hud.riders)", color: Theme.accent) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .hudPanel()
    }

    private var gradePanel: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1f%%", hud.grade * 100))
                .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.gradeColor(hud.grade))
            Text("GRADIENT").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            Text("\(Int(Units.elevation(hud.elevation, profile.units).value)) \(Units.elevation(0, profile.units).unit)")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            if let s = hud.surfaceName {
                Text(s).font(.caption2.bold()).foregroundStyle(.brown).lineLimit(1)
            }
            if !hud.usingVirtualPower || controller.devices.canControlTrainer {
                Text("Difficulty \(Int(hud.difficulty * 100))%").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 150, height: 110)
        .hudPanel()
    }

    private var controlsHint: some View {
        HStack(spacing: 14) {
            Picker("", selection: $controller.cameraMode) {
                ForEach(CameraMode.allCases) { m in Text("\(m.rawValue) \(m.title)").tag(m) }
            }
            .pickerStyle(.menu)
            .frame(width: 170)
            Button { controller.togglePause() } label: { Label("Pause", systemImage: "pause.fill") }
                .buttonStyle(PillButtonStyle(color: .white, prominent: false))
            if controller.simulation.mode == .workout {
                Button { controller.toggleERG() } label: { Label(hud.ergOn ? "ERG on" : "ERG off", systemImage: "bolt.horizontal.circle") }
                    .buttonStyle(PillButtonStyle(color: hud.ergOn ? Theme.good : .white, prominent: false))
            }
            Spacer()
            Text("1–7 cameras · Space pause · E ERG · [ ] difficulty · H hide HUD")
                .font(.caption2).foregroundStyle(.white.opacity(0.45))
        }
    }
}

extension View {
    func hudPanel() -> some View {
        background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        let color: Color
        switch toast.style {
        case .kom: color = Theme.kom
        case .pb: color = Theme.good
        case .lap: color = Theme.info
        case .workout: color = Theme.accent
        case .finish: color = Theme.accent
        case .info: color = .white
        }
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 15, weight: .heavy))
                Text(toast.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hudPanel()
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ClimbBanner: View {
    let climb: ClimbHUD
    let units: UnitSystem

    var body: some View {
        let toGo = Units.distance(climb.toGo, units)
        let progress = 1 - climb.toGo / max(climb.length, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(climb.category).font(.system(size: 11, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.kom, in: Capsule())
                Text(climb.name).font(.headline)
                Spacer()
                Text(Units.clock(climb.elapsed)).font(.system(.headline, design: .rounded)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Theme.kom).frame(width: g.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: 6)
            HStack {
                Text(String(format: "%.2f %@ to the top · avg %.1f%%", toGo.value, toGo.unit, climb.averageGrade * 100))
                Spacer()
                if let pb = climb.personalBest { Text("PB \(Units.clock(pb))").foregroundStyle(Theme.good) }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 420)
        .hudPanel()
    }
}

struct RiderList: View {
    let riders: [NearbyRider]
    let mode: RideMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mode == .race ? "RACE" : "RIDERS NEARBY").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            ForEach(riders) { r in
                HStack(spacing: 8) {
                    Text("\(r.position)").font(.caption.monospacedDigit()).frame(width: 22, alignment: .trailing).foregroundStyle(.white.opacity(0.6))
                    Text(r.name).font(.system(size: 12, weight: r.isPlayer ? .heavy : .medium)).lineLimit(1)
                        .foregroundStyle(r.isPlayer ? Theme.accent : (r.isPacer ? Theme.info : .white))
                    Spacer(minLength: 6)
                    if r.finished {
                        Image(systemName: "flag.checkered").font(.caption)
                    } else if !r.isPlayer {
                        Text(String(format: "%+.0fs", r.gapSeconds)).font(.caption.monospacedDigit())
                            .foregroundStyle(r.gapSeconds > 0 ? .white.opacity(0.85) : .white.opacity(0.55))
                    }
                    Text(String(format: "%.1f", r.wattsPerKg)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55)).frame(width: 28)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(r.isPlayer ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(width: 270)
        .hudPanel()
    }
}

struct WorkoutPanel: View {
    let workout: WorkoutHUD
    let hud: HUDState
    @ObservedObject var controller: RideController

    var body: some View {
        let ftp = controller.simulation.profile.ftp
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workout.name.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(Units.clock(workout.elapsed)) / \(Units.clock(workout.total))").font(.caption.monospacedDigit())
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading) {
                    Text(workout.label).font(.headline)
                    Text(workout.target.map { "\(Int($0)) W" } ?? "Free ride")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(workout.target.map { Theme.zone($0, ftp: ftp) } ?? .white)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Units.clock(workout.remaining)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    if let c = workout.cadenceTarget { Text("\(c) rpm").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                }
            }
            if let target = workout.target {
                let delta = hud.power3s - target
                Text(abs(delta) < target * 0.05 ? "On target" : (delta > 0 ? "\(Int(delta)) W over" : "\(Int(-delta)) W under"))
                    .font(.caption.bold()).foregroundStyle(abs(delta) < target * 0.05 ? Theme.good : .orange)
            }
            if let n = workout.nextLabel {
                Text("Next: \(n)\(workout.nextTarget.map { " · \(Int($0)) W" } ?? "")").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            if let w = controller.simulation.workout {
                WorkoutBlocks(workout: w.workout, ftp: ftp, elapsed: workout.elapsed).frame(height: 44)
            }
        }
        .padding(12)
        .frame(width: 340)
        .hudPanel()
    }
}

/// Live elevation profile with every rider's position.
struct ProfileStrip: View {
    let route: Route
    let hud: HUDState

    var body: some View {
        Canvas { ctx, size in
            let prof = route.profile(samples: 220)
            let lo = route.minElevation, hi = max(route.maxElevation, lo + 20)
            func pt(_ d: Double, _ e: Double) -> CGPoint {
                CGPoint(x: d / route.length * size.width, y: size.height - 8 - (e - lo) / (hi - lo) * (size.height - 24))
            }
            for c in route.climbs {
                let r = CGRect(x: c.startDistance / route.length * size.width, y: 0, width: c.length / route.length * size.width, height: size.height)
                ctx.fill(Path(r), with: .color(Theme.kom.opacity(0.12)))
            }
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: size.height))
            for p in prof { fill.addLine(to: pt(p.distance, p.elevation)) }
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // Ridden part.
            let me = route.normalize(hud.distance)
            var done = Path()
            done.move(to: CGPoint(x: 0, y: size.height))
            for p in prof where p.distance <= me { done.addLine(to: pt(p.distance, p.elevation)) }
            done.addLine(to: pt(me, route.elevation(at: me)))
            done.addLine(to: CGPoint(x: me / route.length * size.width, y: size.height))
            ctx.fill(done, with: .color(Theme.accent.opacity(0.45)))
            for o in hud.others {
                let d = route.normalize(o.distance)
                let p = pt(d, route.elevation(at: d))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(o.isPacer ? Theme.info : .white))
            }
            let p = pt(me, route.elevation(at: me))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.accent))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 2)
        }
        .padding(8)
    }
}

struct MiniMap: View {
    let route: Route
    let hud: HUDState

    var body: some View {
        Canvas { ctx, size in
            let b = route.bounds
            let w = max(b.max.x - b.min.x, 1), h = max(b.max.y - b.min.y, 1)
            let scale = min((size.width - 20) / w, (size.height - 20) / h)
            let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2
            func pt(_ p: LocalPoint) -> CGPoint {
                CGPoint(x: ox + (p.x - b.min.x) * scale, y: size.height - oy - (p.y - b.min.y) * scale)
            }
            var path = Path()
            let step = max(1, route.points.count / 400)
            for i in stride(from: 0, to: route.points.count, by: step) {
                if i == 0 { path.move(to: pt(route.points[i])) } else { path.addLine(to: pt(route.points[i])) }
            }
            if let last = route.points.last { path.addLine(to: pt(last)) }
            ctx.stroke(path, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            for o in hud.others {
                let p = pt(route.position(at: o.distance))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(o.isPacer ? Theme.info : .white))
            }
            let me = pt(route.position(at: hud.distance))
            ctx.fill(Path(ellipseIn: CGRect(x: me.x - 5, y: me.y - 5, width: 10, height: 10)), with: .color(Theme.accent))
        }
    }
}

// MARK: - Overlays

struct LoadingOverlay: View {
    let route: Route
    let progress: Double
    let label: String

    var body: some View {
        VStack(spacing: 16) {
            Text(route.record.flag).font(.system(size: 54))
            Text(route.name).font(.system(size: 40, weight: .heavy, design: .rounded))
            Text(route.record.event).foregroundStyle(Theme.secondaryText)
            ProfileSparkline(route: route).frame(width: 520, height: 90)
            ProgressView(value: progress).tint(Theme.accent).frame(width: 360)
            Text("Building the world: \(label)…").font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct PauseOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: RideController

    var body: some View {
        VStack(spacing: 18) {
            Text("Paused").font(.system(size: 44, weight: .heavy, design: .rounded))
            HStack(spacing: 14) {
                Button { controller.togglePause() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(PillButtonStyle())
                Button { controller.finish() } label: { Label("End & save ride", systemImage: "flag.checkered") }
                    .buttonStyle(PillButtonStyle(color: .white, prominent: false))
                Button { model.closeRide() } label: { Label("Discard", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(color: .red, prominent: false))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trainer difficulty")
                    Slider(value: Binding(get: { controller.simulation.trainerDifficulty },
                                          set: { controller.simulation.trainerDifficulty = $0; controller.objectWillChange.send() }), in: 0...1)
                    Text("\(Int(controller.simulation.trainerDifficulty * 100))%").monospacedDigit().frame(width: 44)
                }
                HStack {
                    Text("Virtual power")
                    Slider(value: Binding(get: { controller.devices.virtualPower },
                                          set: { controller.devices.virtualPower = $0; controller.objectWillChange.send() }), in: 0...600, step: 5)
                    Text("\(Int(controller.devices.virtualPower)) W").monospacedDigit().frame(width: 54)
                }
            }
            .frame(width: 460)
        }
        .padding(36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
    }
}

struct RideSummaryOverlay: View {
    @EnvironmentObject var model: AppModel
    let summary: RideSummary
    @ObservedObject var controller: RideController

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: summary.completed ? "flag.checkered" : "flag").font(.title)
                Text(summary.completed ? "Ride complete" : "Ride saved").font(.system(size: 36, weight: .heavy, design: .rounded))
            }
            Text(summary.routeName).foregroundStyle(Theme.secondaryText)
            if let p = summary.finishPosition {
                Text("You finished \(p) of \(summary.riders)").font(.title2.bold()).foregroundStyle(p <= 3 ? Theme.accent : .white)
            }
            MetricsGrid(metrics: summary.metrics, units: model.profile.units, ftp: summary.ftpAtTime, weight: summary.weightAtTime)
                .frame(width: 760)
            if !summary.climbs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.climbs.enumerated()), id: \.offset) { _, c in
                        HStack {
                            Text(c.climbName)
                            if c.isPersonalBest { Text("PB").font(.caption.bold()).foregroundStyle(.black).padding(.horizontal, 6).background(Theme.good, in: Capsule()) }
                            Spacer()
                            Text(Units.clock(c.seconds)).monospacedDigit().bold()
                        }
                    }
                }
                .frame(width: 520)
            }
            Text("+\(summary.xpEarned) XP").font(.title3.bold()).foregroundStyle(Theme.accent)
            HStack(spacing: 12) {
                Button("Export FIT") { model.export(summary, as: .fit) }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Export GPX") { model.export(summary, as: .gpx) }.buttonStyle(PillButtonStyle(prominent: false))
                Button { model.closeRide() } label: { Label("Done", systemImage: "checkmark") }.buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
    }
}
