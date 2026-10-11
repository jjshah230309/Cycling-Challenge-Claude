import Foundation

/// Key points of a generated bike, in bike space (metres; −Z forward, +Y up, +X right;
/// origin on the ground midway between the axles).
public struct BikeAnchors: Sendable {
    public var frontAxle: SIMD3<Float>
    public var rearAxle: SIMD3<Float>
    public var bottomBracket: SIMD3<Float>
    /// Where the rider sits (centre of the saddle's top surface).
    public var saddleTop: SIMD3<Float>
    public var saddleNose: SIMD3<Float>
    /// Right-hand grip points (mirror x for the left hand).
    public var hoods: SIMD3<Float>
    public var drops: SIMD3<Float>
    public var tops: SIMD3<Float>
    /// Time-trial extensions: hand grip and elbow pad (right side).
    public var extensionGrip: SIMD3<Float>?
    public var elbowPad: SIMD3<Float>?
    /// Steering axis: a point on it (top of the head tube) and its unit direction (pointing up).
    public var steeringPivot: SIMD3<Float>
    public var steeringAxis: SIMD3<Float>
    public var crankLength: Float
    public var wheelRadius: Float
    /// Lateral distance of each pedal's centre from the bike's centre plane.
    public var pedalStance: Float
}

/// A procedurally generated bike split into its moving parts.
public struct BikeModel: Sendable {
    /// Frame, rear brake, drivetrain hardware, saddle, seatpost, bottles, chain (rigid with the frame).
    public var frame = ModelMesh()
    /// Fork, stem, bars, levers and front brake — turns about the steering axis.
    public var steering = ModelMesh()
    /// Wheels in wheel space: axle along X through the origin.
    public var frontWheel = ModelMesh()
    public var rearWheel = ModelMesh()
    /// Chainrings, spider and crank arms in crank space: BB at origin, rotating about X;
    /// the right arm points +Y at crank angle 0.
    public var crankset = ModelMesh()
    /// One pedal in pedal space: spindle along +X from the origin (mirror for the left).
    public var pedalRight = ModelMesh()
    public var pedalLeft = ModelMesh()
    public var anchors: BikeAnchors

    /// Material names used (the app maps them to colours and textures).
    public enum Material {
        public static let paint = "paint", accent = "accent", decal = "decal", carbon = "carbon", black = "black"
        public static let metal = "metal", alloy = "alloy", tyre = "tyre", tyreWall = "tyreWall", rim = "rim"
        public static let rimDecal = "rimDecal", chain = "chain", rotor = "rotor", barTape = "barTape"
        public static let saddle = "saddle", bottle = "bottle", rubber = "rubber"
    }

    struct Geometry {
        var wheelbase: Float, chainstay: Float, bbDrop: Float, stack: Float, reach: Float
        var seatAngle: Float, headAngle: Float, headTube: Float, seatTube: Float, saddleHeight: Float
        var stemLength: Float, stemRise: Float, spacers: Float, barHalfWidth: Float
    }

    static func geometry(_ style: FrameStyle) -> Geometry {
        func deg(_ d: Float) -> Float { d * .pi / 180 }
        switch style {
        case .endurance:
            return Geometry(wheelbase: 1.0, chainstay: 0.415, bbDrop: 0.075, stack: 0.59, reach: 0.38, seatAngle: deg(73),
                            headAngle: deg(72), headTube: 0.18, seatTube: 0.53, saddleHeight: 0.73, stemLength: 0.10,
                            stemRise: deg(6), spacers: 0.03, barHalfWidth: 0.21)
        case .climbing:
            return Geometry(wheelbase: 0.985, chainstay: 0.405, bbDrop: 0.07, stack: 0.565, reach: 0.392, seatAngle: deg(73.5),
                            headAngle: deg(73.2), headTube: 0.155, seatTube: 0.52, saddleHeight: 0.735, stemLength: 0.11,
                            stemRise: 0, spacers: 0.015, barHalfWidth: 0.2)
        case .aero:
            return Geometry(wheelbase: 0.985, chainstay: 0.405, bbDrop: 0.07, stack: 0.56, reach: 0.395, seatAngle: deg(73.5),
                            headAngle: deg(73.2), headTube: 0.15, seatTube: 0.51, saddleHeight: 0.735, stemLength: 0.11,
                            stemRise: 0, spacers: 0.01, barHalfWidth: 0.195)
        case .timeTrial:
            return Geometry(wheelbase: 0.99, chainstay: 0.405, bbDrop: 0.07, stack: 0.5, reach: 0.43, seatAngle: deg(77.5),
                            headAngle: deg(73), headTube: 0.11, seatTube: 0.5, saddleHeight: 0.725, stemLength: 0.09,
                            stemRise: 0, spacers: 0.0, barHalfWidth: 0.2)
        case .gravel:
            return Geometry(wheelbase: 1.03, chainstay: 0.425, bbDrop: 0.07, stack: 0.6, reach: 0.375, seatAngle: deg(73),
                            headAngle: deg(71.5), headTube: 0.17, seatTube: 0.53, saddleHeight: 0.73, stemLength: 0.09,
                            stemRise: deg(6), spacers: 0.03, barHalfWidth: 0.22)
        case .steel:
            return Geometry(wheelbase: 0.99, chainstay: 0.41, bbDrop: 0.07, stack: 0.575, reach: 0.38, seatAngle: deg(73),
                            headAngle: deg(73), headTube: 0.16, seatTube: 0.56, saddleHeight: 0.73, stemLength: 0.11,
                            stemRise: deg(4), spacers: 0.04, barHalfWidth: 0.2)
        case .track:
            return Geometry(wheelbase: 0.97, chainstay: 0.39, bbDrop: 0.06, stack: 0.54, reach: 0.4, seatAngle: deg(74.5),
                            headAngle: deg(74.5), headTube: 0.13, seatTube: 0.52, saddleHeight: 0.735, stemLength: 0.12,
                            stemRise: 0, spacers: 0.0, barHalfWidth: 0.19)
        }
    }

