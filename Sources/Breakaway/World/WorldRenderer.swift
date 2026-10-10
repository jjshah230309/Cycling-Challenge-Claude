import AppKit
import BreakawayCore
import SceneKit
import SwiftUI
import simd

enum CameraMode: Int, CaseIterable, Identifiable {
    case chase = 1, close, firstPerson, side, front, helicopter, cinematic

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .chase: return "Chase"
        case .close: return "Close"
        case .firstPerson: return "Rider's eye"
        case .side: return "Side"
        case .front: return "Front"
        case .helicopter: return "Helicopter"
        case .cinematic: return "Cinematic"
        }
    }
}

/// Owns the camera and rider nodes and syncs them with the simulation every frame.
final class WorldRenderer {
    let world: BuiltWorld
    let cameraNode = SCNNode()
    private var riders: [String: RiderNode] = [:]
    private var camPosition: SIMD3<Float>?
    private var camTarget: SIMD3<Float>?
    private var clock: Float = 0

    init(world: BuiltWorld, simulation: RideSimulation) {
        self.world = world
        let camera = SCNCamera()
        camera.fieldOfView = 62
        camera.zNear = 0.1
        camera.zFar = 60_000
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.1
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 0.9
        camera.vignettingIntensity = 0.35
        camera.vignettingPower = 0.6
        // No SSAO / motion blur: both dither visibly on large terrain and cost frame time.
        cameraNode.camera = camera
        cameraNode.name = "camera"
        world.scene.rootNode.addChildNode(cameraNode)
        for r in [simulation.player] + simulation.bots {
            let node = RiderNode(state: r, showTag: !r.isPlayer)
            riders[r.id] = node
            world.ridersRoot.addChildNode(node)
        }
        update(simulation: simulation, dt: 1, mode: .chase)
    }

    private func scenePoint(_ route: Route, _ d: Double, lateral: Double = 0, lift: Double) -> SIMD3<Float> {
        let s = route.sample(at: d)
        let right = LocalPoint(x: s.direction.y, y: -s.direction.x)
        return world.frame.point(s.position + right * lateral, s.elevation + lift)
    }

    func update(simulation sim: RideSimulation, dt: Double, mode: CameraMode) {
        let route = world.route
        let frame = world.frame
        let fdt = Float(min(dt, 0.1))
        clock += fdt
        let player = sim.player

        // Riders.
        let camPos = cameraNode.simdPosition
        for state in [player] + sim.bots {
            guard let node = riders[state.id] else { continue }
            let p = scenePoint(route, state.distance, lateral: state.lateral, lift: 0)
            let dist = simd_distance(p, camPos)
            let visible = state.isPlayer ? mode != .firstPerson : dist < 1200
            node.isHidden = !visible
            guard visible else { continue }
            node.update(state: state, route: route, frame: frame, dt: fdt, detailed: dist < 90)
            node.setTagVisible(dist > 9 && dist < 55)
            // Fade riders that sit between the camera and the player so they never block the view.
            node.opacity = !state.isPlayer && dist < 5.5 ? CGFloat(max(0.15, (dist - 2) / 3.5)) : 1
        }

        // Camera.
        let d = player.distance
        let s = route.sample(at: d)
        let fwd = frame.direction(s.direction)
        let right = SIMD3<Float>(-fwd.z, 0, fwd.x)
        let up = SIMD3<Float>(0, 1, 0)
        let riderPos = scenePoint(route, d, lateral: player.lateral, lift: 0)
        var targetPos: SIMD3<Float>
        var lookAt: SIMD3<Float>
        var stiffness: Float = 5
        switch mode {
        case .chase:
            targetPos = scenePoint(route, d - 6.5, lateral: player.lateral * 0.6, lift: 2.3)
            lookAt = scenePoint(route, d + 6, lateral: player.lateral * 0.5, lift: 1.0)
        case .close:
            targetPos = scenePoint(route, d - 3.2, lateral: player.lateral + 0.7, lift: 1.45)
            lookAt = riderPos + up * 1.0 + fwd * 1.2
            stiffness = 7
        case .firstPerson:
            targetPos = riderPos + up * 1.52 + fwd * 0.05
            lookAt = scenePoint(route, d + 14, lateral: player.lateral, lift: 0.9)
            stiffness = 14
        case .side:
            targetPos = riderPos + right * 4.2 + up * 1.1 - fwd * 0.4
            lookAt = riderPos + up * 0.85
            stiffness = 8
        case .front:
            targetPos = scenePoint(route, d + 5.5, lateral: player.lateral - 0.4, lift: 1.5)
            lookAt = riderPos + up * 1.05
            stiffness = 7
        case .helicopter:
            // Behind along the heading (not the road) and high enough to clear switchbacks.
            targetPos = riderPos - fwd * 26 + up * 34 + right * 8
            lookAt = riderPos + fwd * 14
            stiffness = 2
        case .cinematic:
            let a = clock * 0.18
            targetPos = riderPos + SIMD3(cos(a) * 9, 3.2 + sin(clock * 0.07) * 1.5, sin(a) * 9)
            lookAt = riderPos + up * 1.0
            stiffness = 3
        }
        // Never dip into the hillside, and keep the rider in sight: on hairpins the
        // inside bank can rise between camera and rider, so lift until the line is clear.
        let terrain = route.terrain
        func groundY(_ p: SIMD3<Float>) -> Float {
            Float(terrain.height(x: Double(p.x), y: Double(-p.z)) - frame.baseElevation)
        }
        targetPos.y = max(targetPos.y, groundY(targetPos) + (mode == .firstPerson ? 0.3 : 0.9))
        if mode != .firstPerson {
            let focus = riderPos + up * 1.0
            for _ in 0..<6 {
                var worst: Float = 0
                for k in 1..<10 {
                    let t = Float(k) / 10
                    let p = targetPos + (focus - targetPos) * t
                    worst = max(worst, groundY(p) + 0.4 - p.y)
                }
                if worst <= 0 { break }
                targetPos.y += worst + 0.5
            }
        }

        let k = 1 - exp(-stiffness * fdt)
        if let p = camPosition, let t = camTarget, dt < 0.5 {
            camPosition = p + (targetPos - p) * k
            camTarget = t + (lookAt - t) * min(1, k * 1.6)
        } else {
            camPosition = targetPos
            camTarget = lookAt
        }
        cameraNode.simdPosition = camPosition!
        cameraNode.simdLook(at: camTarget!, up: up, localFront: SIMD3(0, 0, -1))

        // Keep crisp shadows around the player.
        world.sun.simdPosition = riderPos - world.sun.simdWorldFront * 250
    }
}

/// Hosts the SceneKit view.
struct SceneViewContainer: NSViewRepresentable {
    let renderer: WorldRenderer

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.scene = renderer.world.scene
        view.pointOfView = renderer.cameraNode
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isPlaying = true
        view.allowsCameraControl = false
        view.backgroundColor = .black
        view.isJitteringEnabled = false
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== renderer.world.scene { view.scene = renderer.world.scene }
        if view.pointOfView !== renderer.cameraNode { view.pointOfView = renderer.cameraNode }
    }
}
