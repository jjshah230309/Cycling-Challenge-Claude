import Foundation

/// Rigid body segments of the rider. Each mesh is modelled in its bone space:
/// the bone runs along +Y from the parent joint; +X is the rider's right.
public enum RiderBone: String, CaseIterable, Sendable {
    case torso, head
    case upperArmL, upperArmR, forearmL, forearmR, handL, handR
    case thighL, thighR, shinL, shinR, footL, footR
}

/// Body proportions (metres) for a ~1.78 m rider, varied by build.
public struct RiderDimensions: Sendable {
    public var torso: Float = 0.53          // hip-joint centre → base of the neck
    public var shoulderHalf: Float = 0.185
    public var hipHalf: Float = 0.088
    public var upperArm: Float = 0.30
    public var forearm: Float = 0.265
    public var thigh: Float = 0.435
    public var shin: Float = 0.435
    /// Ankle → cleat (ball of the foot), in foot space.
    public var cleat = SIMD3<Float>(0, 0.115, -0.087)
    public var girth: Float = 1

    public init(build: AvatarBuild) {
        switch build {
        case .slim: girth = 0.9
        case .regular: girth = 1
        case .sprinter: girth = 1.13
        }
        shoulderHalf *= mixf(1, girth, 0.6)
    }
}

/// A procedurally modelled cyclist (no kit colours — materials are named, the app colours them).
public struct RiderModel: Sendable {
    public var segments: [RiderBone: ModelMesh] = [:]
    public let dimensions: RiderDimensions

    public enum Material {
        public static let jersey = "jersey", shorts = "shorts", skin = "skin", helmet = "helmet", lens = "lens"
        public static let sleeve = "sleeve", lips = "lips"
        public static let black = "riderBlack", shoe = "shoe", sole = "sole", sock = "sock", glove = "glove", hair = "hair"
    }

