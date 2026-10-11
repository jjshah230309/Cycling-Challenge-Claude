import Foundation
import XCTest
@testable import BreakawayCore

final class ModelTests: XCTestCase {
    private func assertValid(_ m: ModelMesh, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(m.vertexCount, 0, label, file: file, line: line)
        XCTAssertEqual(m.normals.count, m.vertexCount, label, file: file, line: line)
        XCTAssertEqual(m.uvs.count, m.vertexCount, label, file: file, line: line)
        for p in m.positions where !(p.x.isFinite && p.y.isFinite && p.z.isFinite) {
            return XCTFail("\(label): non-finite vertex", file: file, line: line)
        }
        for n in m.normals where abs(n.norm - 1) > 1e-3 {
            return XCTFail("\(label): non-unit normal \(n)", file: file, line: line)
        }
        for part in m.parts {
            XCTAssertEqual(part.indices.count % 3, 0, label, file: file, line: line)
            XCTAssertLessThan(part.indices.max() ?? 0, UInt32(m.vertexCount), label, file: file, line: line)
        }
    }

    func testMeshPrimitivesFaceOutwards() {
        // Every primitive's normals should point away from its centre.
        var m = ModelMesh()
        m.ellipsoid(center: .zero, radii: SIMD3(1, 2, 0.5), material: "a")
        m.lathe(profile: [SIMD2(0.5, -1), SIMD2(1, 0), SIMD2(0.5, 1)], material: { _ in "b" })
        m.tube(path: [SIMD3(0, -1, 0), SIMD3(0.3, 0, 0), SIMD3(0, 1, 0)], radius: { _ in 0.2 }, material: "c", caps: false)
        assertValid(m, "primitives")
        for part in m.parts where part.material != "c" {
            var k = 0
            while k < part.indices.count {
                let a = m.positions[Int(part.indices[k])], b = m.positions[Int(part.indices[k + 1])], c = m.positions[Int(part.indices[k + 2])]
                let faceN = (b - a).crossp(c - a)
                let centroid = (a + b + c) / 3
                if faceN.norm > 1e-9 {
                    XCTAssertGreaterThan(faceN.dotp(SIMD3(centroid.x, centroid.y * 0.01, centroid.z)), -1e-6, "winding \(part.material)")
                }
                k += 3
            }
        }
        var box = ModelMesh()
        box.box(center: .zero, size: SIMD3(1, 1, 1), material: "x")
        XCTAssertEqual(box.triangleCount, 12)
        var plate = ModelMesh()
        plate.plate(outer: Section.gear(teeth: 52, pitchRadius: 0.105), inner: Section.circle(0.09, count: 208), thickness: 0.004, material: "ring")
        assertValid(plate, "chainring")
    }

    func testTransformsRoundTrip() {
        let t = RigidTransform.rotation(axis: SIMD3(0.3, 1, -0.2), angle: 1.1, origin: SIMD3(1, 2, 3))
        let p = SIMD3<Float>(0.4, -0.7, 2)
        let back = t.inverse.apply(t.apply(p))
        XCTAssertEqual((back - p).norm, 0, accuracy: 1e-5)
        let q = t.quaternion
        XCTAssertEqual((q * q).sum(), 1, accuracy: 1e-5)
        let b = RigidTransform.bone(from: .zero, to: SIMD3(0, 0, -2))
        XCTAssertEqual(b.y.z, -1, accuracy: 1e-6)
        XCTAssertEqual(b.x.crossp(b.y).dotp(b.z), 1, accuracy: 1e-6)
    }

