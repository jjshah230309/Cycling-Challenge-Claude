import AppKit
import BreakawayCore
import CoreGraphics
import SceneKit
import simd

/// Converts the engine's procedural meshes into SceneKit geometry, with caching
/// (bots share bikes and bodies) and distance-based levels of detail.
enum ModelGeometry {
    /// Builds an SCNGeometry whose materials are named after the mesh's material parts.
    static func geometry(_ mesh: ModelMesh, material: (String) -> SCNMaterial) -> SCNGeometry {
        var pos = [Float](), nrm = [Float](), uv = [Float](), col = [Float]()
        let colored = mesh.hasVertexColors
        pos.reserveCapacity(mesh.vertexCount * 3)
        nrm.reserveCapacity(mesh.vertexCount * 3)
        uv.reserveCapacity(mesh.vertexCount * 2)
        for i in 0..<mesh.vertexCount {
            let p = mesh.positions[i], n = mesh.normals[i], t = mesh.uvs[i]
            pos += [p.x, p.y, p.z]
            nrm += [n.x, n.y, n.z]
            uv += [t.x, 1 - t.y]
            if colored {
                let c = mesh.colors[i]
                col += [c.x, c.y, c.z, c.w]
            }
        }
        func source(_ a: [Float], _ semantic: SCNGeometrySource.Semantic, _ comps: Int) -> SCNGeometrySource {
            let data = a.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: a.count / comps, usesFloatComponents: true,
                                     componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: 4 * comps)
        }
        var elements: [SCNGeometryElement] = []
        var mats: [SCNMaterial] = []
        for part in mesh.parts {
            let data = part.indices.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: part.indices.count / 3,
                                               bytesPerIndex: 4))
            let m = material(part.material)
            mats.append(m)
        }
        var sources = [source(pos, .vertex, 3), source(nrm, .normal, 3), source(uv, .texcoord, 2)]
        if colored { sources.append(source(col, .color, 4)) }
        let g = SCNGeometry(sources: sources, elements: elements)
        g.materials = mats
        return g
    }

    /// A copy sharing vertex data but with its own materials.
    static func recoloured(_ base: SCNGeometry, material: (String) -> SCNMaterial) -> SCNGeometry {
        let g = base.copy() as! SCNGeometry
        // Base rider geometry carries one placeholder material per part, named after it.
        g.materials = base.materials.map { material($0.name ?? "") }
        if let lods = base.levelsOfDetail {
            g.levelsOfDetail = lods.compactMap { lod in
                guard let lg = lod.geometry else { return nil }
                return SCNLevelOfDetail(geometry: recoloured(lg, material: material), worldSpaceDistance: lod.worldSpaceDistance)
            }
        }
        return g
    }

    static func withLOD(high: SCNGeometry, low: SCNGeometry, distance: CGFloat) -> SCNGeometry {
        high.levelsOfDetail = [SCNLevelOfDetail(geometry: low, worldSpaceDistance: distance)]
        return high
    }

    // MARK: - Bikes

    struct BikeParts {
        let model: BikeModel
        let frame, steering, frontWheel, rearWheel, crankset, pedalL, pedalR: SCNGeometry
    }

    private static var bikeCache: [String: BikeParts] = [:]

    /// Cached, fully materialised geometry for a frame + wheels combination.
    static func bike(_ setup: BikeSetup) -> BikeParts {
        let key = "\(setup.frameID)/\(setup.wheelsID)"
        if let b = bikeCache[key] { return b }
        let hi = BikeModel(setup: setup, detail: 1)
        let lo = BikeModel(setup: setup, detail: 0.4)
        let mats = BikeMaterials(setup: setup)
        func lod(_ h: ModelMesh, _ l: ModelMesh, _ d: CGFloat = 14) -> SCNGeometry {
            withLOD(high: geometry(h, material: mats.material), low: geometry(l, material: mats.material), distance: d)
        }
        let parts = BikeParts(model: hi, frame: lod(hi.frame, lo.frame), steering: lod(hi.steering, lo.steering),
                              frontWheel: lod(hi.frontWheel, lo.frontWheel), rearWheel: lod(hi.rearWheel, lo.rearWheel),
                              crankset: lod(hi.crankset, lo.crankset), pedalL: lod(hi.pedalLeft, lo.pedalLeft, 8),
                              pedalR: lod(hi.pedalRight, lo.pedalRight, 8))
        bikeCache[key] = parts
        return parts
    }

    // MARK: - Riders

    private static var riderCache: [String: (model: RiderModel, bones: [RiderBone: SCNGeometry])] = [:]

    /// Rider body geometry (shared buffers) recoloured for a kit.
    static func rider(build: AvatarBuild, timeTrial: Bool, kit: Kit, number: Int) -> (RiderModel, [RiderBone: SCNGeometry]) {
        let key = "\(build.rawValue)/\(timeTrial)"
        let base: (model: RiderModel, bones: [RiderBone: SCNGeometry])
        if let b = riderCache[key] {
            base = b
        } else {
            let hi = RiderModel(build: build, timeTrialHelmet: timeTrial, detail: 1)
            let lo = RiderModel(build: build, timeTrialHelmet: timeTrial, detail: 0.4)
            func placeholder(_ name: String) -> SCNMaterial {
                let m = SCNMaterial()
                m.name = name
                return m
            }
            var bones: [RiderBone: SCNGeometry] = [:]
            for bone in RiderBone.allCases {
                bones[bone] = withLOD(high: geometry(hi.segments[bone]!, material: placeholder),
                                      low: geometry(lo.segments[bone]!, material: placeholder), distance: 16)
            }
            base = (hi, bones)
            riderCache[key] = base
        }
        let mats = KitMaterials(kit: kit, number: number, timeTrial: timeTrial)
        return (base.model, base.bones.mapValues { recoloured($0, material: mats.material) })
    }
}