    // swiftlint:disable:next function_body_length
    public init(build: AvatarBuild, timeTrialHelmet: Bool = false, detail: Float = 1) {
        let d = RiderDimensions(build: build)
        dimensions = d
        let hi = detail >= 0.75
        let around = hi ? 28 : 8
        let G = d.girth
        let M = Material.self

        // --- Torso: pelvis and shorts below, jersey above, rounded back ---
        var torso = ModelMesh()
        let torsoKeys: [(t: Float, w: Float, dep: Float, z: Float)] = [
            (-0.15, 0.10, 0.08, 0.02), (-0.12, 0.27, 0.19, 0.025), (-0.04, 0.335, 0.235, 0.02), (0.08, 0.33, 0.22, 0.012),
            (0.22, 0.30, 0.195, 0.01), (0.42, 0.325, 0.215, 0.018), (0.62, 0.355, 0.23, 0.022), (0.80, 0.37, 0.205, 0.02),
            (0.90, 0.345, 0.175, 0.016), (0.97, 0.25, 0.135, 0.014), (1.02, 0.11, 0.09, 0.016),
        ]
        let torsoRows = hi ? 40 : 10
        var torsoPath: [V3] = []
        var torsoShape: [(w: Float, dep: Float, z: Float)] = []
        for k in 0...torsoRows {
            let t = mixf(torsoKeys.first!.t, torsoKeys.last!.t, Float(k) / Float(torsoRows))
            var i = 0
            while i < torsoKeys.count - 2 && torsoKeys[i + 1].t < t { i += 1 }
            let a = torsoKeys[i], b = torsoKeys[i + 1]
            let u = smooth01((t - a.t) / (b.t - a.t))
            // The spine itself curves: a rounded upper back.
            let arch = 0.014 * sin(max(0, min(1, t)) * .pi) * G
            torsoPath.append(V3(0, t * d.torso, arch))
            torsoShape.append((mixf(a.w, b.w, u) * G, mixf(a.dep, b.dep, u) * G, mixf(a.z, b.z, u)))
        }
        torso.loft(path: torsoPath, up: V3(0, 0, 1), section: { i, _ in
            let s = torsoShape[i]
            // Flatter back, fuller chest: superellipse with the centre nudged towards the back.
            return Section.superellipse(s.w, s.dep, exponent: 2.3, count: around + 4).map { SIMD2($0.x, $0.y + s.z - 0.02) }
        }, material: { i in Float(i) / Float(torsoRows) < 0.2 ? M.shorts : M.jersey }, uvScale: 1 / (d.torso * 1.2))
        segments[.torso] = torso

        // --- Head, neck, helmet, glasses ---
        var head = ModelMesh()
        head.tube(path: [V3(0, -0.05, 0.025), V3(0, 0.0, 0.01), V3(0, 0.05, -0.005)], up: V3(0, 0, 1),
                  radius: { t in mixf(0.058, 0.047, t) * mixf(1, G, 0.5) }, sides: around, material: M.skin, caps: false)
        let skull = V3(0, 0.112, -0.02)
        head.ellipsoid(center: skull, radii: V3(0.077, 0.1, 0.094), rings: hi ? 12 : 6, segments: around, material: M.skin)
        // Jaw/chin and nose.
        head.ellipsoid(center: skull + V3(0, -0.06, -0.045), radii: V3(0.058, 0.045, 0.05), rings: hi ? 8 : 4, segments: around,
                       material: M.skin)
        head.loft(path: [skull + V3(0, 0.0, -0.088), skull + V3(0, -0.03, -0.106)], up: V3(0, 0, -1), section: { _, t in
            Section.ellipse(mixf(0.016, 0.026, t), mixf(0.012, 0.02, t), count: 8)
        }, material: { _ in M.skin }, capStart: false, capEnd: true)
        for s: Float in [-1, 1] {
            head.ellipsoid(center: skull + V3(s * 0.077, -0.005, 0.01), radii: V3(0.012, 0.03, 0.02), rings: 4, segments: 8, material: M.skin)
            // Cheekbones.
            head.ellipsoid(center: skull + V3(s * 0.045, -0.025, -0.07), radii: V3(0.026, 0.022, 0.022), rings: 4, segments: 8, material: M.skin)
        }
        // Brow ridge and lips.
        head.ellipsoid(center: skull + V3(0, 0.022, -0.082), radii: V3(0.06, 0.016, 0.02), rings: 4, segments: 10, material: M.skin)
        head.ellipsoid(center: skull + V3(0, -0.072, -0.085), radii: V3(0.022, 0.008, 0.01), rings: 3, segments: 8, material: M.lips)
        // Hair below the helmet at the back.
        head.ellipsoid(center: skull + V3(0, -0.01, 0.03), radii: V3(0.079, 0.085, 0.08), rings: hi ? 8 : 4, segments: around, material: M.hair)
        // Helmet shell: an open dome, elongated, with a tail (long and pointed for TT).
        let helmetRings = hi ? 18 : 6
        let helmetCols = hi ? 44 : 12
        let hc = skull + V3(0, 0.022, 0.008)
        head.addGrid(rows: helmetRings + 1, cols: helmetCols, wrap: true, material: { _ in M.helmet }, point: { i, j in
            // Latitude from the brim (−0.32 rad) to the crown; the brim drops at the back.
            let lat = mixf(-0.32, Float.pi / 2, Float(i) / Float(helmetRings))
            let lon = Float(j) / Float(helmetCols) * 2 * .pi
            let cl = cos(lat), sl = sin(lat)
            var p = V3(cl * cos(lon), sl, -cl * sin(lon))
            let back = max(0, p.z)              // +Z = back of the head
            p.x *= 0.103
            p.y = p.y * 0.112 - back * 0.03
            p.z *= p.z > 0 ? (timeTrialHelmet ? 0.17 + 0.2 * (1 - sl) : 0.148) : 0.135
            if timeTrialHelmet && back > 0 {
                p.y -= back * back * 0.06
                p.x *= 1 - back * back * 0.55
            }
            return hc + p
        }, uv: { i, j in V2(Float(j) / Float(helmetCols), Float(i) / Float(helmetRings)) })
        // Underside of the shell (black liner) so the dome never looks paper-thin.
        head.addGrid(rows: 2, cols: helmetCols, wrap: true, material: { _ in M.black }, point: { i, j in
            let lon = -Float(j) / Float(helmetCols) * 2 * .pi
            let lat: Float = -0.32
            var p = V3(cos(lat) * cos(lon), sin(lat), -cos(lat) * sin(lon))
            let back = max(0, p.z)
            let shrink: Float = i == 0 ? 1 : 0.86
            p.x *= 0.103 * shrink
            p.y = p.y * 0.112 - back * 0.03 + (i == 0 ? 0 : 0.012)
            p.z *= (p.z > 0 ? (timeTrialHelmet ? 0.17 + 0.2 * (1 - sin(lat)) : 0.148) : 0.135) * shrink
            return hc + p
        }, uv: { _, _ in .zero })
        if timeTrialHelmet {
            // Wrap-around visor.
            let visor = (0...(hi ? 12 : 6)).map { k -> V3 in
                let a = mixf(-1.15, 1.15, Float(k) / Float(hi ? 12 : 6))
                return skull + V3(sin(a) * 0.095, 0.022, -cos(a) * 0.108)
            }
            head.loft(path: visor, up: V3(0, 1, 0), section: { _, _ in Section.superellipse(0.004, 0.06, exponent: 4, count: 8) },
                      material: { _ in M.lens }, capStart: true, capEnd: true)
        } else {
            // Wraparound sunglasses with arms back to the ears.
            let lens = (0...(hi ? 14 : 6)).map { k -> V3 in
                let a = mixf(-1.2, 1.2, Float(k) / Float(hi ? 14 : 6))
                return skull + V3(sin(a) * 0.086, 0.012 - 0.008 * abs(a), -cos(a) * 0.097)
            }
            head.loft(path: lens, up: V3(0, 1, 0), section: { _, _ in Section.superellipse(0.004, 0.042, exponent: 3, count: 8) },
                      material: { _ in M.lens }, capStart: true, capEnd: true)
            for s: Float in [-1, 1] {
                head.tube(path: [skull + V3(s * 0.083, 0.02, -0.03), skull + V3(s * 0.082, 0.012, 0.03)], radius: { _ in 0.003 },
                          sides: 4, material: M.black)
                // Chin straps.
                head.tube(path: [hc + V3(s * 0.098, -0.03, -0.04), skull + V3(s * 0.05, -0.1, -0.03)], radius: { _ in 0.0025 },
                          sides: 4, material: M.black)
                head.tube(path: [hc + V3(s * 0.096, -0.035, 0.04), skull + V3(s * 0.05, -0.1, -0.03)], radius: { _ in 0.0025 },
                          sides: 4, material: M.black)
            }
        }
        segments[.head] = head

        // --- Limbs ---
        func limb(length: Float, start: Float = 0, end: Float? = nil, radius: @escaping (Float) -> SIMD2<Float>,
                  bulge: @escaping (Float) -> Float = { _ in 0 }, material: @escaping (Float) -> String) -> ModelMesh {
            var m = ModelMesh()
            let rows = hi ? 22 : 6
            let y0 = start, y1 = end ?? length
            let path = (0...rows).map { k -> V3 in V3(0, mixf(y0, y1, Float(k) / Float(rows)), 0) }
            m.loft(path: path, up: V3(0, 0, 1), section: { _, t in
                let r = radius(t)
                // Rounded ends so neighbouring segments blend at the joints.
                let endTaper = min(1, min(t, 1 - t) * 9 + 0.35)
                return Section.ellipse(2 * r.x * endTaper, 2 * r.y * endTaper, count: around, center: SIMD2(0, bulge(t) * endTaper))
            }, material: { k in material(Float(k) / Float(rows)) }, capStart: true, capEnd: true)
            return m
        }
        let ua = limb(length: d.upperArm, start: -0.05, end: d.upperArm + 0.025, radius: { t in
            SIMD2(mixf(0.06, 0.037, t), mixf(0.056, 0.04, t)) * mixf(1, G, 0.8)
        }, material: { $0 < 0.5 ? M.sleeve : M.skin })
        var fa = limb(length: d.forearm, start: -0.025, end: d.forearm + 0.01, radius: { t in
            SIMD2(mixf(0.041, 0.026, t), mixf(0.037, 0.022, t)) * mixf(1, G, 0.6)
        }, material: { $0 > 0.9 ? M.glove : M.skin })
        fa.ellipsoid(center: V3(0, 0.0, -0.004), radii: V3(0.038, 0.04, 0.036) * mixf(1, G, 0.6), rings: hi ? 6 : 3, segments: hi ? 10 : 6,
                     material: M.skin)   // elbow
        // Hands wrapped round the hoods: padded palm, four fingers curling under the grip,
        // thumb on the inside; fingerless gloves leave the fingertips bare.
        func hand(_ side: Float) -> ModelMesh {
            var h = ModelMesh()
            h.ellipsoid(center: V3(0, 0.045, 0.004), radii: V3(0.042, 0.055, 0.018), rings: hi ? 8 : 4, segments: hi ? 14 : 6, material: M.glove)
            guard hi else { return h }
            for f in 0..<4 {
                let x = (Float(f) - 1.5) * 0.019 * side
                let len: Float = f == 0 || f == 3 ? 0.85 : 1
                let path = catmullRom([V3(x, 0.088, 0.004), V3(x * 1.05, 0.118 * len + 0.01, -0.008), V3(x * 1.05, 0.122 * len, -0.04),
                                       V3(x, 0.1 * len, -0.058)], samplesPerSegment: 3)
                h.loft(path: path, up: V3(0, 0, 1), section: { _, t in Section.circle(mixf(0.0095, 0.0075, t), count: 8) },
                       material: { Float($0) / Float(path.count - 1) > 0.55 ? M.skin : M.glove }, capStart: true, capEnd: true)
            }
            let thumb = catmullRom([V3(-side * 0.032, 0.02, -0.004), V3(-side * 0.048, 0.06, -0.018), V3(-side * 0.036, 0.09, -0.04)],
                                   samplesPerSegment: 3)
            h.loft(path: thumb, up: V3(0, 0, 1), section: { _, t in Section.circle(mixf(0.012, 0.009, t), count: 8) },
                   material: { Float($0) / Float(thumb.count - 1) > 0.6 ? M.skin : M.glove }, capStart: true, capEnd: true)
            return h
        }
        let th = limb(length: d.thigh, start: -0.07, end: d.thigh + 0.02, radius: { t in
            SIMD2(mixf(0.088, 0.054, t), mixf(0.084, 0.05, t)) * G
        }, bulge: { t in 0.012 * sin(t * .pi) * G }, material: { $0 < 0.78 ? M.shorts : M.skin })
        var sh = limb(length: d.shin, start: -0.03, end: d.shin + 0.02, radius: { t in
            let calf = exp(-pow((t - 0.3) / 0.22, 2))
            return SIMD2(mixf(0.046, 0.03, t) + 0.012 * calf, mixf(0.046, 0.03, t) + 0.016 * calf) * mixf(1, G, 0.7)
        }, bulge: { t in -0.012 * exp(-pow((t - 0.3) / 0.22, 2)) }, material: { $0 > 0.8 ? M.sock : M.skin })
        sh.ellipsoid(center: V3(0, 0.005, 0.01), radii: V3(0.046, 0.046, 0.045) * mixf(1, G, 0.6), rings: hi ? 8 : 4, segments: hi ? 12 : 6,
                     material: M.skin)   // knee
        // Shoe: heel → toe in foot space (+Y forward, +Z up, sole at z = −0.075).
        var shoe = ModelMesh()
        let shoeRows = hi ? 14 : 6
        let shoeKeys: [(y: Float, w: Float, h: Float)] = [(-0.075, 0.03, 0.06), (-0.06, 0.07, 0.1), (0.0, 0.08, 0.1), (0.08, 0.098, 0.075),
                                                          (0.15, 0.09, 0.055), (0.19, 0.06, 0.04), (0.205, 0.02, 0.022)]
        let shoePath = (0...shoeRows).map { k -> V3 in
            let y = mixf(shoeKeys.first!.y, shoeKeys.last!.y, Float(k) / Float(shoeRows))
            return V3(0, y, 0)
        }
        func shoeShape(_ y: Float) -> (w: Float, h: Float) {
            var i = 0
            while i < shoeKeys.count - 2 && shoeKeys[i + 1].y < y { i += 1 }
            let a = shoeKeys[i], b = shoeKeys[i + 1]
            let u = smooth01((y - a.y) / (b.y - a.y))
            return (mixf(a.w, b.w, u), mixf(a.h, b.h, u))
        }
        shoe.loft(path: shoePath, up: V3(0, 0, 1), section: { i, _ in
            let s = shoeShape(shoePath[i].y)
            return Section.superellipse(s.w, s.h, exponent: 2.6, count: around).map { SIMD2($0.x, $0.y - 0.075 + s.h / 2) }
        }, material: { _ in M.shoe }, capStart: true, capEnd: true)
        shoe.loft(path: shoePath, up: V3(0, 0, 1), section: { i, _ in
            let s = shoeShape(shoePath[i].y)
            return Section.superellipse(s.w * 1.04, 0.012, exponent: 4, count: around).map { SIMD2($0.x, $0.y - 0.073) }
        }, material: { _ in M.sole }, capStart: true, capEnd: true)
        shoe.box(center: V3(0, 0.115, -0.081), size: V3(0.07, 0.009, 0.075), material: M.black)    // cleat
        shoe.ellipsoid(center: V3(0, 0, 0.005), radii: V3(0.036, 0.04, 0.036), rings: 4, segments: 8, material: M.sock)

        segments[.upperArmL] = ua
        segments[.upperArmR] = ua
        segments[.forearmL] = fa
        segments[.forearmR] = fa
        segments[.handL] = hand(-1)
        segments[.handR] = hand(1)
        segments[.thighL] = th
        segments[.thighR] = th
        segments[.shinL] = sh
        segments[.shinR] = sh
        segments[.footL] = shoe
        segments[.footR] = shoe
    }
}