    func testEveryBikeBuilds() {
        for frame in Garage.frames {
            for wheels in Garage.wheels {
                let bike = BikeModel(setup: BikeSetup(frameID: frame.id, wheelsID: wheels.id))
                for (name, mesh) in [("frame", bike.frame), ("steering", bike.steering), ("front", bike.frontWheel),
                                     ("rear", bike.rearWheel), ("crank", bike.crankset), ("pedal", bike.pedalRight)] {
                    assertValid(mesh, "\(frame.id)/\(wheels.id)/\(name)")
                }
                let a = bike.anchors
                XCTAssertEqual(a.frontAxle.y, a.wheelRadius, accuracy: 1e-6)
                XCTAssertGreaterThan(a.saddleTop.y, 0.9)
                XCTAssertLessThan(a.saddleTop.y, 1.06)
                // Wheels are the right size: ~670 mm across for 700c.
                let wb = bike.frontWheel.bounds
                XCTAssertEqual(wb.max.y - wb.min.y, 2 * a.wheelRadius, accuracy: 0.01, frame.id)
            }
            let low = BikeModel(setup: BikeSetup(frameID: frame.id), detail: 0.4)
            let high = BikeModel(setup: BikeSetup(frameID: frame.id))
            XCTAssertLessThan(low.frame.triangleCount + low.rearWheel.triangleCount,
                              (high.frame.triangleCount + high.rearWheel.triangleCount) / 3, "LOD saves triangles")
        }
    }

    func testRiderPosesAreAnatomicallySane() {
        for build in AvatarBuild.allCases {
            let rider = RiderModel(build: build)
            for (bone, mesh) in rider.segments { assertValid(mesh, "\(build)/\(bone)") }
            XCTAssertEqual(Set(rider.segments.keys), Set(RiderBone.allCases))
        }
        let d = RiderDimensions(build: .regular)
        for frame in Garage.frames {
            let bike = BikeModel(setup: BikeSetup(frameID: frame.id), detail: 0.4)
            let postures: [RiderPosture] = frame.style == .timeTrial ? [.aero, .hoods, .standing] : [.hoods, .drops, .tuck, .standing]
            for posture in postures {
                let params = PoseParameters.target(posture, anchors: bike.anchors)
                var minKnee: Float = 10, maxKnee: Float = 0
                for k in 0..<36 {
                    let crank = Double(k) / 36 * 2 * .pi
                    let roll = posture == .standing ? RiderPose.standingRock(crankAngle: crank) : 0
                    let pose = RiderPose.solve(params: params, anchors: bike.anchors, dimensions: d, crankAngle: crank, roll: roll)
                    XCTAssertEqual(pose.bones.count, RiderBone.allCases.count)
                    minKnee = min(minKnee, pose.kneeAngles.right)
                    maxKnee = max(maxKnee, pose.kneeAngles.right)
                    // Hands reach the bars (or the extensions).
                    let hand = pose.bones[.handR]!
                    XCTAssertLessThan((hand.apply(SIMD3(0, 0.055, 0)) - params.grip).norm, 0.03, "\(frame.id) \(posture) hand")
                    // Feet stay on the pedals.
                    let foot = pose.bones[.footR]!
                    let cleat = foot.apply(d.cleat)
                    XCTAssertLessThan((cleat - pose.pedalRight.origin).norm, 0.05, "\(frame.id) \(posture) foot")
                    // The head stays above the bars and the hips above the saddle.
                    XCTAssertGreaterThan(pose.bones[.head]!.origin.y, bike.anchors.hoods.y - 0.05, "\(frame.id) \(posture) head")
                    XCTAssertGreaterThan(pose.bones[.torso]!.origin.y, bike.anchors.saddleTop.y)
                }
                // Knee flexion through the stroke: ~70° at the top, ~145° (fairly straight) at the bottom.
                let toDeg = Float(180 / Double.pi)
                XCTAssertGreaterThan(minKnee * toDeg, 55, "\(frame.id) \(posture) knee top")
                XCTAssertLessThan(minKnee * toDeg, posture == .standing ? 115 : 95, "\(frame.id) \(posture) knee top")
                XCTAssertGreaterThan(maxKnee * toDeg, 128, "\(frame.id) \(posture) knee bottom")
                XCTAssertLessThan(maxKnee * toDeg, 179, "\(frame.id) \(posture) knee bottom")
            }
        }
    }

