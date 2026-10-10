import AppKit
import BreakawayCore
import SceneKit
import simd

/// A procedurally modelled rider on a bike. Geometry is built per frame style
/// and wheelset; legs are solved with two-bone IK onto the pedals every frame.
final class RiderNode: SCNNode {
    let riderID: String
    private let model = SCNNode()           // pitch/lean applied here
    private let frontWheel = SCNNode()
    private let rearWheel = SCNNode()
    private let crank = SCNNode()
    private var thighs: [SCNNode] = []
    private var shins: [SCNNode] = []
    private var feet: [SCNNode] = []
    private var tag: SCNNode?
    private var lean: Float = 0
    private var bob: Float = 0

    // Geometry constants (metres, bike-local: −Z forward, +Y up, +X right).
    static let wheelRadius: Float = 0.336
    private let crankLength: Float = 0.1725
    private let thighLength: Float = 0.45
    private let shinLength: Float = 0.45
    private var bb = SIMD3<Float>(0, 0.27, 0.08)
    private var hip = SIMD3<Float>(0, 1.0, 0.27)
    /// Where the hands rest (right side; mirrored for left) and, on TT bikes, the elbow pads.
    private var handPoint = SIMD3<Float>(0.21, 0.84, -0.57)
    private var padPoint: SIMD3<Float>?