/// Where the rider's hips, hands and head go for a riding position (bike space).
public struct PoseParameters: Sendable, Equatable {
    /// Hip-joint centre.
    public var hip: SIMD3<Float>
    /// Right-hand grip point (mirrored for the left hand).
    public var grip: SIMD3<Float>
    /// Shoulder→grip distance as a fraction of the full arm length (how bent the elbows are).
    public var reach: Float
    /// Head tilt (radians, + = chin down).
    public var headPitch: Float
    /// Time-trial elbow pad (right), when on the extensions.
    public var elbowPad: SIMD3<Float>?
    /// How far the elbows splay outwards (0 = tucked in).
    public var elbowOut: Float

    public static func target(_ posture: RiderPosture, anchors a: BikeAnchors) -> PoseParameters {
        let sit = a.saddleTop + V3(0, 0.075, 0.005)
        switch posture {
        case .hoods:
            return PoseParameters(hip: sit, grip: a.hoods, reach: 0.9, headPitch: 0.15, elbowPad: nil, elbowOut: 0.35)
        case .drops:
            return PoseParameters(hip: sit + V3(0, 0, -0.015), grip: a.drops, reach: 0.86, headPitch: -0.12, elbowPad: nil, elbowOut: 0.3)
        case .tuck:
            return PoseParameters(hip: sit + V3(0, -0.005, -0.075), grip: a.tops + V3(-0.03, 0, 0), reach: 0.62, headPitch: -0.45,
                                  elbowPad: nil, elbowOut: 0.15)
        case .standing:
            return PoseParameters(hip: sit + V3(0, 0.12, -0.25), grip: a.hoods, reach: 0.84, headPitch: 0.2, elbowPad: nil, elbowOut: 0.55)
        case .aero:
            if let grip = a.extensionGrip, let pad = a.elbowPad {
                return PoseParameters(hip: sit + V3(0, 0, -0.03), grip: grip, reach: 0.0, headPitch: -0.35, elbowPad: pad, elbowOut: 0)
            }
            return target(.drops, anchors: a)
        }
    }