    func testTorsoAngleFollowsPosture() {
        let bike = BikeModel(setup: BikeSetup(frameID: "summit"), detail: 0.4)
        let d = RiderDimensions(build: .regular)
        func torsoAngle(_ p: RiderPosture) -> Float {
            let pose = RiderPose.solve(params: .target(p, anchors: bike.anchors), anchors: bike.anchors, dimensions: d, crankAngle: 0)
            let y = pose.bones[.torso]!.y
            return atan2(y.y, -y.z) * 180 / .pi
        }
        let hoods = torsoAngle(.hoods), drops = torsoAngle(.drops), tuck = torsoAngle(.tuck)
        XCTAssertEqual(hoods, 35, accuracy: 10)
        XCTAssertLessThan(drops, hoods)
        XCTAssertLessThan(tuck, drops + 5)
        XCTAssertGreaterThan(torsoAngle(.standing), drops)
    }

    /// Writes posed rider + bike OBJ/MTL files for visual inspection when
    /// BREAKAWAY_EXPORT_OBJ points at a directory.
    func testExportPreviewModels() throws {
        guard let dir = ProcessInfo.processInfo.environment["BREAKAWAY_EXPORT_OBJ"] else { throw XCTSkip("set BREAKAWAY_EXPORT_OBJ") }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let rider = RiderModel(build: .regular)
        let ttRider = RiderModel(build: .regular, timeTrialHelmet: true)
        let cases: [(String, String, String, RiderPosture, Double)] = [
            ("allroad-hoods", "allroad", "aero50", .hoods, 0.6), ("summit-drops", "summit", "climber", .drops, 2.0),
            ("apex-tuck", "apex", "deep80", .tuck, 0), ("heritage-standing", "heritage", "alloy", .standing, 0.9),
            ("velocity-aero", "velocity", "disc", .aero, 1.4), ("nomad-hoods", "nomad", "gravel40", .hoods, 3.5),
            ("piste-drops", "piste", "deep80", .drops, 4.5),
        ]
        for (name, frameID, wheelsID, posture, crank) in cases {
            let bike = BikeModel(setup: BikeSetup(frameID: frameID, wheelsID: wheelsID))
            let a = bike.anchors
            var all = ModelMesh()
            all.append(bike.frame)
            all.append(bike.steering)
            all.append(bike.frontWheel, transform: .translation(a.frontAxle))
            all.append(bike.rearWheel, transform: .translation(a.rearAxle))
            all.append(bike.crankset, transform: RigidTransform.rotation(axis: SIMD3(1, 0, 0), angle: -Float(crank), origin: a.bottomBracket))
            let r = frameID == "velocity" ? ttRider : rider
            let roll = posture == .standing ? RiderPose.standingRock(crankAngle: crank) : 0
            let pose = RiderPose.solve(params: .target(posture, anchors: a), anchors: a, dimensions: r.dimensions, crankAngle: crank, roll: roll)
            all.append(bike.pedalRight, transform: pose.pedalRight)
            all.append(bike.pedalLeft, transform: pose.pedalLeft)
            for (bone, t) in pose.bones { all.append(r.segments[bone]!, transform: t) }
            try all.objText(name: name).write(to: url.appendingPathComponent("\(name).obj"), atomically: true, encoding: .utf8)
            print("exported \(name): \(all.triangleCount) triangles")
        }
    }

