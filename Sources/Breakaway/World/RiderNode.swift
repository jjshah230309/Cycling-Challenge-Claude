import AppKit
import BreakawayCore
import SceneKit
import simd

/// A rider on a bike, built from the engine's procedural models (lofted body,
/// detailed bike) and animated every frame: legs follow the pedals with IK and
/// ankling, the torso and arms move between riding positions, the bike leans
/// and steers through bends and rocks when the rider climbs out of the saddle.
final class RiderNode: SCNNode {
    let riderID: String
    private let model = SCNNode()            // pitch, lean and rock are applied here
    private let steering = SCNNode()
    private let frontSpinner = SCNNode()
    private let rearSpinner = SCNNode()
    private let crank = SCNNode()
    private let pedalL = SCNNode()
    private let pedalR = SCNNode()
    private var bones: [RiderBone: SCNNode] = [:]
    private let anchors: BikeAnchors
    private let dimensions: RiderDimensions
    private var params: PoseParameters
    private var roll: Float = 0
    private var steer: Float = 0
    private var standWeight: Float = 0
    private var frameCount = 0
    private var tag: SCNNode?

    init(state: RiderState, showTag: Bool) {
        riderID = state.id
        let bike = ModelGeometry.bike(state.bike)
        anchors = bike.model.anchors
        let tt = state.bike.frame.style == .timeTrial
        let number = state.isPlayer ? 1 : (Int(state.id.filter(\.isNumber)) ?? 0) + 2
        let (rider, bodyGeometry, skinned) = ModelGeometry.rider(build: state.build, timeTrial: tt, kit: state.kit, number: number)
        dimensions = rider.dimensions
        params = PoseParameters.target(state.posture, anchors: anchors)
        super.init()
        name = "rider-\(state.id)"
        addChildNode(model)

        // Bike.
        model.addChildNode(SCNNode(geometry: bike.frame))
        steering.geometry = bike.steering
        model.addChildNode(steering)
        let front = SCNNode()
        front.simdPosition = anchors.frontAxle
        frontSpinner.geometry = bike.frontWheel
        front.addChildNode(frontSpinner)
        steering.addChildNode(front)
        let rear = SCNNode()
        rear.simdPosition = anchors.rearAxle
        rearSpinner.geometry = bike.rearWheel
        rear.addChildNode(rearSpinner)
        model.addChildNode(rear)
        crank.simdPosition = anchors.bottomBracket
        crank.geometry = bike.crankset
        model.addChildNode(crank)
        pedalL.geometry = bike.pedalL
        pedalR.geometry = bike.pedalR
        model.addChildNode(pedalL)
        model.addChildNode(pedalR)

        // Body.
        for bone in RiderBone.allCases {
            let n = SCNNode(geometry: bodyGeometry[bone])
            n.name = bone.rawValue
            bones[bone] = n
            model.addChildNode(n)
        }
        applyPose(crankAngle: state.crankAngle)
        // Realistic body: skinned on the GPU to the same bone nodes the pose solver drives.
        if let skinned {
            let skinner = SCNSkinner(baseGeometry: skinned.geometry, bones: RiderBone.allCases.map { bones[$0]! },
                                     boneInverseBindTransforms: skinned.inverseBind, boneWeights: skinned.weights,
                                     boneIndices: skinned.indices)
            skinner.skeleton = model
            let bodyNode = SCNNode(geometry: skinned.geometry)
            bodyNode.name = "body"
            bodyNode.skinner = skinner
            model.addChildNode(bodyNode)
        }

        if showTag {
            let t = RiderNode.nameTag(state.name, pacer: state.isPacer)
            t.simdPosition = SIMD3(0, 2.05, 0)
            addChildNode(t)
            tag = t
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func matrix(_ t: RigidTransform) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(t.x, 0), SIMD4(t.y, 0), SIMD4(t.z, 0), SIMD4(t.origin, 1)))
    }

    private func applyPose(crankAngle: Double) {
        let rock = RiderPose.standingRock(crankAngle: crankAngle) * standWeight
        let pose = RiderPose.solve(params: params, anchors: anchors, dimensions: dimensions, crankAngle: crankAngle,
                                   roll: rock, steer: steer)
        for (bone, t) in pose.bones { bones[bone]?.simdTransform = RiderNode.matrix(t) }
        pedalL.simdTransform = RiderNode.matrix(pose.pedalLeft)
        pedalR.simdTransform = RiderNode.matrix(pose.pedalRight)
        crank.simdOrientation = simd_quatf(angle: -Float(crankAngle), axis: SIMD3(1, 0, 0))
    }

    // MARK: - Per-frame update

    /// Places the rider on the road and animates pedalling, wheels, steering, lean and posture.
    func update(state: RiderState, route: Route, frame: WorldFrame, dt: Float, detailed: Bool) {
        let s = route.sample(at: state.distance)
        let right = LocalPoint(x: s.direction.y, y: -s.direction.x)
        let pos = s.position + right * state.lateral
        simdPosition = frame.point(pos, s.elevation + 0.01)
        simdOrientation = simd_quatf(angle: frame.yaw(s.direction), axis: SIMD3(0, 1, 0))

        // Lean into bends, φ = atan(v²κ/g), and steer the front wheel, δ ≈ atan(L·κ).
        let kappa = route.curvature(at: state.distance)
        let targetRoll = Float(max(-0.8, min(0.8, Cornering.leanAngle(speed: state.speed, curvature: kappa))))
        roll += (targetRoll - roll) * min(1, dt * 4)
        let targetSteer = Float(max(-0.4, min(0.4, atan(1.0 * kappa)))) * (state.speed < 4 ? 1.4 : 1)
        steer += (targetSteer - steer) * min(1, dt * 5)
        // Ease between riding positions.
        let target = PoseParameters.target(state.posture, anchors: anchors)
        params = params.blended(to: target, 1 - exp(-dt * 5))
        standWeight += ((state.posture == .standing ? 1 : 0) - standWeight) * min(1, dt * 4)
        let rock = RiderPose.standingRock(crankAngle: state.crankAngle) * standWeight

        let pitch = Float(atan(s.grade))
        model.simdOrientation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: roll + rock, axis: SIMD3(0, 0, 1))

        // Steering assembly turns about the head-tube axis.
        let q = simd_quatf(angle: steer, axis: anchors.steeringAxis)
        var m = simd_float4x4(q)
        let pivot = anchors.steeringPivot
        m.columns.3 = SIMD4(pivot - q.act(pivot), 1)
        steering.simdTransform = m

        let wheelRotation = simd_quatf(angle: -Float(state.wheelAngle), axis: SIMD3(1, 0, 0))
        frontSpinner.simdOrientation = wheelRotation
        rearSpinner.simdOrientation = wheelRotation

        // Full IK for nearby riders every frame, distant ones a few times a second.
        frameCount += 1
        if detailed || frameCount % 6 == 0 {
            applyPose(crankAngle: state.crankAngle)
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
        let plane = SCNPlane(width: 1.1, height: 0.24)
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