    // swiftlint:disable:next function_body_length
    public init(setup: BikeSetup, detail: Float = 1) {
        let frame = setup.frame, wheels = setup.wheels
        let style = frame.style
        let g = BikeModel.geometry(style)
        let hi = detail >= 0.75
        let seg = hi ? 1 : 0                      // extra smoothness on the high LOD
        let M = Material.self

        // --- Key points ---
        let tyreH = Float(wheels.tyreWidthMM) / 1000 * 0.92
        let R: Float = 0.311 + tyreH
        let rearAxle = V3(0, R, g.wheelbase / 2)
        let frontAxle = V3(0, R, -g.wheelbase / 2)
        let bb = V3(0, R - g.bbDrop, g.wheelbase / 2 - (g.chainstay * g.chainstay - g.bbDrop * g.bbDrop).squareRoot())
        let headUp = V3(0, sin(g.headAngle), cos(g.headAngle))           // steering axis, pointing up (and back)
        let headTop = bb + V3(0, g.stack, -g.reach)
        let headBottom = headTop - headUp * g.headTube
        let seatDir = V3(0, sin(g.seatAngle), cos(g.seatAngle))
        let seatTop = bb + seatDir * g.seatTube
        let cluster = seatTop - seatDir * (style == .steel ? 0.015 : 0.045)
        let saddleTop = bb + seatDir * g.saddleHeight + V3(0, 0, style == .timeTrial ? -0.02 : 0)
        let crankLength: Float = 0.1725

        // --- Tube cross-sections ---
        let sides = hi ? 18 : 8
        func round(_ r0: Float, _ r1: Float) -> (Int, Float) -> [SIMD2<Float>] {
            let unit = Section.circle(1, count: sides)
            return { _, t in unit.map { $0 * mixf(r0, r1, t) } }
        }
        func aero(_ chord0: Float, _ chord1: Float, thick: Float, trunc: Float = 0.3) -> (Int, Float) -> [SIMD2<Float>] {
            { _, t in Section.kammtail(chord: mixf(chord0, chord1, t), thickness: thick, truncation: trunc, count: sides + 2) }
        }
        func oval(_ w0: Float, _ h0: Float, _ w1: Float, _ h1: Float) -> (Int, Float) -> [SIMD2<Float>] {
            { _, t in Section.superellipse(mixf(w0, w1, t), mixf(h0, h1, t), exponent: 2.4, count: sides + 2) }
        }
        let isAero = style == .aero || style == .timeTrial || style == .track
        let steel = style == .steel
        let tubeScale = Float(frame.tubeScale)
        var body = ModelMesh()
        func tube(_ path: [V3], up: V3, section: @escaping (Int, Float) -> [SIMD2<Float>], material: @escaping (Int, Float) -> String,
                  into m: inout ModelMesh, caps: Bool = true) {
            let pts = path.count == 2 ? (0...(4 + 4 * seg)).map { mix3(path[0], path[1], Float($0) / Float(4 + 4 * seg)) }
                : catmullRom(path, samplesPerSegment: 4 + 4 * seg)
            var arc: [Float] = [0]
            for k in 1..<pts.count { arc.append(arc[k - 1] + (pts[k] - pts[k - 1]).norm) }
            let total = max(arc.last!, 1e-6)
            m.loft(path: pts, up: up, section: section, material: { material($0, arc[$0] / total) }, capStart: caps, capEnd: caps)
        }
        let plain: (String) -> (Int, Float) -> String = { name in { _, _ in name } }

        // Down tube with the brand decal in the middle.
        let downStart = bb + V3(0, 0.015, -0.01), downEnd = headBottom + headUp * 0.03 + V3(0, 0, 0.005)
        let fwdDown = V3(0, -0.5, -1)
        let decalBand: (Int, Float) -> String = { _, t in t > 0.25 && t < 0.72 ? M.decal : M.paint }
        if isAero {
            tube([downStart, downEnd], up: fwdDown, section: aero(0.062 * tubeScale / 1.3, 0.055, thick: 0.034), material: decalBand, into: &body)
        } else if steel {
            tube([downStart, downEnd], up: fwdDown, section: round(0.0145, 0.0145), material: decalBand, into: &body)
        } else {
            tube([downStart, downEnd], up: fwdDown, section: oval(0.05 * tubeScale, 0.054 * tubeScale, 0.042, 0.04), material: decalBand, into: &body)
        }
        // Seat tube (curved around the rear wheel on aero frames).
        let seatPath: [V3] = isAero
            ? [bb + V3(0, 0.01, 0.005), bb + seatDir * 0.2 + V3(0, 0, -0.012), seatTop]
            : [bb + V3(0, 0.01, 0), seatTop]
        if isAero {
            tube(seatPath, up: V3(0, 0, -1), section: aero(0.065, 0.05, thick: 0.03, trunc: 0.5), material: plain(M.paint), into: &body)
        } else {
            tube(seatPath, up: V3(0, 0, -1), section: round(steel ? 0.0143 : 0.019 * tubeScale, steel ? 0.0143 : 0.0165 * tubeScale),
                 material: plain(M.paint), into: &body)
        }
        // Top tube.
        let ttEnd = headTop - headUp * 0.025
        if isAero {
            tube([cluster, ttEnd], up: V3(0, 1, 0), section: oval(0.026, 0.04, 0.03, 0.045), material: plain(M.paint), into: &body)
        } else if steel {
            tube([cluster, ttEnd], up: V3(0, 1, 0), section: round(0.0128, 0.0128), material: plain(M.paint), into: &body)
        } else {
            tube([cluster, ttEnd], up: V3(0, 1, 0), section: oval(0.03 * tubeScale, 0.034 * tubeScale, 0.036 * tubeScale, 0.038 * tubeScale),
                 material: plain(M.paint), into: &body)
        }
        // Head tube (tapered 1⅛ → 1½").
        tube([headBottom - headUp * 0.008, headTop + headUp * 0.006], up: V3(0, 0, -1),
             section: steel ? round(0.019, 0.019) : (isAero ? aero(0.07, 0.06, thick: 0.04, trunc: 0.6) : round(0.026, 0.021)),
             material: plain(M.accent), into: &body)
        // Bottom-bracket shell and seat cluster.
        tube([bb + V3(-0.043, 0, 0), bb + V3(0.043, 0, 0)], up: V3(0, 1, 0), section: round(0.024, 0.024), material: plain(M.paint), into: &body)
        body.ellipsoid(center: cluster, radii: V3(0.02, 0.026, 0.024) * (steel ? 0.75 : 1), rings: 6 + 2 * seg, segments: 10 + 4 * seg, material: M.paint)
        // Stays: chainstays from the BB, seat stays from the cluster (dropped on modern frames).
        let stayTop = steel ? cluster - seatDir * 0.01 : cluster - seatDir * (isAero ? 0.16 : 0.07)
        for side: Float in [-1, 1] {
            let drop = rearAxle + V3(side * 0.066, 0, 0)
            let cs0 = bb + V3(side * 0.035, -0.005, 0.03)
            tube([cs0, mix3(cs0, drop, 0.5) + V3(side * 0.014, 0.004, 0), drop + V3(0, 0.004, -0.006)], up: V3(0, 1, 0),
                 section: steel ? round(0.0095, 0.007) : oval(0.018, 0.03, 0.012, 0.018), material: plain(M.paint), into: &body)
            let ss0 = stayTop + V3(side * 0.018, 0, 0.004)
            tube([ss0, mix3(ss0, drop, 0.5) + V3(side * 0.012, 0, 0), drop + V3(0, 0.01, -0.002)], up: V3(0, 0, -1),
                 section: steel ? round(0.0085, 0.0065) : (isAero ? aero(0.026, 0.018, thick: 0.012) : oval(0.014, 0.018, 0.011, 0.013)),
                 material: plain(M.paint), into: &body)
            // Dropout.
            body.box(center: drop + V3(0, 0, -0.004), size: V3(0.006, 0.03, 0.035), material: steel ? M.metal : M.paint)
        }
        if steel {
            // Polished lugs at the head tube and seat cluster.
            for p in [headTop - headUp * 0.02, headBottom + headUp * 0.015, cluster] {
                body.ellipsoid(center: p, radii: V3(0.021, 0.024, 0.024), rings: 6, segments: 12, material: M.metal)
            }
        }

        // --- Seatpost, saddle ---
        let saddleClamp = saddleTop - V3(0, 0.045, 0) + V3(0, 0, 0.006)
        tube([seatTop - seatDir * 0.02, saddleClamp], up: V3(0, 0, -1),
             section: isAero ? aero(0.045, 0.045, thick: 0.022, trunc: 0.5) : round(0.0136, 0.0136),
             material: plain(steel ? M.metal : M.carbon), into: &body)
        body.ellipsoid(center: saddleClamp + V3(0, 0.008, 0), radii: V3(0.02, 0.012, 0.03), rings: 5, segments: 10, material: M.black)
        // Saddle: lofted from the wide rear to the narrow nose.
        let saddleLen: Float = 0.27
        let saddleBack = saddleTop + V3(0, 0, saddleLen * 0.45), saddleNose = saddleTop + V3(0, -0.006, -saddleLen * 0.55)
        let saddlePath = catmullRom([saddleBack + V3(0, -0.012, 0.004), saddleBack + V3(0, -0.002, -0.02), saddleTop + V3(0, 0, 0.0),
                                     saddleTop + V3(0, -0.002, -0.07), saddleNose + V3(0, -0.002, 0.03), saddleNose],
                                    samplesPerSegment: 3 + 2 * seg)
        let saddleSections = hi ? 22 : 10
        body.loft(path: saddlePath, up: V3(0, 1, 0), section: { _, t in
            // Width: 140 mm at the back, 30 mm at the nose; thickness ~30 mm with a rounded top.
            let w = t < 0.35 ? mixf(0.11, 0.142, smooth01(t / 0.18)) : mixf(0.142, 0.032, smooth01((t - 0.35) / 0.55))
            let h: Float = t < 0.06 ? mixf(0.012, 0.03, t / 0.06) : mixf(0.032, 0.024, t)
            return Section.superellipse(w, h, exponent: 3, count: saddleSections).map { SIMD2($0.x, $0.y - h * 0.35) }
        }, material: { _ in M.saddle }, capStart: true, capEnd: true)
        for side: Float in [-1, 1] {   // rails
            tube([saddleBack + V3(side * 0.035, -0.025, -0.01), saddleClamp + V3(side * 0.02, 0.006, 0.02),
                  saddleClamp + V3(side * 0.018, 0.006, -0.05), saddleNose + V3(side * 0.012, -0.02, 0.03)],
                 up: V3(0, 1, 0), section: round(0.0035, 0.0035), material: plain(M.metal), into: &body, caps: false)
        }

        // --- Bottles ---
        if style != .track && style != .timeTrial {
            let dt = (downEnd - downStart).unit
            let bottleUp = V3(1, 0, 0).crossp(dt)        // perpendicular to the down tube, towards the seat tube
            let st = (seatTop - bb).unit
            let stUp = st.crossp(V3(1, 0, 0)) * -1         // in front of the seat tube
            for (base, axis, off) in [(downStart + dt * 0.13, dt, bottleUp), (bb + st * 0.13, st, stUp)] {
                var bottle = ModelMesh()
                bottle.lathe(profile: [SIMD2(0, 0), SIMD2(0.034, 0.002), SIMD2(0.036, 0.02), SIMD2(0.033, 0.09), SIMD2(0.035, 0.15),
                                       SIMD2(0.03, 0.188), SIMD2(0.013, 0.2), SIMD2(0.012, 0.222), SIMD2(0.005, 0.232), SIMD2(0, 0.233)],
                             segments: hi ? 20 : 8, material: { $0 >= 6 ? M.black : M.bottle })
                let t = RigidTransform.bone(from: base + off * 0.044, to: base + off * 0.044 + axis, side: V3(1, 0, 0))
                body.append(bottle, transform: t)
                // Cage rails.
                for s: Float in [-1, 1] {
                    let a = base + off * 0.012 + t.x * (s * 0.03)
                    tube([a, a + axis * 0.07 + off * 0.02, a + axis * 0.15 + off * 0.012], up: off, section: round(0.0028, 0.0028),
                         material: plain(M.black), into: &body, caps: false)
                }
            }
        }

        // --- Drivetrain hardware on the frame ---
        let drivetrain = Drivetrain.forFrame(style)
        let bigRing = drivetrain.chainrings.max()!
        let cogs = Array(drivetrain.cassette.prefix(hi ? 12 : 4))
        func pitchRadius(_ teeth: Int) -> Float { 0.0127 / (2 * sin(.pi / Float(teeth))) }
        let chainX: Float = 0.044
        let ringR = pitchRadius(bigRing)
        let cogTeeth = cogs[min(cogs.count - 1, 5)]
        let cogR = pitchRadius(cogTeeth)
        let cogX: Float = 0.022 + Float(cogs.count - 1 - min(cogs.count - 1, 5)) * 0.0039 + 0.004
        if hi {
            // Chain: over the top of the ring, round the sprocket, through the derailleur, back to the ring.
            let jockeyTop = rearAxle + V3(cogX, -0.055, 0.012), jockeyBottom = rearAxle + V3(cogX, -0.12, -0.012)
            var chainPath: [V3] = []
            func arc(_ c: V3, _ r: Float, _ a0: Float, _ a1: Float, _ x: Float, steps: Int) {
                for k in 0...steps {
                    let a = a0 + (a1 - a0) * Float(k) / Float(steps)
                    chainPath.append(V3(x, c.y + r * cos(a), c.z + r * sin(a)))
                }
            }
            // Angles measured from +Y towards +Z (rearwards).
            arc(rearAxle, cogR, 0, .pi, cogX, steps: 10)                              // top → back → bottom of the sprocket
            chainPath.append(jockeyTop + V3(0, 0.006, 0.005))
            arc(jockeyTop, 0.019, .pi * 0.15, .pi * 1.0, cogX, steps: 4)
            arc(jockeyBottom, 0.019, 0.0, -.pi * 0.95, cogX, steps: 5)
            let mid = mix3(jockeyBottom, bb, 0.5)
            chainPath.append(V3(mix3(V3(cogX, 0, 0), V3(chainX, 0, 0), 0.5).x, mid.y - 0.1, mid.z))
            arc(bb, ringR, .pi, 2 * .pi, chainX, steps: 16)                         // bottom → front → top of the ring
            chainPath.append(V3(cogX, rearAxle.y + cogR, rearAxle.z - 0.02))
            let link = Section.superellipse(0.0095, 0.0062, exponent: 4, count: 8)
            body.loft(path: chainPath, up: V3(1, 0, 0), section: { _, _ in link }, material: { _ in M.chain }, uvScale: 1 / 0.0254)
            // Rear derailleur: hanger knuckle, parallelogram and cage with two jockey wheels.
            tube([rearAxle + V3(0.07, -0.005, 0.006), rearAxle + V3(0.078, -0.03, 0.03), jockeyTop + V3(0.012, 0.01, 0.01)],
                 up: V3(1, 0, 0), section: oval(0.02, 0.016, 0.018, 0.014), material: plain(M.alloy), into: &body)
            for (c, r) in [(jockeyTop, Float(0.016)), (jockeyBottom, Float(0.016))] {
                var w = ModelMesh()
                w.plate(outer: Section.gear(teeth: 11, pitchRadius: r, toothDepth: 0.003), inner: Section.circle(0.004, count: 44),
                        thickness: 0.004, material: M.black)
                body.append(w, transform: RigidTransform(origin: c, x: V3(0, 0, -1), y: V3(0, 1, 0), z: V3(1, 0, 0)))
            }
            body.box(center: mix3(jockeyTop, jockeyBottom, 0.5) + V3(0.006, 0, 0), size: V3(0.003, 0.09, 0.03), material: M.alloy,
                     transform: .identity)
            // Front derailleur cage.
            let fd = bb + seatDir * (ringR + 0.03) + V3(0.035, 0, 0)
            body.box(center: fd + V3(0.008, 0, -0.02), size: V3(0.016, 0.022, 0.07), material: M.alloy)
            // Rear disc calliper on the left chainstay.
            if style != .steel && style != .track {
                body.box(center: rearAxle + V3(-0.07, 0.05, -0.04), size: V3(0.022, 0.045, 0.06), material: M.alloy)
            }
        }
        // Rim-brake calliper on the seat-stay bridge (steel).
        if style == .steel {
            let bridge = stayTop + (rearAxle - stayTop) * 0.25
            tube([bridge + V3(-0.03, 0, 0), bridge + V3(0, 0.012, 0.012), bridge + V3(0.03, 0, 0)], up: V3(0, 0, 1),
                 section: round(0.005, 0.005), material: plain(M.metal), into: &body)
            for s: Float in [-1, 1] {
                tube([bridge + V3(s * 0.02, 0, 0.004), rearAxle + V3(s * 0.016, R - 0.04, 0) + (bridge - rearAxle).unit * 0.0],
                     up: V3(0, 0, 1), section: round(0.004, 0.003), material: plain(M.metal), into: &body)
            }
        }

        // --- Steering assembly: fork, steerer, stem, bars, levers ---
        var steer = ModelMesh()
        let crown = headBottom - headUp * 0.012
        steer.ellipsoid(center: crown - headUp * 0.006, radii: V3(0.05, 0.016, 0.034), rings: 6, segments: 14,
                        material: steel ? M.metal : M.paint)
        for side: Float in [-1, 1] {
            let top = crown + V3(side * 0.045, -0.01, 0)
            let drop = frontAxle + V3(side * 0.052, 0, 0)
            let path = bezier(top, top - headUp * 0.16, drop + V3(0, 0.15, 0.025), drop, steps: 6 + 4 * seg)
            steer.loft(path: path, up: V3(0, 0, -1), section: { _, t in
                steel ? Section.circle(mixf(0.013, 0.0075, t), count: sides)
                    : Section.kammtail(chord: mixf(0.04, 0.022, t), thickness: mixf(0.027, 0.014, t), truncation: 0.45, count: sides + 2)
            }, material: { $0 > 6 + 4 * seg - 3 ? M.accent : (steel ? M.metal : M.paint) }, capStart: true, capEnd: true)
        }
        if style != .steel && style != .track && hi {
            steer.box(center: frontAxle + V3(-0.07, 0.055, 0.035), size: V3(0.022, 0.05, 0.06), material: M.alloy)
        }
        if style == .steel {
            // Front rim-brake calliper arching over the tyre.
            let c0 = crown + V3(0, -0.01, -0.012)
            for s: Float in [-1, 1] {
                tube([c0, c0 + V3(s * 0.03, -0.02, -0.005), frontAxle + V3(s * 0.016, R - 0.03, -0.02)], up: V3(0, 0, -1),
                     section: round(0.004, 0.003), material: plain(M.metal), into: &steer)
            }
        }
        // Spacers, top cap, stem.
        let steererTop = headTop + headUp * (g.spacers + 0.042)
        tube([headTop, steererTop], up: V3(0, 0, -1), section: round(0.0175, 0.0175), material: plain(steel ? M.metal : M.black), into: &steer)
        let stemStart = headTop + headUp * (g.spacers + 0.02)
        let stemDir = V3(0, sin(g.stemRise), -cos(g.stemRise))
        let stemEnd = stemStart + stemDir * g.stemLength
        tube([stemStart + stemDir * -0.02, stemEnd + stemDir * 0.012], up: V3(0, 1, 0),
             section: isAero ? oval(0.03, 0.036, 0.03, 0.034) : oval(0.036, 0.038, 0.032, 0.034),
             material: plain(steel ? M.metal : M.black), into: &steer)
        // Handlebar.
        let C = stemEnd
        let hw = g.barHalfWidth
        var hoods = C + V3(hw, 0.03, -0.1)
        var drops = C + V3(hw, -0.115, -0.035)
        var tops = C + V3(hw * 0.55, 0.012, -0.005)
        var extensionGrip: V3?
        var elbowPad: V3?
        let barR: Float = 0.0118
        switch frame.handlebar {
        case .drops, .aeroDrops, .flaredDrops:
            let flare: Float = frame.handlebar == .flaredDrops ? 0.035 : 0
            for side: Float in [-1, 1] {
                let pts: [V3] = [V3(0, 0, 0), V3(0.1, 0, 0), V3(hw - 0.035, 0, -0.004), V3(hw - 0.006, -0.001, -0.035),
                                 V3(hw + 0.002, -0.006, -0.075), V3(hw + 0.004 + flare * 0.3, -0.04, -0.098),
                                 V3(hw + 0.005 + flare * 0.6, -0.09, -0.088), V3(hw + 0.006 + flare * 0.85, -0.122, -0.05),
                                 V3(hw + 0.006 + flare, -0.13, 0.0), V3(hw + 0.005 + flare, -0.128, 0.055)]
                let path = catmullRom(pts.map { C + V3($0.x * side, $0.y, $0.z) }, samplesPerSegment: 3 + 3 * seg)
                let wing = frame.handlebar == .aeroDrops
                let n = path.count
                steer.loft(path: path, up: V3(0, 1, 0), section: { i, _ in
                    if wing, i < n / 4 { return Section.kammtail(chord: 0.05, thickness: 0.016, truncation: 0.4, count: sides + 2).map { SIMD2($0.x, $0.y - 0.01) } }
                    return Section.circle(barR, count: sides + 2)
                }, material: { i in i < n / 6 ? M.carbon : M.barTape }, capStart: false, capEnd: true)
                // Brake/shift hood and lever blade.
                let hoodBase = C + V3(side * (hw + 0.003), 0.004, -0.078)
                let hoodPath = catmullRom([hoodBase, hoodBase + V3(0, 0.022, -0.035), hoodBase + V3(0, 0.036, -0.075),
                                           hoodBase + V3(0, 0.03, -0.095)], samplesPerSegment: 3 + 2 * seg)
                steer.loft(path: hoodPath, up: V3(0, 1, 0), section: { _, t in
                    Section.superellipse(mixf(0.03, 0.024, t), mixf(0.034, 0.03, t), exponent: 2.8, count: sides)
                }, material: { _ in M.rubber }, capStart: true, capEnd: true)
                let lever0 = hoodBase + V3(0, 0.02, -0.088)
                tube([lever0, lever0 + V3(0, -0.06, -0.012), lever0 + V3(side * 0.006, -0.115, 0.01)], up: V3(0, 0, -1),
                     section: oval(0.012, 0.007, 0.01, 0.006), material: plain(M.black), into: &steer)
            }
            // Centre bar section (left end to right end through the stem).
            tube([C + V3(-0.1, 0, 0), C + V3(0.1, 0, 0)], up: V3(0, 1, 0), section: round(0.0159, 0.0159), material: plain(M.carbon), into: &steer)
            hoods = C + V3(hw + 0.003, 0.034, -0.105)
            drops = C + V3(hw + 0.006 + flare * 0.9, -0.124, -0.03)
            tops = C + V3(hw * 0.5, 0.012, 0)
        case .timeTrialExtensions:
            // Base bar wing with bullhorn ends and bar-end levers.
            let basePath = catmullRom([C + V3(-hw, 0.03, -0.12), C + V3(-hw + 0.015, -0.01, -0.03), C + V3(-0.08, -0.02, 0),
                                       C + V3(0.08, -0.02, 0), C + V3(hw - 0.015, -0.01, -0.03), C + V3(hw, 0.03, -0.12)],
                                      samplesPerSegment: 4 + 3 * seg)
            steer.loft(path: basePath, up: V3(0, 1, 0), section: { _, _ in
                Section.kammtail(chord: 0.045, thickness: 0.018, truncation: 0.4, count: sides + 2)
            }, material: { _ in M.carbon }, capStart: true, capEnd: true)
            for side: Float in [-1, 1] {
                let riser = C + V3(side * 0.08, 0.0, 0.02)
                tube([riser, riser + V3(0, 0.07, 0)], up: V3(0, 0, -1), section: round(0.011, 0.011), material: plain(M.black), into: &steer)
                // Elbow pad.
                steer.loft(path: [riser + V3(0, 0.07, 0.07), riser + V3(0, 0.072, -0.05)], up: V3(0, 1, 0), section: { _, _ in
                    Section.superellipse(0.085, 0.022, exponent: 3, count: sides)
                }, material: { _ in M.black }, capStart: true, capEnd: true)
                // Extension with a ski-bend tip.
                let ext = catmullRom([riser + V3(-side * 0.006, 0.085, 0.0), riser + V3(-side * 0.008, 0.088, -0.2),
                                      riser + V3(-side * 0.008, 0.1, -0.31), riser + V3(-side * 0.008, 0.135, -0.36)], samplesPerSegment: 4 + 2 * seg)
                steer.loft(path: ext, up: V3(0, 1, 0), section: { _, _ in Section.circle(0.0115, count: sides) },
                           material: { _ in M.barTape }, capStart: true, capEnd: true)
            }
            hoods = C + V3(hw, 0.04, -0.13)
            drops = hoods
            tops = C + V3(0.08, -0.005, -0.02)
            extensionGrip = C + V3(0.074, 0.11, -0.3)
            elbowPad = C + V3(0.08, 0.115, 0.01)
        case .bullhorn:
            let path = catmullRom([C + V3(-hw, 0.06, -0.17), C + V3(-hw - 0.004, 0.01, -0.05), C + V3(-hw + 0.04, 0, -0.002),
                                   C + V3(hw - 0.04, 0, -0.002), C + V3(hw + 0.004, 0.01, -0.05), C + V3(hw, 0.06, -0.17)],
                                  samplesPerSegment: 4 + 3 * seg)
            steer.loft(path: path, up: V3(0, 1, 0), section: { _, _ in Section.circle(barR, count: sides + 2) },
                       material: { _ in M.barTape }, capStart: true, capEnd: true)
            hoods = C + V3(hw + 0.002, 0.045, -0.13)
            drops = C + V3(hw - 0.01, 0.005, -0.04)
            tops = C + V3(hw * 0.5, 0.012, 0)
        }
        steering = steer
        self.frame = body

        // --- Wheels ---
        frontWheel = BikeModel.wheel(wheels: wheels, rear: false, radius: R, classic: steel, hi: hi, cassette: [], cassetteX: 0,
                                     disc: style != .steel && style != .track)
        rearWheel = BikeModel.wheel(wheels: wheels, rear: true, radius: R, classic: steel, hi: hi, cassette: cogs, cassetteX: 0.022,
                                    disc: style != .steel && style != .track)

        // --- Crankset (crank space) ---
        var crank = ModelMesh()
        for (k, teeth) in drivetrain.chainrings.sorted(by: >).enumerated() {
            let r = pitchRadius(teeth)
            let x = chainX - Float(k) * 0.0065
            var ring = ModelMesh()
            ring.plate(outer: hi ? Section.gear(teeth: teeth, pitchRadius: r) : Section.circle(r, count: 48),
                       inner: Section.circle(r - 0.016, count: hi ? teeth * 4 : 48), thickness: 0.004,
                       material: k == 0 ? M.alloy : M.black)
            crank.append(ring, transform: RigidTransform(origin: V3(x, 0, 0), x: V3(0, 0, -1), y: V3(0, 1, 0), z: V3(1, 0, 0)))
        }
        // Four-arm spider.
        for k in 0..<4 {
            let a = Float(k) * .pi / 2 + .pi / 4
            let dir = V3(0, cos(a), -sin(a))
            crank.loft(path: [V3(chainX + 0.004, 0, 0) + dir * 0.02, V3(chainX, 0, 0) + dir * (ringR - 0.012)], up: V3(1, 0, 0), section: { _, t in
                Section.superellipse(mixf(0.02, 0.012, t), 0.008, exponent: 3, count: 10)
            }, material: { _ in M.carbon }, capStart: false, capEnd: true)
        }
        // Spindle and arms.
        crank.tube(path: [V3(-0.075, 0, 0), V3(0.075, 0, 0)], radius: { _ in 0.012 }, sides: 12, material: M.alloy)
        for side: Float in [-1, 1] {
            let x0: Float = side * 0.068, x1: Float = side * 0.078
            let path = (0...(4 + 3 * seg)).map { k -> V3 in
                let t = Float(k) / Float(4 + 3 * seg)
                return V3(mixf(x0, x1, t), side * crankLength * t, 0)
            }
            crank.loft(path: path, up: V3(0, 0, 1), section: { _, t in
                Section.superellipse(0.013, mixf(0.032, 0.022, t), exponent: 3, count: 12)
            }, material: { _ in steel ? M.metal : M.carbon }, capStart: true, capEnd: true)
        }
        crankset = crank

        // --- Pedals (pedal space: spindle along +X) ---
        func pedal(_ side: Float) -> ModelMesh {
            var p = ModelMesh()
            p.tube(path: [V3(0, 0, 0), V3(side * 0.06, 0, 0)], radius: { _ in 0.005 }, sides: 8, material: M.metal)
            p.loft(path: [V3(side * 0.016, 0, 0), V3(side * 0.07, 0, 0)], up: V3(0, 1, 0), section: { _, _ in
                Section.superellipse(0.088, 0.018, exponent: 3.5, count: 14)
            }, material: { _ in steel ? M.metal : M.black }, capStart: true, capEnd: true)
            return p
        }
        pedalRight = pedal(1)
        pedalLeft = pedal(-1)

        anchors = BikeAnchors(frontAxle: frontAxle, rearAxle: rearAxle, bottomBracket: bb, saddleTop: saddleTop + V3(0, 0.012, 0),
                              saddleNose: saddleNose, hoods: hoods, drops: drops, tops: tops, extensionGrip: extensionGrip,
                              elbowPad: elbowPad, steeringPivot: headTop, steeringAxis: headUp, crankLength: crankLength,
                              wheelRadius: R, pedalStance: 0.11)
    }