// MARK: - Materials

private func pbr(_ c: NSColor, rough: CGFloat, metal: CGFloat = 0) -> SCNMaterial {
    SceneMath.material(c, roughness: rough, metalness: metal)
}

/// Paint, carbon, rubber and metal for one bike.
struct BikeMaterials {
    private var table: [String: SCNMaterial] = [:]

    init(setup: BikeSetup) {
        let frame = setup.frame
        let M = BikeModel.Material.self
        let paintColor = SceneMath.color(frame.color)
        let accentColor = SceneMath.color(frame.accent)
        func paint(_ c: NSColor, image: CGImage? = nil) -> SCNMaterial {
            let m = pbr(c, rough: 0.34, metal: frame.style == .steel ? 0.05 : 0.3)
            if let image {
                m.diffuse.contents = image
                m.diffuse.wrapS = .repeat
                m.diffuse.wrapT = .repeat
            }
            // Lacquer: a glossy clear coat over the colour.
            m.clearCoat.contents = 1.0
            m.clearCoatRoughness.contents = 0.06
            return m
        }
        table[M.paint] = paint(paintColor)
        table[M.accent] = paint(accentColor)
        table[M.decal] = paint(paintColor, image: ModelTextures.frameDecal(paint: frame.color, accent: frame.accent))
        let carbon = pbr(NSColor(white: 1, alpha: 1), rough: 0.3, metal: 0.15)
        carbon.diffuse.contents = ModelTextures.carbonWeave()
        carbon.diffuse.wrapS = .repeat
        carbon.diffuse.wrapT = .repeat
        carbon.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 20, 1)
        carbon.clearCoat.contents = 0.8
        carbon.clearCoatRoughness.contents = 0.1
        table[M.carbon] = carbon
        table[M.rim] = carbon
        let decal = pbr(NSColor(white: 1, alpha: 1), rough: 0.3, metal: 0.1)
        decal.diffuse.contents = ModelTextures.rimDecal(accent: frame.accent)
        decal.diffuse.wrapS = .repeat
        table[M.rimDecal] = decal
        table[M.black] = pbr(NSColor(white: 0.06, alpha: 1), rough: 0.5)
        table[M.rubber] = pbr(NSColor(white: 0.08, alpha: 1), rough: 0.85)
        table[M.metal] = pbr(NSColor(white: 0.8, alpha: 1), rough: 0.2, metal: 1)
        table[M.alloy] = pbr(NSColor(white: 0.24, alpha: 1), rough: 0.35, metal: 0.85)
        let tyre = pbr(NSColor(white: 0.09, alpha: 1), rough: 0.8)
        tyre.diffuse.contents = ModelTextures.tyreTread()
        tyre.diffuse.wrapS = .repeat
        tyre.diffuse.contentsTransform = SCNMatrix4MakeScale(24, 1, 1)
        table[M.tyre] = tyre
        table[M.tyreWall] = pbr(NSColor(srgbRed: 0.72, green: 0.56, blue: 0.34, alpha: 1), rough: 0.75)
        let chain = pbr(NSColor(white: 0.7, alpha: 1), rough: 0.35, metal: 0.9)
        chain.diffuse.contents = ModelTextures.chainLinks()
        chain.diffuse.wrapT = .repeat
        chain.diffuse.wrapS = .repeat
        table[M.chain] = chain
        let rotor = pbr(NSColor(white: 0.75, alpha: 1), rough: 0.3, metal: 1)
        rotor.diffuse.contents = ModelTextures.rotor()
        table[M.rotor] = rotor
        let tape = pbr(NSColor(white: 0.1, alpha: 1), rough: 0.7)
        tape.diffuse.contents = ModelTextures.barTape(frame.style == .steel ? 0xD8C9A8 : 0x161616)
        tape.diffuse.wrapS = .repeat
        tape.diffuse.wrapT = .repeat
        tape.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 30, 1)
        table[M.barTape] = tape
        table[M.saddle] = pbr(frame.style == .steel ? NSColor(srgbRed: 0.33, green: 0.2, blue: 0.12, alpha: 1) : NSColor(white: 0.07, alpha: 1),
                              rough: 0.55)
        let bottle = pbr(accentColor, rough: 0.4)
        bottle.transparency = 0.92
        table[M.bottle] = bottle
    }

    func material(_ name: String) -> SCNMaterial {
        table[name] ?? pbr(.magenta, rough: 0.5)
    }
}