    public func blended(to b: PoseParameters, _ t: Float) -> PoseParameters {
        var r = self
        r.hip = mix3(hip, b.hip, t)
        r.grip = mix3(grip, b.grip, t)
        r.reach = mixf(reach, b.reach, t)
        r.headPitch = mixf(headPitch, b.headPitch, t)
        r.elbowOut = mixf(elbowOut, b.elbowOut, t)
        switch (elbowPad, b.elbowPad) {
        case let (p?, q?): r.elbowPad = mix3(p, q, t)
        case let (nil, q?): r.elbowPad = t > 0.5 ? q : nil
        case (_?, nil): r.elbowPad = t > 0.5 ? nil : elbowPad
        default: r.elbowPad = nil
        }
        return r
    }
}

/// Solved bone transforms (bike space) for one frame of animation.
public struct RiderPose: Sendable {
    public var bones: [RiderBone: RigidTransform] = [:]
    public var pedalLeft = RigidTransform.identity
    public var pedalRight = RigidTransform.identity
    public var kneeAngles: (left: Float, right: Float) = (0, 0)

    /// Bike roll (radians about the bike's +Z axis) while out of the saddle: the bike swings
    /// away from the leg pushing down.
    public static func standingRock(crankAngle: Double) -> Float { Float(0.12 * sin(crankAngle)) }

