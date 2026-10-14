import AppKit
import BreakawayCore
import Foundation
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case ride, routes, workouts, garage, devices, profile, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ride: return "Ride"
        case .routes: return "Routes"
        case .workouts: return "Workouts"
        case .garage: return "Garage"
        case .devices: return "Devices"
        case .profile: return "Profile"
        case .history: return "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .ride: return "play.circle.fill"
        case .routes: return "map.fill"
        case .workouts: return "chart.bar.xaxis"
        case .garage: return "bicycle"
        case .devices: return "antenna.radiowaves.left.and.right"
        case .profile: return "person.crop.circle.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// App-wide state: rider profile, history, selections, devices and the active ride.
@MainActor
final class AppModel: ObservableObject {
    @Published var profile: RiderProfile { didSet { Storage.save(profile, to: "profile.json") } }
    @Published private(set) var history: [RideSummary]
    @Published private(set) var personalBests: [String: Double]
    @Published private(set) var importedWorkouts: [Workout]
    @Published private(set) var importedRoutes: [Route] = []

    @Published var section: SidebarSection = .ride
    @Published var selectedRouteID: String { didSet { UserDefaults.standard.set(selectedRouteID, forKey: "selectedRouteID") } }
    @Published var mode: RideMode = .freeRide
    @Published var laps: Int = 1
    @Published var botCount: Int = 14
    @Published var weatherPreset: Weather.Preset = .typical
    @Published var selectedWorkoutID: String?
    @Published var activeRide: RideController?
    @Published var lastFinishedRide: RideSummary?
    @Published var presentGPXImporter = false
    @Published var presentZWOImporter = false
    @Published var alertMessage: String?

    let devices = DeviceManager()

    init() {
        profile = Storage.load(RiderProfile.self, from: "profile.json") ?? RiderProfile()
        history = (Storage.load([RideSummary].self, from: "history.json") ?? []).sorted { $0.date > $1.date }
        personalBests = Storage.load([String: Double].self, from: "personal-bests.json") ?? [:]
        importedWorkouts = Storage.load([Workout].self, from: "workouts.json") ?? []
        selectedRouteID = UserDefaults.standard.string(forKey: "selectedRouteID") ?? "alpe-dhuez"
        loadImportedRoutes()
        if route(id: selectedRouteID) == nil { selectedRouteID = "alpe-dhuez" }
    }

    // MARK: - Routes & workouts

    var allRouteRecords: [RouteRecord] { RouteCatalog.all + importedRoutes.map(\.record) }

    func route(id: String) -> Route? {
        RouteCatalog.route(id: id) ?? importedRoutes.first { $0.id == id }
    }

    var selectedRoute: Route? { route(id: selectedRouteID) }

    var allWorkouts: [Workout] { WorkoutLibrary.all + importedWorkouts }

    var selectedWorkout: Workout? {
        guard let id = selectedWorkoutID else { return nil }
        return allWorkouts.first { $0.id == id }
    }

    func personalBest(routeID: String, climb: String) -> Double? { personalBests["\(routeID)#\(climb)"] }