/// Jersey, skin, helmet and shoes for one rider.
struct KitMaterials {
    private var table: [String: SCNMaterial] = [:]

    init(kit: Kit, number: Int, timeTrial: Bool) {
        let M = RiderModel.Material.self
        let jersey = pbr(.white, rough: 0.55)
        jersey.clearCoat.contents = 0.18
        jersey.clearCoatRoughness.contents = 0.5
        jersey.diffuse.contents = ModelTextures.jersey(kit: kit, number: number)
        jersey.diffuse.wrapS = .repeat
        table[M.jersey] = jersey
        let sleeve = pbr(.white, rough: 0.62)
        sleeve.diffuse.contents = ModelTextures.sleeve(kit: kit)
        sleeve.diffuse.wrapS = .repeat
        table[M.sleeve] = sleeve
        // Lycra has a soft sheen; skin is matte with a faint oily highlight.
        let shorts = pbr(SceneMath.color(kit.shorts), rough: 0.38)
        shorts.clearCoat.contents = 0.35
        shorts.clearCoatRoughness.contents = 0.45
        table[M.shorts] = shorts
        table[M.skin] = pbr(SceneMath.color(kit.skin), rough: 0.5)
        let lips = SceneMath.color(kit.skin).blended(withFraction: 0.25, of: NSColor(srgbRed: 0.6, green: 0.25, blue: 0.25, alpha: 1)) ?? .brown
        table[M.lips] = pbr(lips, rough: 0.4)
        let helmet = pbr(.white, rough: 0.25, metal: 0.05)
        helmet.diffuse.contents = ModelTextures.helmet(kit.helmet, accent: kit.jerseyAccent, timeTrial: timeTrial)
        helmet.diffuse.wrapS = .repeat
        helmet.clearCoat.contents = 0.9
        helmet.clearCoatRoughness.contents = 0.08
        table[M.helmet] = helmet
        let lens = pbr(NSColor(srgbRed: 0.1, green: 0.16, blue: 0.24, alpha: 1), rough: 0.05, metal: 0.9)
        table[M.lens] = lens
        table[M.black] = pbr(NSColor(white: 0.05, alpha: 1), rough: 0.6)
        table[M.shoe] = pbr(SceneMath.color(kit.helmet), rough: 0.35)
        table[M.sole] = pbr(NSColor(white: 0.08, alpha: 1), rough: 0.4, metal: 0.2)
        table[M.sock] = pbr(NSColor(white: 0.96, alpha: 1), rough: 0.9)
        table[M.glove] = pbr(NSColor(white: 0.1, alpha: 1), rough: 0.7)
        table[M.hair] = pbr(NSColor(srgbRed: 0.18, green: 0.12, blue: 0.08, alpha: 1), rough: 0.8)
    }

    func material(_ name: String) -> SCNMaterial {
        table[name] ?? pbr(.magenta, rough: 0.5)
    }
}

// MARK: - Textures