    /// Ankling: toes drop through the bottom of the stroke, heel drops over the top.
    public static func footPitch(crankAngle a: Float) -> Float { -0.17 + 0.22 * cos(a - 0.35) }

    // swiftlint:disable:next function_body_length
    public static func solve(params p: PoseParameters, anchors a: BikeAnchors, dimensions d: RiderDimensions,
                             crankAngle: Double, roll: Float = 0, steer: Float = 0) -> RiderPose {
        var pose = RiderPose()
        let X = V3(1, 0, 0)
        // Out of the saddle the bike rocks under a body that stays upright: shift the body the other way.
        var hip = p.hip
        hip.x += sin(roll) * (hip.y - 0.0) * 0.9

        // Torso angle: lean forward until the shoulders sit at the right distance from the bars.
        let steering = RigidTransform.rotation(axis: a.steeringAxis, angle: steer, origin: a.steeringPivot)
        func steered(_ v: V3) -> V3 { steering.apply(v - a.steeringPivot) }
        let gripR = steered(p.grip), gripL = steered(V3(-p.grip.x, p.grip.y, p.grip.z))
        let padR = p.elbowPad.map { steered($0) }, padL = p.elbowPad.map { steered(V3(-$0.x, $0.y, $0.z)) }
        let armLength = d.upperArm + d.forearm + 0.06
        func torsoFrame(_ theta: Float) -> RigidTransform {
            var top = hip + V3(0, sin(theta), -cos(theta)) * d.torso
            top.x += sin(roll) * 0.35 * 0.9
            return .bone(from: hip, to: top, side: X)
        }
        func shoulder(_ t: RigidTransform, _ side: Float) -> V3 { t.apply(V3(side * d.shoulderHalf, d.torso * 0.885, -0.004)) }
        let (targetPoint, targetDist): (V3, Float) = {
            if let pad = padR { return (pad + V3(0, 0.03, 0), d.upperArm * 0.98) }
            return (gripR, armLength * p.reach)
        }()
        var lo: Float = 0.02, hi: Float = 1.45
        for _ in 0..<28 {
            let mid = (lo + hi) / 2
            let dist = (shoulder(torsoFrame(mid), 1) - targetPoint).norm
            // More upright → shoulders further back and up → further from the bars.
            if dist > targetDist { hi = mid } else { lo = mid }
        }
        let torso = torsoFrame((lo + hi) / 2)
        pose.bones[.torso] = torso

        // Head: on top of the neck, tilted to keep the eyes on the road.
        let neck = torso.apply(V3(0, d.torso - 0.005, 0.012))
        let headUp = V3(0, cos(p.headPitch), -sin(p.headPitch))
        let headBase = neck
        pose.bones[.head] = RigidTransform(origin: headBase, x: X, y: headUp, z: X.crossp(headUp))

        // Arms (two-bone IK; elbows bend outwards and down).
        for (side, grip, pad) in [(Float(1), gripR, padR), (Float(-1), gripL, padL)] {
            let s = shoulder(torso, side)
            let handDir = ((grip - s).unit + V3(0, -0.15, -0.9)).unit
            let wrist = grip - handDir * 0.055
            let elbow: V3
            if let pad {
                elbow = pad + V3(0, 0.03, 0)
            } else {
                elbow = RiderPose.twoBone(root: s, target: wrist, l1: d.upperArm, l2: d.forearm,
                                          pole: V3(side * p.elbowOut, -0.8, 0.35))
            }
            let ua: RiderBone = side > 0 ? .upperArmR : .upperArmL
            let fa: RiderBone = side > 0 ? .forearmR : .forearmL
            let hd: RiderBone = side > 0 ? .handR : .handL
            pose.bones[ua] = .bone(from: s, to: elbow, side: X)
            pose.bones[fa] = .bone(from: elbow, to: wrist, side: X)
            pose.bones[hd] = .bone(from: wrist, to: wrist + handDir, side: X)
        }

        // Legs: feet clipped into the pedals, ankling through the stroke.
        let theta = Float(crankAngle)
        for side in [Float(1), Float(-1)] {
            let ang = theta + (side > 0 ? 0 : .pi)
            let spindle = a.bottomBracket + V3(side * 0.078, a.crankLength * cos(ang), -a.crankLength * sin(ang))
            let phi = footPitch(crankAngle: ang)
            let fwd = V3(0, sin(phi), -cos(phi))
            let foot0 = RigidTransform.bone(from: .zero, to: fwd, side: X)
            // Cleat sits on the pedal's top face (half the body thickness above the spindle).
            let contact = spindle + foot0.z * 0.009 + V3(side * (a.pedalStance - 0.078), 0, 0)
            let ankle = contact - foot0.rotate(d.cleat)
            let hipJoint = torso.apply(V3(side * d.hipHalf, 0, 0))
            let knee = RiderPose.twoBone(root: hipJoint, target: ankle, l1: d.thigh, l2: d.shin, pole: V3(side * 0.12, 0.25, -1))
            let thigh: RiderBone = side > 0 ? .thighR : .thighL
            let shin: RiderBone = side > 0 ? .shinR : .shinL
            let footBone: RiderBone = side > 0 ? .footR : .footL
            pose.bones[thigh] = .bone(from: hipJoint, to: knee, side: X)
            pose.bones[shin] = .bone(from: knee, to: ankle, side: X)
            pose.bones[footBone] = RigidTransform(origin: ankle, x: foot0.x, y: foot0.y, z: foot0.z)
            let pedal = RigidTransform(origin: spindle, x: X, y: foot0.z, z: X.crossp(foot0.z))
            if side > 0 { pose.pedalRight = pedal } else { pose.pedalLeft = pedal }
            let u = (hipJoint - knee).unit, v = (ankle - knee).unit
            let angle = acos(max(-1, min(1, u.dotp(v))))
            if side > 0 { pose.kneeAngles.right = angle } else { pose.kneeAngles.left = angle }
        }
        return pose
    }

    /// Analytic two-bone IK: the middle joint for a chain root→target with segment lengths
    /// l1, l2, bending towards `pole`.
    static func twoBone(root: V3, target: V3, l1: Float, l2: Float, pole: V3) -> V3 {
        var v = target - root
        var dist = v.norm
        dist = min(max(dist, abs(l1 - l2) + 0.01), l1 + l2 - 0.002)
        v = v.unit
        let along = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
        let h = (max(0, l1 * l1 - along * along)).squareRoot()
        var perp = pole - v * pole.dotp(v)
        if perp.norm < 1e-5 { perp = V3(0, 1, 0) - v * v.y }
        return root + v * along + perp.unit * h
    }
}