    private func loadImportedRoutes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.routesDirectory, includingPropertiesForKeys: nil)) ?? []
        importedRoutes = files.filter { $0.pathExtension.lowercased() == "gpx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let track = try? GPXFormat.importTrack(data, fallbackName: url.deletingPathExtension().lastPathComponent)
                else { return nil }
                return Route(importedName: track.name, coordinates: track.coordinates, elevations: track.elevations)
            }
    }

    func importGPX(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let track = try GPXFormat.importTrack(data, fallbackName: url.deletingPathExtension().lastPathComponent)
            let dest = Storage.routesDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try data.write(to: dest)
            loadImportedRoutes()
            let route = Route(importedName: track.name, coordinates: track.coordinates, elevations: track.elevations)
            selectedRouteID = route.id
            section = .routes
            if !track.hadElevation {
                alertMessage = "“\(track.name)” has no elevation data, so it will ride flat. Export the GPX with elevation for a realistic climb."
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteImportedRoute(_ route: Route) {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.routesDirectory, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            if let data = try? Data(contentsOf: f),
               let t = try? GPXFormat.importTrack(data, fallbackName: f.deletingPathExtension().lastPathComponent),
               Route(importedName: t.name, coordinates: t.coordinates, elevations: t.elevations).id == route.id {
                try? FileManager.default.removeItem(at: f)
            }
        }
        loadImportedRoutes()
        if selectedRouteID == route.id { selectedRouteID = "alpe-dhuez" }
    }

    func importZWO(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let w = try ZWOFormat.parse(try Data(contentsOf: url), fallbackName: url.deletingPathExtension().lastPathComponent)
            importedWorkouts.removeAll { $0.id == w.id }
            importedWorkouts.append(w)
            Storage.save(importedWorkouts, to: "workouts.json")
            selectedWorkoutID = w.id
            section = .workouts
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteImportedWorkout(_ w: Workout) {
        importedWorkouts.removeAll { $0.id == w.id }
        Storage.save(importedWorkouts, to: "workouts.json")
        if selectedWorkoutID == w.id { selectedWorkoutID = nil }
    }

    // MARK: - Rides

    func startRide() {
        guard activeRide == nil, let route = selectedRoute else { return }
        var workout: Workout?
        if mode == .workout {
            workout = selectedWorkout ?? WorkoutLibrary.all.first { $0.id == "sweetspot-3x12" }
            selectedWorkoutID = workout?.id
        }
        let sim = RideSimulation(route: route, laps: route.isLoop ? laps : 1, mode: mode, profile: profile,
                                 botCount: mode == .timeTrial ? 0 : botCount, workout: workout,
                                 personalBests: personalBests, weather: Weather.preset(weatherPreset, for: route),
                                 seed: UInt64.random(in: 1...UInt64.max))
        activeRide = RideController(simulation: sim, devices: devices) { [weak self] summary, samples in
            self?.rideEnded(summary: summary, samples: samples)
        }
    }

    func closeRide() {
        activeRide?.stop()
        activeRide = nil
    }

    private func rideEnded(summary: RideSummary?, samples: [RideSample]) {
        guard let summary, summary.metrics.duration >= 30 else { return }
        history.insert(summary, at: 0)
        Storage.save(history, to: "history.json")
        Storage.saveSamples(samples, for: summary.id)
        if let sim = activeRide?.simulation {
            for (k, v) in sim.personalBests where personalBests[k].map({ v < $0 }) ?? true {
                personalBests[k] = v
            }
            Storage.save(personalBests, to: "personal-bests.json")
        }
        let levelBefore = profile.level
        profile.xp += summary.xpEarned
        profile.totalDistanceMeters += summary.metrics.distance
        profile.totalClimbMeters += summary.metrics.elevationGain
        profile.totalRideSeconds += summary.metrics.duration
        lastFinishedRide = summary
        if profile.level > levelBefore {
            let unlocked = Garage.frames.filter { $0.unlockLevel == profile.level }.map(\.name)
                + Garage.wheels.filter { $0.unlockLevel == profile.level }.map(\.name)
            alertMessage = "Level \(profile.level)! " + (unlocked.isEmpty ? "Keep riding." : "Unlocked: \(unlocked.joined(separator: ", ")).")
        }
    }

    func deleteRide(_ ride: RideSummary) {
        history.removeAll { $0.id == ride.id }
        Storage.deleteSamples(for: ride.id)
        Storage.save(history, to: "history.json")
    }

    // MARK: - Exports

    enum ExportFormat: String, CaseIterable { case fit, gpx, tcx }

    func export(_ ride: RideSummary, as format: ExportFormat) {
        let samples = Storage.loadSamples(for: ride.id)
        guard !samples.isEmpty else {
            alertMessage = "The detailed samples for this ride are no longer available."
            return
        }
        let data: Data
        switch format {
        case .fit: data = FITEncoder.encode(summary: ride, samples: samples, start: ride.date)
        case .gpx: data = Data(GPXFormat.exportRide(summary: ride, samples: samples, start: ride.date).utf8)
        case .tcx: data = Data(GPXFormat.exportTCX(summary: ride, samples: samples, start: ride.date).utf8)
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "Breakaway-\(df.string(from: ride.date))-\(ride.routeID).\(format.rawValue)"
        save(data: data, suggestedName: name)
    }

    func exportRouteGPX(_ route: Route) {
        save(data: Data(GPXFormat.exportRoute(route).utf8), suggestedName: "\(route.id).gpx")
    }

    func exportWorkout(_ w: Workout) {
        save(data: Data(ZWOFormat.export(w).utf8), suggestedName: "\(w.name).zwo")
    }

    private func save(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url) } catch { alertMessage = error.localizedDescription }
        }
    }
}