    func testSceneryBuilds() {
        for kind in Scenery.TreeKind.allCases {
            var counts: [Int] = []
            for detail: Float in [1, 0.5, 0.2] {
                let t = Scenery.tree(kind, seed: 42, detail: detail)
                assertValid(t, "\(kind) \(detail)")
                counts.append(t.triangleCount)
                let b = t.bounds
                XCTAssertGreaterThan(b.max.y, 3, "\(kind) height")
                XCTAssertLessThan(b.max.y, 30, "\(kind) height")
                XCTAssertTrue(t.hasVertexColors || kind == .palm, "\(kind) colours")
            }
            XCTAssertGreaterThan(counts[0], counts[2], "\(kind) LOD")
        }
        for style in Scenery.HouseStyle.allCases {
            let h = Scenery.house(style, width: 10, depth: 8, floors: 2, foundation: 1, wallColor: SIMD4(1, 0.9, 0.8, 1),
                                  roofColor: SIMD4(0.5, 0.2, 0.1, 1), seed: 3)
            assertValid(h, "house \(style)")
            XCTAssertGreaterThan(h.bounds.max.y, 6.4, "\(style)")
            XCTAssertEqual(h.bounds.min.y, -1, accuracy: 0.01)
        }
        for pose in Scenery.SpectatorPose.allCases {
            assertValid(Scenery.spectator(pose: pose, shirt: SIMD4(1, 0, 0, 1), trousers: SIMD4(0, 0, 1, 1), skin: SIMD4(0.8, 0.6, 0.5, 1), seed: 9), "\(pose)")
        }
        assertValid(Scenery.rock(seed: 5), "rock")
        assertValid(Scenery.campervan(color: SIMD4(1, 1, 1, 1), seed: 2), "van")
        assertValid(Scenery.grassTuft(seed: 1, flowers: true), "grass")
    }

    func testExportSceneryPreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["BREAKAWAY_EXPORT_OBJ"] else { throw XCTSkip("set BREAKAWAY_EXPORT_OBJ") }
        let url = URL(fileURLWithPath: dir)
        var trees = ModelMesh()
        for (i, kind) in Scenery.TreeKind.allCases.enumerated() {
            trees.append(Scenery.tree(kind, seed: UInt64(i + 7)), transform: .translation(SIMD3(Float(i) * 9 - 27, 0, 0)))
            trees.append(Scenery.tree(kind, seed: UInt64(i + 7), detail: 0.5), transform: .translation(SIMD3(Float(i) * 9 - 27, 0, 12)))
        }
        for k in 0..<4 { trees.append(Scenery.rock(seed: UInt64(k)), transform: .translation(SIMD3(Float(k) * 3 - 5, 0.3, -6))) }
        try trees.objText(name: "trees").write(to: url.appendingPathComponent("trees.obj"), atomically: true, encoding: .utf8)
        var houses = ModelMesh()
        let wall: [SIMD4<Float>] = [SIMD4(0.95, 0.9, 0.8, 1), SIMD4(0.9, 0.75, 0.6, 1), SIMD4(0.85, 0.85, 0.85, 1)]
        for (i, style) in Scenery.HouseStyle.allCases.enumerated() {
            let h = Scenery.house(style, width: i % 2 == 0 ? 11 : 8, depth: i % 2 == 0 ? 8 : 10, floors: style == .apartment ? 4 : 2,
                                  wallColor: wall[i % 3], roofColor: SIMD4(0.55, 0.25, 0.15, 1), seed: UInt64(i))
            houses.append(h, transform: .translation(SIMD3(Float(i) * 15 - 37, 0, 0)))
        }
        for (i, pose) in Scenery.SpectatorPose.allCases.enumerated() {
            houses.append(Scenery.spectator(pose: pose, shirt: SIMD4(0.9, 0.2, 0.2, 1), trousers: SIMD4(0.1, 0.1, 0.3, 1),
                                            skin: SIMD4(0.8, 0.6, 0.45, 1), seed: UInt64(i), detail: 1),
                          transform: .translation(SIMD3(Float(i) * 1.2 - 3, 0, 9)))
        }
        houses.append(Scenery.campervan(color: SIMD4(0.95, 0.95, 0.9, 1), seed: 4), transform: .translation(SIMD3(6, 0, 10)))
        for k in 0..<40 {
            houses.append(Scenery.grassTuft(seed: UInt64(k), flowers: k % 5 == 0), transform: .translation(SIMD3(Float(k % 8) * 0.4 - 12, 0, 9 + Float(k / 8) * 0.4)))
        }
        try houses.objText(name: "houses").write(to: url.appendingPathComponent("houses.obj"), atomically: true, encoding: .utf8)
    }
}