/// Kit and bike textures drawn with Core Graphics (cached by content).
enum ModelTextures {
    private static var cache: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage) -> CGImage {
        if let i = cache[key] { return i }
        let i = make()
        cache[key] = i
        return i
    }

    private static func cg(_ c: KitColor, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: a)
    }

    /// Jersey for the torso loft: u runs round the body (0 = left side, 0.25 = back,
    /// 0.5 = right side, 0.75 = chest), v runs from the waist (bottom) to the collar.
    static func jersey(kit: Kit, number: Int) -> CGImage {
        cached("jersey-\(kit.jersey.hex)-\(kit.jerseyAccent.hex)-\(number)") {
            let w = 1024, h = 512
            let ctx = ProceduralTextures.context(w, h)
            let W = CGFloat(w), H = CGFloat(h)
            ctx.setFillColor(cg(kit.jersey))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            // Side panels (both sides, wrapping at u = 0).
            ctx.setFillColor(cg(kit.jerseyAccent))
            for cx in [0, 0.5, 1.0] {
                ctx.fill(CGRect(x: W * CGFloat(cx) - W * 0.035, y: 0, width: W * 0.07, height: H * 0.78))
            }
            // Chest band and matching band across the shoulder blades.
            ctx.fill(CGRect(x: W * 0.53, y: H * 0.56, width: W * 0.44, height: H * 0.09))
            ctx.setFillColor(cg(kit.jerseyAccent, 0.85))
            ctx.fill(CGRect(x: W * 0.06, y: H * 0.62, width: W * 0.38, height: H * 0.05))
            // Collar and hem.
            ctx.setFillColor(cg(kit.jerseyAccent))
            ctx.fill(CGRect(x: 0, y: H * 0.94, width: W, height: H * 0.06))
            ctx.fill(CGRect(x: 0, y: H * 0.205, width: W, height: H * 0.025))
            // Zip down the chest.
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 0.7))
            ctx.fill(CGRect(x: W * 0.75 - 2, y: H * 0.25, width: 4, height: H * 0.7))
            // Rear pockets.
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
            ctx.setLineWidth(3)
            for k in 0..<3 {
                let x = W * (0.155 + CGFloat(k) * 0.065)
                ctx.stroke(CGRect(x: x, y: H * 0.23, width: W * 0.06, height: H * 0.17))
            }
            // Race number pinned on the lower back.
            if number > 0 {
                let plate = CGRect(x: W * 0.18, y: H * 0.38, width: W * 0.14, height: H * 0.15)
                ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
                ctx.fill(plate)
                ProceduralTextures.drawText("\(number)", in: ctx, rect: plate.insetBy(dx: 6, dy: 4), color: 0x111111, maxSize: plate.height * 0.8)
            }
            // Subtle fabric grain.
            var r = SceneRandom(seed: UInt64(kit.jersey.hex))
            for _ in 0..<4000 {
                ctx.setFillColor(CGColor(gray: r.chance(0.5) ? 1 : 0, alpha: 0.03))
                ctx.fill(CGRect(x: r.range(0, Double(W)), y: r.range(0, Double(H)), width: 2, height: 2))
            }
            return ctx.makeImage()!
        }
    }

    /// Sleeves: jersey colour with an accent cuff near the elbow end (v = along the arm, in metres).
    static func sleeve(kit: Kit) -> CGImage {
        cached("sleeve-\(kit.jersey.hex)-\(kit.jerseyAccent.hex)") {
            let ctx = ProceduralTextures.context(64, 256)
            ctx.setFillColor(cg(kit.jersey))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 256))
            ctx.setFillColor(cg(kit.jerseyAccent))
            // v is metres along the upper-arm loft (texture = 1 m); the sleeve ends ~0.19 m along it.
            ctx.fill(CGRect(x: 0, y: 256 * 0.155, width: 64, height: 256 * 0.04))
            return ctx.makeImage()!
        }
    }

    /// Helmet shell: u round the head, v from the brim up to the crown. Dark vents run front-to-back.
    static func helmet(_ color: KitColor, accent: KitColor, timeTrial: Bool) -> CGImage {
        cached("helmet-\(color.hex)-\(accent.hex)-\(timeTrial)") {
            let w = 512, h = 256
            let ctx = ProceduralTextures.context(w, h)
            let W = CGFloat(w), H = CGFloat(h)
            ctx.setFillColor(cg(color))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            // Accent stripe along the brim.
            ctx.setFillColor(cg(accent))
            ctx.fill(CGRect(x: 0, y: H * 0.02, width: W, height: H * 0.05))
            guard !timeTrial else { return ctx.makeImage()! }
            // Vents: slots following the meridians, longer near the crown.
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            let slots = 14
            for k in 0..<slots {
                let u = CGFloat(k) / CGFloat(slots)
                let len: CGFloat = k % 2 == 0 ? 0.42 : 0.3
                let rect = CGRect(x: W * u + W * 0.012, y: H * (0.18 + (k % 2 == 0 ? 0 : 0.1)), width: W * 0.026, height: H * len)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: W * 0.012, cornerHeight: W * 0.012, transform: nil))
                ctx.fillPath()
            }
            return ctx.makeImage()!
        }
    }

    /// Down-tube decal: u round the tube, v along it in metres (0–1 m).
    static func frameDecal(paint: KitColor, accent: KitColor) -> CGImage {
        cached("decal-\(paint.hex)-\(accent.hex)") {
            let w = 128, h = 1024
            let ctx = ProceduralTextures.context(w, h)
            ctx.setFillColor(cg(paint))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Text runs along v; drawn rotated on both flanks of the tube (u = 0/1 and 0.5).
            for cx in [CGFloat(0), 0.5, 1] {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(w) * cx, y: CGFloat(h) * 0.30)
                ctx.rotate(by: cx == 0.5 ? .pi / 2 : -.pi / 2)
                let rect = CGRect(x: -CGFloat(h) * 0.12, y: -CGFloat(w) * 0.1, width: CGFloat(h) * 0.24, height: CGFloat(w) * 0.2)
                ProceduralTextures.drawText("BREAKAWAY", in: ctx, rect: rect, color: accent.hex, maxSize: CGFloat(w) * 0.3)
                ctx.restoreGState()
            }
            return ctx.makeImage()!
        }
    }

    /// Deep-rim sidewall: carbon with repeated logos round the wheel.
    static func rimDecal(accent: KitColor) -> CGImage {
        cached("rim-\(accent.hex)") {
            let w = 2048, h = 64
            let ctx = ProceduralTextures.context(w, h)
            ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for k in 0..<4 {
                let rect = CGRect(x: CGFloat(w) * (CGFloat(k) / 4 + 0.02), y: 6, width: CGFloat(w) * 0.2, height: CGFloat(h) - 12)
                ProceduralTextures.drawText("BREAKAWAY", in: ctx, rect: rect, color: 0xF2F2F2, maxSize: CGFloat(h) * 0.7)
            }
            return ctx.makeImage()!
        }
    }

    static func carbonWeave() -> CGImage {
        cached("carbon") {
            let n = 64
            let ctx = ProceduralTextures.context(n, n)
            for y in 0..<8 {
                for x in 0..<8 {
                    let g: CGFloat = (x + y) % 2 == 0 ? 0.13 : 0.075
                    ctx.setFillColor(CGColor(gray: g, alpha: 1))
                    ctx.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
                    ctx.setFillColor(CGColor(gray: 1, alpha: 0.05))
                    ctx.fill(CGRect(x: x * 8 + 1, y: y * 8 + 1, width: 6, height: 2))
                }
            }
            return ctx.makeImage()!
        }
    }

    static func tyreTread() -> CGImage {
        cached("tread") {
            let ctx = ProceduralTextures.context(64, 64)
            ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
            for k in 0..<8 {
                ctx.fill(CGRect(x: k * 8, y: 22, width: 4, height: 20))
            }
            return ctx.makeImage()!
        }
    }

    static func chainLinks() -> CGImage {
        cached("chain") {
            let ctx = ProceduralTextures.context(32, 128)
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 128))
            // Two links (outer plate, inner plate) per v unit (= 1 inch).
            for k in 0..<2 {
                let y = CGFloat(k) * 64
                ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
                ctx.addPath(CGPath(roundedRect: CGRect(x: 2, y: y + 4, width: 28, height: 56), cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.fillPath()
                ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 10, y: y + 4, width: 12, height: 12))
            }
            return ctx.makeImage()!
        }
    }

    static func rotor() -> CGImage {
        cached("rotor") {
            let n = 256
            let ctx = ProceduralTextures.context(n, n)
            ctx.setFillColor(CGColor(gray: 0.72, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
            for ring in [0.4, 0.45] {
                for k in 0..<24 {
                    let a = Double(k) / 24 * 2 * .pi + ring * 10
                    let r = Double(n) * ring
                    ctx.fillEllipse(in: CGRect(x: Double(n) / 2 + cos(a) * r - 4, y: Double(n) / 2 + sin(a) * r - 4, width: 8, height: 8))
                }
            }
            return ctx.makeImage()!
        }
    }

    static func barTape(_ hex: UInt32) -> CGImage {
        cached("tape-\(hex)") {
            let ctx = ProceduralTextures.context(64, 64)
            ctx.setFillColor(ProceduralTextures.cg(hex))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            // Overlapping wraps.
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
            ctx.setLineWidth(3)
            for k in -2..<4 {
                ctx.move(to: CGPoint(x: 0, y: k * 24))
                ctx.addLine(to: CGPoint(x: 64, y: k * 24 + 40))
            }
            ctx.strokePath()
            return ctx.makeImage()!
        }
    }
}
