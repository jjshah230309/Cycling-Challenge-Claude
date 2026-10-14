import AppKit
import BreakawayCore
import Foundation
import SwiftUI

struct NearbyRider: Identifiable, Equatable {
    var id: String
    var name: String
    var nation: String
    var gapSeconds: Double
    var wattsPerKg: Double
    var isPlayer: Bool
    var isPacer: Bool
    var position: Int
    var finished: Bool
}

struct ClimbHUD: Equatable {
    var name: String
    var category: String
    var toGo: Double
    var length: Double
    var averageGrade: Double
    var elapsed: Double
    var personalBest: Double?
}

struct WorkoutHUD: Equatable {
    var name: String
    var label: String
    var target: Double?
    var remaining: Double
    var nextLabel: String?
    var nextTarget: Double?
    var elapsed: Double
    var total: Double
    var cadenceTarget: Int?
}

struct HUDState: Equatable {
    var power: Double = 0
    var power3s: Double = 0
    var wattsPerKg: Double = 0
    var cadence: Double = 0
    var heartRate: Double?
    var speed: Double = 0
    var distance: Double = 0
    var totalDistance: Double = 0
    var lapDistance: Double = 0
    var elapsed: Double = 0
    var grade: Double = 0
    var elevation: Double = 0
    var climbed: Double = 0
    var lap = 1
    var laps = 1
    var position = 1
    var riders = 1
    var draft: Double = 0
    var wPrime: Double = 1
    var gear = ""
    /// Wind felt by the rider, m/s: + headwind / − tailwind, and across (+ from the right).
    var headwind: Double = 0
    var crosswind: Double = 0
    var braking = false
    var averagePower: Double = 0
    var climb: ClimbHUD?
    var workout: WorkoutHUD?
    var nearby: [NearbyRider] = []
    var surfaceName: String?
    var usingVirtualPower = true
    var trainerStatus = ""
    var ergOn = true
    var difficulty: Double = 0.5
    var others: [(id: String, distance: Double, isPacer: Bool)] = []

    static func == (a: HUDState, b: HUDState) -> Bool {
        a.power == b.power && a.distance == b.distance && a.elapsed == b.elapsed && a.position == b.position
            && a.workout == b.workout && a.climb == b.climb && a.nearby == b.nearby && a.heartRate == b.heartRate
    }
}

struct Toast: Identifiable, Equatable {
    enum Style { case kom, pb, lap, info, workout, finish }
    let id = UUID()
    var title: String
    var subtitle: String
    var style: Style
    var expires: Date
}

/// Drives one ride: builds the world, runs the 60 Hz simulation loop, feeds the
/// trainer, publishes HUD state and handles keyboard controls.
@MainActor
final class RideController: ObservableObject {
    enum Phase: Equatable {
        case loading(Double, String)
        case countdown(Int)
        case riding
        case paused
        case finished
    }

    @Published private(set) var phase: Phase = .loading(0, "Preparing")
    @Published private(set) var hud = HUDState()
    @Published private(set) var toasts: [Toast] = []
    @Published var cameraMode: CameraMode = .chase
    @Published private(set) var summary: RideSummary?
    @Published private(set) var renderer: WorldRenderer?
    @Published var showHUD = true

    let simulation: RideSimulation
    let devices: DeviceManager
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var hudClock: Double = 0
    private var powerWindow: [(t: Double, p: Double)] = []
    private var keyMonitor: Any?
    private let onEnd: (RideSummary?, [RideSample]) -> Void
    private var ended = false

    init(simulation: RideSimulation, devices: DeviceManager, onEnd: @escaping (RideSummary?, [RideSample]) -> Void) {
        self.simulation = simulation
        self.devices = devices
        self.onEnd = onEnd
        hud.totalDistance = simulation.totalDistance
        hud.laps = simulation.laps
        loadWorld()
        installKeyMonitor()
    }

    /// Snapshot / preview use: wraps an already-built world, no timers or key handling.
    init(simulation: RideSimulation, devices: DeviceManager, renderer: WorldRenderer) {
        self.simulation = simulation
        self.devices = devices
        self.onEnd = { _, _ in }
        self.renderer = renderer
        phase = .riding
        for e in simulation.drainEvents() { handle(e) }
        publishHUD()
    }

    // MARK: - Lifecycle

