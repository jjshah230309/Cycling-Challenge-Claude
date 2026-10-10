import BreakawayCore
import SceneKit
import SwiftUI

struct GarageView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            previewColumn
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(title: "Garage", subtitle: "Frames and wheels change weight, aerodynamics and rolling resistance.")
                    frameList
                    wheelList
                }
                .padding(24)
            }
            .frame(width: 440)
            .background(Theme.panel.opacity(0.4))
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            BikePreview(profile: model.profile)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.24), Theme.background],
                                           startPoint: .top, endPoint: .bottom))
            bikeStats.padding(20)
        }
        .frame(minWidth: 420)
    }

    private var frameList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FRAMES").font(.caption.bold()).foregroundStyle(Theme.secondaryText)
            ForEach(Garage.frames) { f in
                EquipmentRow(title: f.name, subtitle: f.blurb, detail: String(format: "%.1f kg · CdA ×%.2f", f.weight, f.cdaFactor),
                             swatch: Theme.color(f.color), locked: model.profile.level < f.unlockLevel, unlockLevel: f.unlockLevel,
                             selected: model.profile.bike.frameID == f.id) {
                    model.profile.bike.frameID = f.id
                }
            }
        }
    }

    private var wheelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHEELS").font(.caption.bold()).foregroundStyle(Theme.secondaryText).padding(.top, 8)
            ForEach(Garage.wheels) { w in
                EquipmentRow(title: w.name, subtitle: w.blurb,
                             detail: String(format: "%.0f mm · %.2f kg · ΔCdA %+.3f", w.rimDepthMM, w.weight, w.cdaDelta),
                             swatch: .gray, locked: model.profile.level < w.unlockLevel, unlockLevel: w.unlockLevel,
                             selected: model.profile.bike.wheelsID == w.id) {
                    model.profile.bike.wheelsID = w.id
                }
            }
        }
    }

    private var bikeStats: some View {
        let bike = model.profile.bike
        let phys = model.profile.physicsBody()
        let flat = CyclingPhysics.steadySpeed(power: 250, grade: 0, body: phys) * 3.6
        let climb = CyclingPhysics.steadySpeed(power: 250, grade: 0.08, body: phys) * 3.6
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(bike.frame.name) + \(bike.wheels.name)").font(.headline)
                RatingBar(label: "Aero", value: bike.aeroRating)
                RatingBar(label: "Climbing", value: bike.climbRating)
                RatingBar(label: "Cobbles & gravel", value: bike.roughRating)
                HStack(spacing: 24) {
                    StatBlock(label: "Bike weight", value: String(format: "%.2f", bike.weight), unit: "kg")
                    StatBlock(label: "CdA", value: String(format: "%.3f", phys.cda), unit: "m²")
                    StatBlock(label: "250 W flat", value: String(format: "%.1f", flat), unit: "km/h")
                    StatBlock(label: "250 W @ 8%", value: String(format: "%.1f", climb), unit: "km/h")
                }
            }
        }
    }
}

struct RatingBar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 110, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.accent).frame(width: g.size.width * value / 100)
                }
            }
            .frame(height: 8)
            Text("\(Int(value))").font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
        }
    }
}

struct EquipmentRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let swatch: Color
    let locked: Bool
    let unlockLevel: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { if !locked { action() } }) {
            HStack(spacing: 12) {
                Circle().fill(swatch).frame(width: 22, height: 22).overlay(Circle().stroke(Color.white.opacity(0.3)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText.opacity(0.8))
                }
                Spacer()
                if locked {
                    Label("Lv \(unlockLevel)", systemImage: "lock.fill").font(.caption.bold()).foregroundStyle(Theme.secondaryText)
                } else if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.title3)
                }
            }
            .padding(12)
            .background(selected ? Theme.accentSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent : Theme.stroke))
            .opacity(locked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
    }
}

/// Turntable 3D preview of the rider's current bike and kit.
struct BikePreview: View {
    let profile: RiderProfile

    var body: some View {
        let built = makeScene()
        SceneView(scene: built.0, pointOfView: built.1, options: [.allowsCameraControl])
            .id("\(profile.bike.frameID)-\(profile.bike.wheelsID)-\(profile.kit.jersey.hex)-\(profile.kit.helmet.hex)-\(profile.build.rawValue)")
    }

    private func makeScene() -> (SCNScene, SCNNode) {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let state = RiderState(id: "preview", name: profile.name, nationCode: profile.nationCode, isPlayer: true, isPacer: false,
                               distance: 0, speed: 0, power: 0, cadence: 0, heartRate: nil, lateral: 0, draft: 0,
                               weightKg: profile.weightKg, kit: profile.kit, bike: profile.bike, build: profile.build)
        let rider = RiderNode(state: state, showTag: false)
        let spin = SCNNode()
        spin.addChildNode(rider)
        spin.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16)))
        scene.rootNode.addChildNode(spin)
        let floor = SCNCylinder(radius: 1.3, height: 0.02)
        floor.materials = [SceneMath.material(NSColor(white: 0.18, alpha: 1), roughness: 0.4)]
        let fn = SCNNode(geometry: floor)
        fn.simdPosition = SIMD3(0, -0.01, 0)
        scene.rootNode.addChildNode(fn)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 38
        cam.simdPosition = SIMD3(2.6, 1.5, 0.4)
        cam.simdLook(at: SIMD3(0, 0.75, 0), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(cam)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.simdOrientation = simd_quatf(angle: -0.8, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0))
        scene.rootNode.addChildNode(key)
        scene.lightingEnvironment.contents = ProceduralTextures.sky(biome: .alpine)
        scene.lightingEnvironment.intensity = 1.2
        return (scene, cam)
    }
}