    init(state: RiderState, showTag: Bool) {
        riderID = state.id
        super.init()
        name = "rider-\(state.id)"
        addChildNode(model)
        buildBike(state.bike)
        buildRider(kit: state.kit, build: state.build, tt: state.bike.frame.style == .timeTrial)
        if showTag {
            let t = RiderNode.nameTag(state.name, pacer: state.isPacer)
            t.simdPosition = SIMD3(0, 2.25, 0)
            addChildNode(t)
            tag = t
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Materials

    private static func pbr(_ c: NSColor, rough: CGFloat, metal: CGFloat = 0) -> SCNMaterial {
        SceneMath.material(c, roughness: rough, metalness: metal)
    }

    // MARK: - Bike

    private func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float, _ m: SCNMaterial, aero: Float = 1, parent: SCNNode? = nil) {
        let cyl = SCNCylinder(radius: CGFloat(r), height: CGFloat(simd_length(b - a)))
        cyl.radialSegmentCount = 10
        cyl.materials = [m]
        let holder = SCNNode()
        SceneMath.place(holder, from: a, to: b)
        let n = SCNNode(geometry: cyl)
        if aero != 1 { n.simdScale = SIMD3(1 / aero.squareRoot(), 1, aero) }
        holder.addChildNode(n)
        (parent ?? model).addChildNode(holder)
    }

    private func buildBike(_ setup: BikeSetup) {
        let frame = setup.frame
        let wheels = setup.wheels
        let paint = RiderNode.pbr(SceneMath.color(frame.color), rough: 0.28, metal: frame.style == .steel ? 0.2 : 0.35)
        let accent = RiderNode.pbr(SceneMath.color(frame.accent), rough: 0.3, metal: 0.4)
        let black = RiderNode.pbr(NSColor(white: 0.07, alpha: 1), rough: 0.55)
        let rubber = RiderNode.pbr(NSColor(white: 0.1, alpha: 1), rough: 0.9)
        let silver = RiderNode.pbr(NSColor(white: 0.78, alpha: 1), rough: 0.25, metal: 0.95)
        let carbon = RiderNode.pbr(NSColor(white: 0.12, alpha: 1), rough: 0.35, metal: 0.3)

        let R = RiderNode.wheelRadius
        let wheelbase: Float = frame.style == .gravel ? 1.03 : (frame.style == .track ? 0.97 : 1.0)
        let rearAxle = SIMD3<Float>(0, R, wheelbase / 2)
        let frontAxle = SIMD3<Float>(0, R, -wheelbase / 2)
        bb = SIMD3(0, 0.27, wheelbase / 2 - 0.41)

        // Tube radii and shapes per style.
        var r: Float = 0.017, aero: Float = 1
        var seatTop = SIMD3<Float>(0, 0.78, bb.z + 0.17)
        var headTop = SIMD3<Float>(0, 0.80, -wheelbase / 2 + 0.11)
        let headBottom = SIMD3<Float>(0, 0.64, -wheelbase / 2 + 0.065)
        var stayTop = seatTop - SIMD3(0, 0.02, 0.02)
        switch frame.style {
        case .steel:
            r = 0.0145
            seatTop.y = 0.82
            headTop.y = 0.82
            stayTop = seatTop - SIMD3(0, 0.015, 0.01)
        case .climbing:
            r = 0.0165 * Float(frame.tubeScale / 0.85)
        case .aero, .track:
            r = 0.019
            aero = 2.6
            stayTop = SIMD3(0, 0.66, seatTop.z - 0.05)
        case .timeTrial:
            r = 0.02
            aero = 3.2
            seatTop = SIMD3(0, 0.76, bb.z + 0.12)
            headTop = SIMD3(0, 0.72, -wheelbase / 2 + 0.11)
            stayTop = SIMD3(0, 0.62, seatTop.z - 0.05)
        case .gravel:
            r = 0.019
            headTop.y = 0.84
        case .endurance:
            r = 0.018
            headTop.y = 0.84
        }

        // Main triangle + rear triangle + fork.
        tube(bb, seatTop, r, paint, aero: aero)
        tube(seatTop, headTop, r * 0.92, paint, aero: aero)
        tube(bb, headBottom + SIMD3(0, 0.02, 0.01), r * 1.15, paint, aero: aero)
        tube(headBottom, headTop + SIMD3(0, 0.03, -0.01), r * 1.1, accent)
        for side: Float in [-1, 1] {
            let axle = rearAxle + SIMD3(side * 0.065, 0, 0)
            tube(bb + SIMD3(side * 0.03, 0, 0), axle, r * 0.6, paint)
            tube(stayTop + SIMD3(side * 0.02, 0, 0), axle, r * 0.5, paint)
            tube(headBottom + SIMD3(side * 0.03, 0, 0), frontAxle + SIMD3(side * 0.055, 0, 0), r * 0.62, paint, aero: aero > 1 ? 2 : 1)
        }

        // Seatpost + saddle.
        let saddlePos = seatTop + simd_normalize(seatTop - bb) * 0.16
        tube(seatTop, saddlePos, 0.0135, frame.style == .steel ? silver : carbon)
        let saddle = SCNBox(width: 0.13, height: 0.035, length: 0.27, chamferRadius: 0.015)
        saddle.materials = [black]
        let sn = SCNNode(geometry: saddle)
        sn.simdPosition = saddlePos + SIMD3(0, 0.02, 0.0)
        model.addChildNode(sn)
        hip = SIMD3(0, saddlePos.y + 0.075, saddlePos.z - 0.01)

        // Cockpit.
        let stemEnd = headTop + SIMD3(0, 0.02, -0.11)
        tube(headTop + SIMD3(0, 0.03, 0), stemEnd, 0.016, frame.style == .steel ? silver : carbon)
        switch frame.handlebar {
        case .drops, .aeroDrops, .flaredDrops:
            let half: Float = frame.handlebar == .flaredDrops ? 0.24 : 0.21
            tube(SIMD3(-half, stemEnd.y, stemEnd.z), SIMD3(half, stemEnd.y, stemEnd.z), 0.013, frame.style == .steel ? silver : black,
                 aero: frame.handlebar == .aeroDrops ? 2.2 : 1)
            for side: Float in [-1, 1] {
                let top = SIMD3<Float>(side * half, stemEnd.y, stemEnd.z)
                let hood = SIMD3<Float>(side * half, stemEnd.y + 0.02, stemEnd.z - 0.07)
                let drop = SIMD3<Float>(side * (half + (frame.handlebar == .flaredDrops ? 0.03 : 0)), stemEnd.y - 0.13, stemEnd.z - 0.06)
                let end = SIMD3<Float>(side * (half + (frame.handlebar == .flaredDrops ? 0.04 : 0)), stemEnd.y - 0.14, stemEnd.z + 0.04)
                tube(top, hood, 0.014, black)
                tube(hood, drop, 0.013, black)
                tube(drop, end, 0.013, black)
            }
            handPoint = SIMD3(half, stemEnd.y + 0.035, stemEnd.z - 0.07)
        case .timeTrialExtensions:
            tube(SIMD3(-0.2, stemEnd.y - 0.02, stemEnd.z), SIMD3(0.2, stemEnd.y - 0.02, stemEnd.z), 0.014, black, aero: 2.5)
            for side: Float in [-1, 1] {
                tube(SIMD3(side * 0.08, stemEnd.y + 0.06, stemEnd.z + 0.05), SIMD3(side * 0.07, stemEnd.y + 0.08, stemEnd.z - 0.3), 0.012, black)
                let pad = SCNBox(width: 0.08, height: 0.03, length: 0.12, chamferRadius: 0.01)
                pad.materials = [black]
                let pn = SCNNode(geometry: pad)
                pn.simdPosition = SIMD3(side * 0.08, stemEnd.y + 0.075, stemEnd.z + 0.02)
                model.addChildNode(pn)
            }
            padPoint = SIMD3(0.08, stemEnd.y + 0.12, stemEnd.z + 0.02)
            handPoint = SIMD3(0.07, stemEnd.y + 0.11, stemEnd.z - 0.28)
        case .bullhorn:
            tube(SIMD3(-0.19, stemEnd.y, stemEnd.z), SIMD3(0.19, stemEnd.y, stemEnd.z), 0.013, black)
            for side: Float in [-1, 1] {
                tube(SIMD3(side * 0.19, stemEnd.y, stemEnd.z), SIMD3(side * 0.2, stemEnd.y + 0.04, stemEnd.z - 0.14), 0.013, black)
            }
            handPoint = SIMD3(0.2, stemEnd.y + 0.06, stemEnd.z - 0.12)
        }

        // Wheels.
        for (node, axle, isRear) in [(frontWheel, frontAxle, false), (rearWheel, rearAxle, true)] {
            node.simdPosition = axle
            buildWheel(into: node, wheels: wheels, rear: isRear, rubber: rubber, carbon: carbon, silver: silver,
                       accent: accent, classic: frame.style == .steel)
            model.addChildNode(node)
        }

        // Crankset (spins with cadence).
        crank.simdPosition = bb
        let ring = SCNCylinder(radius: 0.1, height: 0.006)
        ring.materials = [silver]
        let rn = SCNNode(geometry: ring)
        rn.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        rn.simdPosition = SIMD3(0.05, 0, 0)
        crank.addChildNode(rn)
        for (side, dirY) in [(Float(1), Float(1)), (Float(-1), Float(-1))] {
            let arm = SCNBox(width: 0.012, height: CGFloat(crankLength), length: 0.025, chamferRadius: 0.005)
            arm.materials = [frame.style == .steel ? silver : carbon]
            let an = SCNNode(geometry: arm)
            an.simdPosition = SIMD3(side * 0.075, dirY * crankLength / 2, 0)
            crank.addChildNode(an)
            let pedal = SCNBox(width: 0.09, height: 0.015, length: 0.07, chamferRadius: 0.005)
            pedal.materials = [black]
            let pn = SCNNode(geometry: pedal)
            pn.simdPosition = SIMD3(side * 0.12, dirY * crankLength, 0)
            crank.addChildNode(pn)
        }
        model.addChildNode(crank)
        // Chain.
        tube(bb + SIMD3(0.05, 0.09, 0), rearAxle + SIMD3(0.05, 0.04, 0), 0.004, silver)
        tube(bb + SIMD3(0.05, -0.09, 0), rearAxle + SIMD3(0.05, -0.04, 0), 0.004, silver)
        // Bottle.
        let bottle = SCNCapsule(capRadius: 0.035, height: 0.2)
        bottle.materials = [accent]
        let bn = SCNNode(geometry: bottle)
        SceneMath.place(bn, from: bb + (seatTop - bb) * 0.25 + SIMD3(0, 0, -0.05), to: bb + (seatTop - bb) * 0.6 + SIMD3(0, 0, -0.05))
        model.addChildNode(bn)
    }

    private func buildWheel(into node: SCNNode, wheels: Wheelset, rear: Bool, rubber: SCNMaterial, carbon: SCNMaterial,
                            silver: SCNMaterial, accent: SCNMaterial, classic: Bool) {
        let R = RiderNode.wheelRadius
        let tyreR = Float(wheels.tyreWidthMM) / 2000
        let spinner = SCNNode()
        spinner.name = "spinner"
        // Wheel geometry is built with its axle along X.
        let toAxleX = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let tyre = SCNTorus(ringRadius: CGFloat(R - tyreR), pipeRadius: CGFloat(tyreR))
        tyre.ringSegmentCount = 36
        tyre.pipeSegmentCount = 8
        tyre.materials = [rubber]
        let tn = SCNNode(geometry: tyre)
        tn.simdOrientation = toAxleX
        spinner.addChildNode(tn)

        let rimOuter = R - tyreR * 1.6
        let depth = Float(wheels.rimDepthMM) / 1000
        if rear && wheels.rearDisc {
            let disc = SCNCylinder(radius: CGFloat(rimOuter), height: 0.024)
            disc.radialSegmentCount = 36
            disc.materials = [carbon]
            let dn = SCNNode(geometry: disc)
            dn.simdOrientation = toAxleX
            spinner.addChildNode(dn)
        } else {
            let rim = SCNTube(innerRadius: CGFloat(rimOuter - depth), outerRadius: CGFloat(rimOuter), height: 0.02)
            rim.radialSegmentCount = 36
            rim.materials = [classic || depth < 0.03 ? silver : carbon]
            let rn = SCNNode(geometry: rim)
            rn.simdOrientation = toAxleX
            spinner.addChildNode(rn)
            if depth >= 0.045 {
                // Decal band on deep rims.
                let decal = SCNTube(innerRadius: CGFloat(rimOuter - depth * 0.7), outerRadius: CGFloat(rimOuter - depth * 0.35), height: 0.021)
                decal.radialSegmentCount = 36
                decal.materials = [accent]
                let dn = SCNNode(geometry: decal)
                dn.simdOrientation = toAxleX
                spinner.addChildNode(dn)
            }
            let spokes = classic ? 32 : (depth > 0.06 ? 16 : 20)
            let spokeGeo = SCNCylinder(radius: 0.0011, height: CGFloat(rimOuter - depth - 0.02))
            spokeGeo.radialSegmentCount = 3
            spokeGeo.materials = [silver]
            let spokesNode = SCNNode()
            for k in 0..<spokes {
                let a = Float(k) / Float(spokes) * 2 * .pi
                let s = SCNNode(geometry: spokeGeo)
                let mid = (rimOuter - depth + 0.02) / 2
                s.simdPosition = SIMD3(k % 2 == 0 ? 0.012 : -0.012, mid * cos(a), mid * sin(a))
                s.simdOrientation = simd_quatf(angle: a, axis: SIMD3(1, 0, 0))
                spokesNode.addChildNode(s)
            }
            spinner.addChildNode(spokesNode.flattenedClone())
        }
        let hub = SCNCylinder(radius: 0.022, height: 0.1)
        hub.materials = [silver]
        let hn = SCNNode(geometry: hub)
        hn.simdOrientation = toAxleX
        spinner.addChildNode(hn)
        node.addChildNode(spinner)
    }

    // MARK: - Rider

    private func buildRider(kit: Kit, build: AvatarBuild, tt: Bool) {
        let jersey = RiderNode.pbr(SceneMath.color(kit.jersey), rough: 0.7)
        let accent = RiderNode.pbr(SceneMath.color(kit.jerseyAccent), rough: 0.7)
        let shorts = RiderNode.pbr(SceneMath.color(kit.shorts), rough: 0.6)
        let skin = RiderNode.pbr(SceneMath.color(kit.skin), rough: 0.65)
        let helmet = RiderNode.pbr(SceneMath.color(kit.helmet), rough: 0.25, metal: 0.1)
        let shoe = RiderNode.pbr(NSColor(white: 0.95, alpha: 1), rough: 0.4)
        let visor = RiderNode.pbr(NSColor(white: 0.05, alpha: 1), rough: 0.05, metal: 0.8)
        let girth: Float = build == .slim ? 0.9 : (build == .sprinter ? 1.15 : 1.0)

        let shoulder = tt ? SIMD3<Float>(0, hip.y + 0.17, hip.z - 0.58) : SIMD3<Float>(0, hip.y + 0.33, hip.z - 0.45)
        // Torso.
        let torso = SCNCapsule(capRadius: CGFloat(0.13 * girth), height: CGFloat(simd_length(shoulder - hip) + 0.18))
        torso.materials = [jersey]
        let tn = SCNNode(geometry: torso)
        SceneMath.place(tn, from: hip, to: shoulder)
        tn.simdScale = SIMD3(1.3, 1, 0.85)
        model.addChildNode(tn)
        // Jersey stripe.
        let stripe = SCNCapsule(capRadius: CGFloat(0.132 * girth), height: 0.16)
        stripe.materials = [accent]
        let sn = SCNNode(geometry: stripe)
        SceneMath.place(sn, from: hip + (shoulder - hip) * 0.45, to: hip + (shoulder - hip) * 0.62)
        sn.simdScale = SIMD3(1.31, 1, 0.86)
        model.addChildNode(sn)
        // Shorts / pelvis.
        let pelvis = SCNSphere(radius: CGFloat(0.13 * girth))
        pelvis.materials = [shorts]
        let pn = SCNNode(geometry: pelvis)
        pn.simdPosition = hip + SIMD3(0, 0.02, 0)
        pn.simdScale = SIMD3(1.35, 0.9, 1.1)
        model.addChildNode(pn)

        // Head + helmet + glasses.
        let headPos = shoulder + (tt ? SIMD3(0, 0.12, -0.14) : SIMD3(0, 0.16, -0.12))
        let neck = SCNCapsule(capRadius: 0.05, height: 0.16)
        neck.materials = [skin]
        let nn = SCNNode(geometry: neck)
        SceneMath.place(nn, from: shoulder, to: headPos)
        model.addChildNode(nn)
        let head = SCNSphere(radius: 0.1)
        head.materials = [skin]
        let hn = SCNNode(geometry: head)
        hn.simdPosition = headPos
        model.addChildNode(hn)
        let hel = SCNSphere(radius: 0.122)
        hel.materials = [helmet]
        let heln = SCNNode(geometry: hel)
        heln.simdPosition = headPos + SIMD3(0, 0.045, tt ? 0.06 : 0.01)
        heln.simdScale = tt ? SIMD3(0.95, 0.78, 1.9) : SIMD3(1, 0.78, 1.18)
        model.addChildNode(heln)
        let glasses = SCNBox(width: 0.17, height: 0.04, length: 0.03, chamferRadius: 0.01)
        glasses.materials = [visor]
        let gn = SCNNode(geometry: glasses)
        gn.simdPosition = headPos + SIMD3(0, 0.01, -0.095)
        model.addChildNode(gn)

        // Arms (static pose on the hoods / aero pads).
        for side: Float in [-1, 1] {
            let sh = shoulder + SIMD3(side * 0.19 * girth, -0.02, 0)
            let hand = SIMD3(side * handPoint.x, handPoint.y, handPoint.z)
            let elbow: SIMD3<Float>
            if tt, let pad = padPoint {
                elbow = SIMD3(side * pad.x, pad.y, pad.z)
            } else {
                elbow = (sh + hand) / 2 + SIMD3(side * 0.05, -0.05, 0.05)
            }
            tubeCapsule(sh, elbow, 0.048 * girth, jersey)
            tubeCapsule(elbow, hand, 0.037, skin)
            let glove = SCNSphere(radius: 0.04)
            glove.materials = [shorts]
            let g = SCNNode(geometry: glove)
            g.simdPosition = hand
            model.addChildNode(g)
        }

        // Legs (animated).
        for side: Float in [-1, 1] {
            let thigh = SCNNode(geometry: { () -> SCNGeometry in
                let c = SCNCapsule(capRadius: CGFloat(0.068 * girth), height: CGFloat(thighLength + 0.1))
                c.materials = [shorts]
                return c
            }())
            let shin = SCNNode(geometry: { () -> SCNGeometry in
                let c = SCNCapsule(capRadius: 0.048, height: CGFloat(shinLength + 0.06))
                c.materials = [skin]
                return c
            }())
            let foot = SCNNode(geometry: { () -> SCNGeometry in
                let b = SCNBox(width: 0.09, height: 0.07, length: 0.26, chamferRadius: 0.03)
                b.materials = [shoe]
                return b
            }())
            _ = side
            model.addChildNode(thigh)
            model.addChildNode(shin)
            model.addChildNode(foot)
            thighs.append(thigh)
            shins.append(shin)
            feet.append(foot)
        }
        updateLegs(crankAngle: 0)
    }

    private func tubeCapsule(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float, _ m: SCNMaterial) {
        let c = SCNCapsule(capRadius: CGFloat(r), height: CGFloat(simd_length(b - a) + 2 * r))
        c.materials = [m]
        let n = SCNNode(geometry: c)
        SceneMath.place(n, from: a, to: b)
        model.addChildNode(n)
    }

    /// Two-bone IK in the bike's sagittal plane.
    private func updateLegs(crankAngle: Double) {
        let theta = Float(crankAngle)
        for (i, side) in [Float(1), Float(-1)].enumerated() {
            let a = theta + (side > 0 ? 0 : .pi)
            let pedal = bb + SIMD3(side * 0.12, crankLength * cos(a), -crankLength * sin(a))
            let ankle = pedal + SIMD3(0, 0.06, 0.035)
            let h = hip + SIMD3(side * 0.095, 0, 0)
            var v = ankle - h
            var d = simd_length(v)
            d = min(max(d, abs(thighLength - shinLength) + 0.02), thighLength + shinLength - 0.004)
            v = simd_normalize(v)
            let along = (thighLength * thighLength - shinLength * shinLength + d * d) / (2 * d)
            let up = sqrt(max(0, thighLength * thighLength - along * along))
            // Perpendicular in the sagittal (YZ) plane, pointing forward (knee ahead of the hip–ankle line).
            var perp = SIMD3<Float>(0, -v.z, v.y)
            if perp.z > 0 { perp = -perp }
            let knee = h + v * along + simd_normalize(perp) * up
            let ankleSolved = h + v * d
            SceneMath.place(thighs[i], from: h, to: knee)
            SceneMath.place(shins[i], from: knee, to: ankleSolved)
            feet[i].simdPosition = pedal + SIMD3(0, 0.035, -0.02)
            feet[i].simdOrientation = simd_quatf(angle: 0.12 * sin(a), axis: SIMD3(1, 0, 0))
        }
    }

    // MARK: - Per-frame update

    /// Places the rider on the road and animates pedalling / wheels / lean.
    func update(state: RiderState, route: Route, frame: WorldFrame, dt: Float, detailed: Bool) {
        let s = route.sample(at: state.distance)
        let right = LocalPoint(x: s.direction.y, y: -s.direction.x)
        let pos = s.position + right * state.lateral
        simdPosition = frame.point(pos, s.elevation + 0.05)

        // Lean into corners: φ = atan(v²κ / g).
        let ahead = route.direction(at: state.distance + 6), behind = route.direction(at: state.distance - 6)
        let turn = atan2(behind.x * ahead.y - behind.y * ahead.x, behind.x * ahead.x + behind.y * ahead.y)   // + = left turn
        let curvature = -turn / 12
        let target = Float(max(-0.55, min(0.55, atan(state.speed * state.speed * curvature / 9.81))))
        lean += (target - lean) * min(1, dt * 4)
        let yaw = frame.yaw(s.direction)
        simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let pitch = Float(atan(s.grade))
        bob += dt * Float(state.cadence / 60) * 2 * .pi
        let rock = detailed && state.power > 450 ? 0.06 * sin(bob) : 0
        model.simdOrientation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -lean + rock, axis: SIMD3(0, 0, 1))

        let wheelRotation = simd_quatf(angle: -Float(state.wheelAngle), axis: SIMD3(1, 0, 0))
        frontWheel.childNodes.first?.simdOrientation = wheelRotation
        rearWheel.childNodes.first?.simdOrientation = wheelRotation
        if detailed {
            crank.simdOrientation = simd_quatf(angle: -Float(state.crankAngle), axis: SIMD3(1, 0, 0))
            updateLegs(crankAngle: state.crankAngle)
        }
    }

    func setTagVisible(_ visible: Bool) { tag?.isHidden = !visible }

    // MARK: - Name tag

    static func nameTag(_ text: String, pacer: Bool) -> SCNNode {
        let w = 512, h = 112
        let ctx = ProceduralTextures.context(w, h)
        ctx.setFillColor(ProceduralTextures.cg(pacer ? 0x00A6D6 : 0x111418, 0.82))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 4, y: 4, width: w - 8, height: h - 8), cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.fillPath()
        ProceduralTextures.drawText(text, in: ctx, rect: CGRect(x: 16, y: 8, width: w - 32, height: h - 16), color: 0xFFFFFF, maxSize: 56)
        let plane = SCNPlane(width: 1.5, height: 0.33)
        let m = SCNMaterial()
        m.diffuse.contents = ctx.makeImage()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 10
        node.castsShadow = false
        return node
    }
}