    private func loadWorld() {
        let route = simulation.route
        Task.detached(priority: .userInitiated) { [weak self] in
            let world = WorldBuilder.build(route: route) { p, label in
                Task { @MainActor [weak self] in
                    if let me = self, case .loading = me.phase { me.phase = .loading(p, label) }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !self.ended else { return }
                self.renderer = WorldRenderer(world: world, simulation: self.simulation)
                self.startCountdown()
            }
        }
    }

    private func startCountdown() {
        phase = .countdown(3)
        for i in 1...3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, case .countdown = self.phase else { return }
                    if i < 3 { self.phase = .countdown(3 - i) } else { self.beginRiding() }
                }
            }
        }
        startTimer()
    }

    private func beginRiding() {
        phase = .riding
        lastTick = CACurrentMediaTime()
        push(Toast(title: simulation.route.name, subtitle: "\(simulation.mode.displayName) · \(simulation.route.record.event)",
                   style: .info, expires: Date().addingTimeInterval(5)))
    }

    private func startTimer() {
        timer?.invalidate()
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        devices.resetTrainer()
    }

    func togglePause() {
        switch phase {
        case .riding: phase = .paused
        case .paused:
            phase = .riding
            lastTick = CACurrentMediaTime()
        default: break
        }
    }

    /// Ends the ride (finished or abandoned) and produces the summary.
    func finish() {
        guard !ended else { return }
        ended = true
        timer?.invalidate()
        timer = nil
        devices.resetTrainer()
        let s = simulation.makeSummary()
        summary = s
        phase = .finished
        onEnd(s, simulation.recorder.samples)
    }

    // MARK: - Loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        guard let renderer else { return }

        if phase == .riding {
            let input = devices.currentInput()
            simulation.step(dt: dt, input: input)
            devices.apply(simulation.trainerTarget)
            powerWindow.append((simulation.elapsed, input.power))
            powerWindow.removeAll { simulation.elapsed - $0.t > 3 }
            for e in simulation.drainEvents() { handle(e) }
            if simulation.isFinished {
                renderer.update(simulation: simulation, dt: dt, mode: cameraMode)
                publishHUD()
                finish()
                return
            }
        }
        renderer.update(simulation: simulation, dt: dt, mode: cameraMode)

        hudClock += dt
        if hudClock > 0.12 {
            hudClock = 0
            publishHUD()
            let nowDate = Date()
            if toasts.contains(where: { $0.expires < nowDate }) {
                toasts.removeAll { $0.expires < nowDate }
            }
        }
    }

    private func publishHUD() {
        let sim = simulation
        var h = HUDState()
        let p = sim.player
        h.power = p.power
        h.power3s = powerWindow.isEmpty ? p.power : powerWindow.map(\.p).reduce(0, +) / Double(powerWindow.count)
        h.wattsPerKg = h.power3s / max(sim.profile.weightKg, 30)
        h.cadence = p.cadence
        h.heartRate = p.heartRate
        h.speed = p.speed
        h.distance = p.distance
        h.totalDistance = sim.totalDistance
        h.lapDistance = sim.lapDistance
        h.elapsed = sim.elapsed
        let s = sim.sample
        h.grade = s.grade
        h.elevation = s.elevation
        h.climbed = sim.recorder.samples.isEmpty ? 0 : zip(sim.recorder.samples, sim.recorder.samples.dropFirst())
            .reduce(0) { $0 + max(0, $1.1.elevation - $1.0.elevation) }
        h.lap = sim.currentLap
        h.laps = sim.laps
        h.position = sim.playerPosition
        h.riders = sim.bots.count + 1
        h.draft = p.draft
        h.wPrime = p.wPrime
        h.gear = "\(p.gearFront)×\(p.gearRear)"
        h.headwind = p.headwind
        h.crosswind = p.crosswind
        h.braking = p.isBraking
        h.averagePower = sim.recorder.samples.isEmpty ? 0 : sim.recorder.samples.map(\.power).reduce(0, +) / Double(sim.recorder.samples.count)
        h.surfaceName = sim.route.surfaceSection(at: p.distance)?.name
        h.usingVirtualPower = !devices.hasHardwarePower
        h.trainerStatus = devices.canControlTrainer ? devices.lastCommand : ""
        h.ergOn = sim.ergEnabled
        h.difficulty = sim.trainerDifficulty

        if let active = sim.activeClimb {
            let c = active.climb
            h.climb = ClimbHUD(name: c.name, category: c.category.label, toGo: max(0, c.endDistance - sim.lapDistance),
                               length: c.length, averageGrade: c.averageGrade, elapsed: sim.elapsed - active.startTime,
                               personalBest: sim.personalBests["\(sim.route.id)#\(c.name)"])
        }
        if let w = sim.workout {
            let ftp = sim.profile.ftp
            h.workout = WorkoutHUD(name: w.workout.name, label: w.current?.label ?? (w.isComplete ? "Complete" : ""),
                                   target: w.targetWatts(ftp: ftp), remaining: w.remainingInSegment,
                                   nextLabel: w.next?.label, nextTarget: w.next?.startPower.map { ($0 * ftp).rounded() },
                                   elapsed: w.elapsed, total: w.workout.duration, cadenceTarget: w.current?.cadence)
        }
        // Riders around the player (time gaps estimated from distance gap / speed).
        let standings = sim.standings
        let myIndex = standings.firstIndex { $0.isPlayer } ?? 0
        let lo = max(0, myIndex - 4), hi = min(standings.count, myIndex + 5)
        let speed = max(p.speed, 3)
        h.nearby = standings[lo..<hi].enumerated().map { offset, r in
            NearbyRider(id: r.id, name: r.name, nation: r.nationCode, gapSeconds: (r.distance - p.distance) / speed,
                        wattsPerKg: r.wattsPerKg, isPlayer: r.isPlayer, isPacer: r.isPacer, position: lo + offset + 1,
                        finished: r.finishTime != nil)
        }
        h.others = sim.bots.map { ($0.id, $0.distance, $0.isPacer) }
        hud = h
    }

    // MARK: - Events → toasts

    private func handle(_ e: RideEvent) {
        let units = simulation.profile.units
        switch e {
        case let .climbStarted(name, category, length, grade):
            let len = Units.distance(length, units)
            push(Toast(title: "\(category) · \(name)", subtitle: String(format: "%.1f %@ at %.1f%% — timing started", len.value, len.unit, grade * 100),
                       style: .kom, expires: Date().addingTimeInterval(6)))
        case let .climbFinished(name, seconds, pb, previous):
            var sub = Units.clock(seconds)
            if pb, let previous { sub += " — new PB by \(Units.clock(previous - seconds))!" } else if pb { sub += " — first ascent recorded" } else if let previous { sub += " (PB \(Units.clock(previous)))" }
            push(Toast(title: "\(name) complete", subtitle: sub, style: pb ? .pb : .kom, expires: Date().addingTimeInterval(7)))
        case let .lapCompleted(lap, seconds):
            push(Toast(title: "Lap \(lap) of \(simulation.laps)", subtitle: Units.clock(seconds), style: .lap, expires: Date().addingTimeInterval(5)))
        case let .surfaceChanged(name, surface):
            push(Toast(title: surface.displayName, subtitle: name, style: .info, expires: Date().addingTimeInterval(5)))
        case let .workoutStep(label, target):
            push(Toast(title: label, subtitle: target.map { "\(Int($0)) W" } ?? "Ride by feel", style: .workout, expires: Date().addingTimeInterval(3)))
        case .workoutComplete:
            push(Toast(title: "Workout complete", subtitle: "Nice work — keep riding or end the session.", style: .pb, expires: Date().addingTimeInterval(8)))
        case let .finished(position, seconds):
            push(Toast(title: position.map { "Finished \(ordinal($0))" } ?? "Finished", subtitle: Units.clock(seconds), style: .finish,
                       expires: Date().addingTimeInterval(30)))
        case let .passed(name):
            push(Toast(title: "Passed \(name)", subtitle: "Now \(ordinal(simulation.playerPosition))", style: .info, expires: Date().addingTimeInterval(2.5)))
        }
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let t) where t != 11: suffix = "st"
        case (2, let t) where t != 12: suffix = "nd"
        case (3, let t) where t != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private func push(_ t: Toast) {
        toasts.removeAll { $0.style == t.style && t.style != .info }
        toasts.append(t)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
    }

    // MARK: - Controls

    func adjustVirtualPower(_ delta: Double) {
        devices.virtualPower = max(0, min(1500, devices.virtualPower + delta))
        if !devices.hasHardwarePower { devices.virtualPowerEnabled = true }
    }

    func adjustDifficulty(_ delta: Double) {
        simulation.trainerDifficulty = max(0, min(1, simulation.trainerDifficulty + delta))
        push(Toast(title: "Trainer difficulty", subtitle: "\(Int(simulation.trainerDifficulty * 100)) %", style: .info, expires: Date().addingTimeInterval(2)))
    }

    func toggleERG() {
        simulation.ergEnabled.toggle()
        push(Toast(title: simulation.ergEnabled ? "ERG on" : "ERG off", subtitle: simulation.ergEnabled ? "Trainer holds the target power" : "Simulation mode — feel the gradient",
                   style: .info, expires: Date().addingTimeInterval(2.5)))
    }

    private static let handledKeys: Set<UInt16> = [126, 125, 49, 53, 14, 33, 30, 4, 18, 19, 20, 21, 23, 22, 26]

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard RideController.handledKeys.contains(event.keyCode) else { return event }
            let shift = event.modifierFlags.contains(.shift)
            let code = event.keyCode
            Task { @MainActor [weak self] in self?.handleKey(code, shift: shift) }
            return nil
        }
    }

    private func handleKey(_ code: UInt16, shift: Bool) {
        switch code {
        case 126: adjustVirtualPower(shift ? 50 : 10)      // ↑
        case 125: adjustVirtualPower(shift ? -50 : -10)    // ↓
        case 49: togglePause()                             // space
        case 53: if phase == .finished { return } else { togglePause() } // esc pauses (end from the pause menu)
        case 14: toggleERG()                               // E
        case 33: adjustDifficulty(-0.1)                    // [
        case 30: adjustDifficulty(0.1)                     // ]
        case 4: showHUD.toggle()                           // H
        default:
            let map: [UInt16: CameraMode] = [18: .chase, 19: .close, 20: .firstPerson, 21: .side, 23: .front, 22: .helicopter, 26: .cinematic]
            if let m = map[code] { cameraMode = m }
        }
    }
}
