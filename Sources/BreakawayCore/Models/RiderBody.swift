import Foundation

/// A realistic human body (from the CC0 MakeHuman base mesh, see
/// `tools/riderbody/build_rider_body.py`) skinned to Breakaway's rider skeleton.
///
/// Every vertex is bound to up to three `RiderBone`s with linear-blend weights.
/// `restFrames` are the bones in the rest (standing) pose, built exactly like
/// the pose solver builds them, so `pose ∘ rest⁻¹` deforms the body.
public struct RiderBody: Sendable {
    /// Rest-pose mesh with kit regions as materials (jersey, sleeve, shorts, sock, skin, hair).
    public let mesh: ModelMesh
    /// Per vertex: up to three bone indices (into `RiderBone.allCases`) and weights summing to 1.
    public let boneIndices: [SIMD3<UInt8>]
    public let boneWeights: [SIMD3<Float>]
    /// Rest-pose bone frames, indexed like `RiderBone.allCases`.
    public let restFrames: [RigidTransform]
    public let dimensions: RiderDimensions
    /// Centre and half-extents of the skull in head-bone space (for fitting helmets).
    public let skullCentre: SIMD3<Float>
    public let skullRadii: SIMD3<Float>

    public static let shared: RiderBody = RiderBody.decode()

    static func joint(_ name: String) -> V3 { joints[name] ?? .zero }

