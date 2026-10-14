import AppKit
import BreakawayCore
import Foundation
import Metal
import SceneKit
import SwiftUI

/// Headless renderer used by CI and for quick visual checks:
///
///     Breakaway --snapshot <output-dir> [route-id,route-id,…]
///
/// Builds each route's world, rides the simulation to the most interesting
/// point (two-thirds up its biggest climb) and writes PNGs from several cameras.
@MainActor
enum SnapshotTool {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return }
        let out = URL(fileURLWithPath: args.count > i + 1 ? args[i + 1] : "snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ids = args.count > i + 2 ? args[i + 2].split(separator: ",").map(String.init) : RouteCatalog.all.map(\.id)
        var failures = 0
        let devices = DeviceManager()
        devices.virtualPowerEnabled = true
        for id in ids {
            guard let route = RouteCatalog.route(id: id) else {
                print("unknown route \(id)")
                failures += 1
                continue
            }
            if !render(route: route, to: out, devices: devices) { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }

    private static func render(route: Route, to dir: URL, devices: DeviceManager) -> Bool {
        let t0 = Date()
        let world = WorldBuilder.build(route: route) { _, _ in }
        let buildTime = Date().timeIntervalSince(t0)

        var profile = RiderProfile(name: "You", weightKg: 70, ftp: 300)
        profile.bike = BikeSetup(frameID: "apex", wheelsID: "deep80")
        let sim = RideSimulation(route: route, mode: .groupRide, profile: profile, botCount: 14,
                                 weather: Weather.preset(.typical, for: route), seed: 7)
        let target: Double
        if let climb = route.climbs.max(by: { $0.elevationGain < $1.elevationGain }) {
            target = climb.startDistance + climb.length * 0.66
        } else {
            target = route.length * 0.4
        }
        var guardSteps = 0
        while sim.player.distance < target, !sim.isFinished, guardSteps < 40_000 {
            sim.step(dt: 0.25, input: PlayerInput(power: 300, cadence: 88))
            guardSteps += 1
        }
        let renderer = WorldRenderer(world: world, simulation: sim)
        let scn = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        scn.scene = world.scene
        scn.pointOfView = renderer.cameraNode
        var ok = true
        for mode in [CameraMode.chase, .side, .helicopter] {
            // Let the camera settle.
            for _ in 0..<90 { renderer.update(simulation: sim, dt: 1.0 / 30, mode: mode) }
            let image = scn.snapshot(atTime: 0, with: CGSize(width: 1280, height: 720), antialiasingMode: .multisampling4X)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                print("✗ \(route.id) \(mode.title): render failed")
                ok = false
                continue
            }
            let file = dir.appendingPathComponent("\(route.id)-\(mode.title.lowercased().replacingOccurrences(of: " ", with: "-")).png")
            try? png.write(to: file)
        }
        // Full in-ride frame: chase camera + the SwiftUI HUD composited on top.
        for _ in 0..<90 { renderer.update(simulation: sim, dt: 1.0 / 30, mode: .chase) }
        let frame3D = scn.snapshot(atTime: 0, with: CGSize(width: 1440, height: 900), antialiasingMode: .multisampling4X)
        let controller = RideController(simulation: sim, devices: devices, renderer: renderer)
        let hud = ZStack {
            Image(nsImage: frame3D).resizable()
            RideHUD(controller: controller, hud: controller.hud, profile: sim.profile, showsControls: false)
        }
        .frame(width: 1440, height: 900)
        .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: hud)
        r.scale = 1
        if let img = r.nsImage, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(route.id)-ride.png"))
        } else {
            print("✗ \(route.id): HUD composite failed")
        }
        print(String(format: "✓ %@  world %.1fs  at km %.2f  elev %.0f m", route.id, buildTime, sim.player.distance / 1000,
                     route.elevation(at: sim.player.distance)))
        return ok
    }
}