    /// A wheel in wheel space (axle along X).
    static func wheel(wheels: Wheelset, rear: Bool, radius R: Float, classic: Bool, hi: Bool, cassette: [Int], cassetteX: Float,
                      disc: Bool) -> ModelMesh {
        let M = Material.self
        var lathe = ModelMesh()      // built about Y, rotated onto X at the end
        let segs = hi ? 72 : 24
        let tyreW = Float(wheels.tyreWidthMM) / 1000
        let bead: Float = 0.311
        let a = tyreW / 2
        // Tyre: circular section sitting on the rim.
        let c0 = bead + a * 0.86
        var tyreProfile: [SIMD2<Float>] = []
        let tyreRings = hi ? 18 : 8
        for k in 0...tyreRings {
            let t = -Float.pi * 0.62 + Float(k) / Float(tyreRings) * Float.pi * 1.24   // outer arc only (inner half sits in the rim)
            tyreProfile.append(SIMD2(c0 + a * cos(t), a * 1.04 * sin(t)))
        }
        lathe.lathe(profile: tyreProfile, segments: segs, material: { i in
            let t = Float(i) / Float(tyreRings)
            if classic && (t < 0.3 || t > 0.7) { return M.tyreWall }
            return M.tyre
        })
        // Rim.
        let depth = Float(rear && wheels.rearDisc ? 0.0 : wheels.rimDepthMM) / 1000
        let rimW: Float = depth >= 0.045 ? 0.0145 : 0.012
        if rear && wheels.rearDisc {
            lathe.lathe(profile: [SIMD2(0.03, -0.014), SIMD2(0.16, -0.0125), SIMD2(0.28, -0.0105), SIMD2(bead + 0.004, -0.009),
                                  SIMD2(bead + 0.006, 0), SIMD2(bead + 0.004, 0.009), SIMD2(0.28, 0.0105), SIMD2(0.16, 0.0125),
                                  SIMD2(0.03, 0.014)], segments: segs, material: { $0 == 1 || $0 == 6 ? M.rimDecal : M.rim },
                        v: { [1: 0, 2: 1, 6: 1, 7: 0][$0] ?? 0 })
        } else {
            let inner = bead - depth - 0.008
            let rimProfile: [SIMD2<Float>] = [
                SIMD2(inner, 0), SIMD2(inner + 0.002, -rimW * 0.45), SIMD2(inner + (depth + 0.008) * 0.35, -rimW * 0.92),
                SIMD2(bead - 0.003, -rimW), SIMD2(bead + 0.004, -rimW * 0.92), SIMD2(bead + 0.005, -rimW * 0.6),
                SIMD2(bead + 0.005, rimW * 0.6), SIMD2(bead + 0.004, rimW * 0.92), SIMD2(bead - 0.003, rimW),
                SIMD2(inner + (depth + 0.008) * 0.35, rimW * 0.92), SIMD2(inner + 0.002, rimW * 0.45), SIMD2(inner, 0),
            ]
            let decal = depth >= 0.045
            lathe.lathe(profile: rimProfile, segments: segs, material: { i in
                if decal && (i == 2 || i == 8) { return M.rimDecal }
                return (classic || depth < 0.03) ? M.metal : M.rim
            }, v: { [2: 0, 3: 1, 8: 1, 9: 0][$0] ?? 0 })
            // Spokes (2-cross on the rear drive side and front disc side, radial otherwise).
            if hi {
                let count = classic ? 32 : (depth > 0.06 ? 18 : (rear ? 24 : 20))
                let flangeR: Float = 0.026
                for k in 0..<count {
                    let sideSign: Float = k % 2 == 0 ? 1 : -1
                    let rimAngle = Float(k) / Float(count) * 2 * .pi
                    let crossed = rear ? sideSign > 0 : disc && sideSign < 0
                    let leading: Float = (k / 2) % 2 == 0 ? 1 : -1
                    let hubAngle = rimAngle + (crossed ? leading * 2 * (4 * .pi / Float(count)) : 0)
                    let hubY: Float = sideSign * (rear && sideSign > 0 ? 0.019 : 0.031)
                    let p0 = V3(flangeR * cos(hubAngle), hubY, -flangeR * sin(hubAngle))
                    let p1 = V3((inner + 0.002) * cos(rimAngle), sideSign * 0.003, -(inner + 0.002) * sin(rimAngle))
                    lathe.loft(path: [p0, p1], up: V3(0, 1, 0), section: { _, _ in
                        Section.ellipse(0.0024, 0.001, count: 4)
                    }, material: { _ in classic ? M.metal : M.black })
                }
            }
        }
        // Hub with flanges.
        lathe.lathe(profile: [SIMD2(0.006, -0.058), SIMD2(0.013, -0.054), SIMD2(0.013, -0.036), SIMD2(0.029, -0.034),
                              SIMD2(0.029, -0.029), SIMD2(0.017, -0.026), SIMD2(0.017, 0.026), SIMD2(0.029, 0.029),
                              SIMD2(0.029, 0.034), SIMD2(0.013, 0.036), SIMD2(0.013, 0.054), SIMD2(0.006, 0.058)],
                    segments: hi ? 24 : 10, material: { _ in classic ? M.metal : M.alloy })
        var wheel = ModelMesh()
        // Y (lathe axis) → X (axle).
        let toAxle = RigidTransform(origin: .zero, x: V3(0, -1, 0), y: V3(1, 0, 0), z: V3(0, 0, 1))
        wheel.append(lathe, transform: toAxle)
        // Valve stem.
        if hi {
            wheel.box(center: V3(0, bead - depth - 0.02, 0), size: V3(0.006, 0.03, 0.006), material: M.metal)
        }
        // Cassette (drive side) and brake rotor (left).
        if hi {
            for (k, teeth) in cassette.enumerated() {
                let r = 0.0127 / (2 * sin(.pi / Float(teeth)))
                var cog = ModelMesh()
                cog.plate(outer: Section.gear(teeth: teeth, pitchRadius: r, toothDepth: 0.004), inner: Section.circle(0.017, count: teeth * 4),
                          thickness: 0.0018, material: M.metal)
                let x = cassetteX + Float(cassette.count - 1 - k) * 0.0039
                wheel.append(cog, transform: RigidTransform(origin: V3(x, 0, 0), x: V3(0, 0, -1), y: V3(0, 1, 0), z: V3(1, 0, 0)))
            }
            if disc {
                var rotor = ModelMesh()
                rotor.plate(outer: Section.circle(0.08, count: 48), inner: Section.circle(0.022, count: 48), thickness: 0.0018,
                            material: M.rotor, edgeMaterial: M.metal)
                wheel.append(rotor, transform: RigidTransform(origin: V3(-0.046, 0, 0), x: V3(0, 0, -1), y: V3(0, 1, 0), z: V3(1, 0, 0)))
            }
        }
        return wheel
    }
}