    private static func decode() -> RiderBody {
        guard let data = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) else {
            fatalError("corrupt rider body data")
        }
        let bytes = [UInt8](data)
        var o = 4
        func u32() -> Int {
            let v = Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
            o += 4
            return v
        }
        func i16(_ k: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[k]) | UInt16(bytes[k + 1]) << 8) }
        let n = u32()
        var mesh = ModelMesh()
        let posBase = o, nrmBase = posBase + n * 6, uvBase = nrmBase + n * 3, biBase = uvBase + n * 4, bwBase = biBase + n * 3
        var indices: [SIMD3<UInt8>] = []
        var weights: [SIMD3<Float>] = []
        indices.reserveCapacity(n)
        weights.reserveCapacity(n)
        for i in 0..<n {
            let p = SIMD3<Float>(Float(i16(posBase + i * 6)), Float(i16(posBase + i * 6 + 2)), Float(i16(posBase + i * 6 + 4))) / 8000
            let nn = SIMD3<Float>(Float(Int8(bitPattern: bytes[nrmBase + i * 3])), Float(Int8(bitPattern: bytes[nrmBase + i * 3 + 1])),
                                  Float(Int8(bitPattern: bytes[nrmBase + i * 3 + 2]))) / 127
            let uv = SIMD2<Float>(Float(i16(uvBase + i * 4)), Float(i16(uvBase + i * 4 + 2))) / 16000
            mesh.addVertex(p, nn.unit, uv)
            indices.append(SIMD3(bytes[biBase + i * 3], bytes[biBase + i * 3 + 1], bytes[biBase + i * 3 + 2]))
            var w = SIMD3<Float>(Float(bytes[bwBase + i * 3]), Float(bytes[bwBase + i * 3 + 1]), Float(bytes[bwBase + i * 3 + 2]))
            w /= max(1, w.x + w.y + w.z)
            weights.append(w)
        }
        o = bwBase + n * 3
        for material in materialOrder {
            let count = u32()
            var idx = [UInt32](repeating: 0, count: count)
            for k in 0..<count { idx[k] = UInt32(bytes[o + k * 2]) | UInt32(bytes[o + k * 2 + 1]) << 8 }
            o += count * 2
            mesh.addIndices(idx, material: material)
        }
        // Rest frames, constructed as the pose solver constructs live bones.
        let j = joint
        let hipC = j("hipCentre"), neck = j("neck")
        let torso = RigidTransform.bone(from: hipC, to: neck)
        func limb(_ a: String, _ b: String) -> RigidTransform { .bone(from: j(a), to: j(b)) }
        var frames: [RiderBone: RigidTransform] = [
            .torso: torso,
            .head: RigidTransform(origin: neck),
            .upperArmL: limb("shoulderL", "elbowL"), .upperArmR: limb("shoulderR", "elbowR"),
            .forearmL: limb("elbowL", "wristL"), .forearmR: limb("elbowR", "wristR"),
            .thighL: limb("hipL", "kneeL"), .thighR: limb("hipR", "kneeR"),
            .shinL: limb("kneeL", "ankleL"), .shinR: limb("kneeR", "ankleR"),
        ]
        for (hand, elbow, wrist) in [(RiderBone.handL, "elbowL", "wristL"), (.handR, "elbowR", "wristR")] {
            frames[hand] = .bone(from: j(wrist), to: j(wrist) * 2 - j(elbow))
        }
        for (foot, ankle) in [(RiderBone.footL, "ankleL"), (.footR, "ankleR")] {
            frames[foot] = .bone(from: j(ankle), to: j(ankle) + SIMD3(0, 0, -1))
        }
        // Proportions for the pose solver.
        var d = RiderDimensions(build: .regular)
        let inv = torso.inverse
        d.torso = (neck - hipC).norm
        d.neckOffset = inv.apply(neck)
        d.shoulderOffset = inv.apply(j("shoulderR"))
        d.hipOffset = inv.apply(j("hipR"))
        d.shoulderHalf = d.shoulderOffset.x
        d.hipHalf = d.hipOffset.x
        d.upperArm = (j("elbowR") - j("shoulderR")).norm
        d.forearm = (j("wristR") - j("elbowR")).norm
        d.thigh = (j("kneeR") - j("hipR")).norm
        d.shin = (j("ankleR") - j("kneeR")).norm
        d.girth = 1
        return RiderBody(mesh: mesh, boneIndices: indices, boneWeights: weights,
                         restFrames: RiderBone.allCases.map { frames[$0]! }, dimensions: d,
                         skullCentre: skullCentre, skullRadii: skullRadii)
    }

    /// The same body, slimmer or stockier: flesh is scaled across each limb (not along it).
    public func withBuild(_ build: AvatarBuild) -> RiderBody {
        let g: Float
        switch build {
        case .slim: g = 0.92
        case .regular: return self
        case .sprinter: g = 1.1
        }
        var m = mesh
        let headIndex = RiderBone.allCases.firstIndex(of: .head)!
        for i in 0..<m.vertexCount {
            let w = boneWeights[i], b = boneIndices[i]
            var acc = SIMD3<Float>.zero
            for k in 0..<3 where w[k] > 0 {
                let f = restFrames[Int(b[k])]
                var q = f.inverse.apply(m.positions[i])
                if Int(b[k]) != headIndex {
                    q.x *= g
                    q.z *= g
                }
                acc += f.apply(q) * w[k]
            }
            m.positions[i] = acc
        }
        return RiderBody(mesh: m, boneIndices: boneIndices, boneWeights: boneWeights, restFrames: restFrames,
                         dimensions: dimensions, skullCentre: skullCentre, skullRadii: skullRadii)
    }

    /// CPU linear-blend skinning (tests, previews and exports; the app skins on the GPU).
    public func posed(_ pose: RiderPose) -> ModelMesh {
        let skin = RiderBone.allCases.enumerated().map { k, bone -> RigidTransform in
            (pose.bones[bone] ?? restFrames[k]).then(restFrames[k].inverse)
        }
        var m = mesh
        for i in 0..<m.vertexCount {
            let w = boneWeights[i], b = boneIndices[i]
            var p = SIMD3<Float>.zero, n = SIMD3<Float>.zero
            for k in 0..<3 where w[k] > 0 {
                let t = skin[Int(b[k])]
                p += t.apply(mesh.positions[i]) * w[k]
                n += t.rotate(mesh.normals[i]) * w[k]
            }
            m.positions[i] = p
            m.normals[i] = n.unit
        }
        return m
    }
}
