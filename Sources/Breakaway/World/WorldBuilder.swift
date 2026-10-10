import AppKit
import BreakawayCore
import Foundation
import SceneKit
import simd

/// The static 3D world for one route.
final class BuiltWorld {
    let scene: SCNScene
    let frame: WorldFrame
    let route: Route
    let sun: SCNNode
    let ridersRoot: SCNNode

    init(scene: SCNScene, frame: WorldFrame, route: Route, sun: SCNNode, ridersRoot: SCNNode) {
        self.scene = scene
        self.frame = frame
        self.route = route
        self.sun = sun
        self.ridersRoot = ridersRoot
    }
}

/// Generates terrain, road, scenery, signage, water, sky and lighting from
/// the route's real geometry and DEM.
enum WorldBuilder {
    static let corridorOffsets: [Double] = [5.5, 8, 12, 18, 26, 36, 50, 70, 95, 125, 160, 200, 250]
    static let corridorHole = 120.0

    static func build(route: Route, progress: @escaping (Double, String) -> Void) -> BuiltWorld {
        let terrain = route.terrain
        let frame = WorldFrame(baseElevation: route.minElevation)
        let scene = SCNScene()
        let root = scene.rootNode
        let biome = route.record.biome

        progress(0.05, "Sky & light")
        setupEnvironment(scene: scene, biome: biome, terrain: terrain)
        let sun = makeSun()
        root.addChildNode(sun)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 260
        ambient.light?.color = NSColor(srgbRed: 0.75, green: 0.82, blue: 0.95, alpha: 1)
        root.addChildNode(ambient)

        progress(0.12, "Valleys & mountains (DEM)")
        root.addChildNode(farTerrain(route: route, terrain: terrain, frame: frame))
        progress(0.35, "Hillsides along the road")
        root.addChildNode(corridorTerrain(route: route, terrain: terrain, frame: frame))
        progress(0.55, "Road surface")
        root.addChildNode(road(route: route, terrain: terrain, frame: frame))
        root.addChildNode(guardrails(route: route, terrain: terrain, frame: frame))
        if let w = terrain.waterLevel {
            root.addChildNode(water(level: w, terrain: terrain, frame: frame))
        }
        progress(0.68, "Forests & villages")
        var rng = SceneRandom(seed: UInt64(StableHash.hex(route.id), radix: 16) ?? 7)
        root.addChildNode(vegetation(route: route, terrain: terrain, frame: frame, rng: &rng))
        root.addChildNode(buildings(route: route, terrain: terrain, frame: frame, rng: &rng))
        progress(0.85, "Crowds & signage")
        root.addChildNode(crowds(route: route, terrain: terrain, frame: frame, rng: &rng))
        root.addChildNode(signage(route: route, frame: frame))

        let riders = SCNNode()
        riders.name = "riders"
        root.addChildNode(riders)
        progress(1, "Ready")
        return BuiltWorld(scene: scene, frame: frame, route: route, sun: sun, ridersRoot: riders)
    }

    // MARK: - Environment

    static func setupEnvironment(scene: SCNScene, biome: RouteRecord.Biome, terrain: TerrainModel) {
        let sky = ProceduralTextures.sky(biome: biome)
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = 1.1
        let size = max(terrain.width, terrain.depth)
        scene.fogStartDistance = CGFloat(min(2500, size * 0.12))
        scene.fogEndDistance = CGFloat(max(6000, size * 0.55))
        scene.fogDensityExponent = 1.4
        scene.fogColor = biome == .urban ? NSColor(srgbRed: 0.84, green: 0.88, blue: 0.91, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.88, blue: 0.95, alpha: 1)
    }

    static func makeSun() -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.intensity = 1350
        light.color = NSColor(srgbRed: 1, green: 0.96, blue: 0.88, alpha: 1)
        light.castsShadow = true
        light.shadowMode = .forward
        light.shadowSampleCount = 8
        light.shadowRadius = 2.5
        light.shadowMapSize = CGSize(width: 2048, height: 2048)
        light.orthographicScale = 45
        light.zNear = 1
        light.zFar = 600
        light.shadowColor = NSColor(white: 0, alpha: 0.55)
        light.automaticallyAdjustsShadowProjection = false
        let node = SCNNode()
        node.name = "sun"
        node.light = light
        // Afternoon sun from the south-west, ~40° high.
        node.simdOrientation = simd_quatf(angle: Float.pi * 0.78, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -0.70, axis: SIMD3(1, 0, 0))
        return node
    }

    // MARK: - Terrain colouring

    static func groundColor(biome: RouteRecord.Biome, elevation: Double, slope: Float, x: Double, y: Double,
                            water: Double?, roadDistance: Double?) -> SIMD4<Float> {
        let n = Float(TerrainModel.fbm(x / 90, y / 90, octaves: 3, seed: 41)) // -1…1
        let patch = Float(TerrainModel.fbm(x / 400, y / 400, octaves: 2, seed: 77))
        var c: SIMD4<Float>
        switch biome {
        case .alpine:
            let meadow = SceneMath.mix(SceneMath.rgba(0x5F8A3A), SceneMath.rgba(0x46702C), 0.5 + 0.5 * patch)
            let forest = SceneMath.rgba(0x2E4A26)
            let alpineGrass = SceneMath.mix(SceneMath.rgba(0x6F8A45), SceneMath.rgba(0x93A060), 0.5 + 0.5 * n)
            let scree = SceneMath.mix(SceneMath.rgba(0x9C978C), SceneMath.rgba(0x7E786E), 0.5 + 0.5 * n)
            let rock = SceneMath.mix(SceneMath.rgba(0x5F5B55), SceneMath.rgba(0x7A746B), 0.5 + 0.5 * n)
            let snow = SceneMath.rgba(0xF3F6FA)
            let e = Float(elevation)
            // Dark conifer forest patches on the lower slopes.
            c = SceneMath.mix(meadow, forest, (patch - 0.05) * 3 * (e < 1950 ? 1 : 0))
            c = SceneMath.mix(c, alpineGrass, (e - 2000 - 150 * n) / 400)
            // Scree fans and bare rock on steep ground; more of both higher up.
            c = SceneMath.mix(c, scree, (patch + 0.15) * 2.5 * (e > 2300 ? 1 : 0) * min(1, (e - 2300) / 300))
            c = SceneMath.mix(c, rock, (slope - 0.42 + (e - 2600) / 3000) / 0.18)
            c = SceneMath.mix(c, snow, (e - 2900 - 150 * patch) / 220 * (slope < 0.6 ? 1 : 0.25))
        case .coastal:
            let scrub = SceneMath.mix(SceneMath.rgba(0x7A8A48), SceneMath.rgba(0x5E7038), 0.5 + 0.5 * patch)
            c = SceneMath.mix(scrub, SceneMath.rgba(0xA89C82), (slope - 0.5) / 0.25)
        case .urban:
            let park = SceneMath.mix(SceneMath.rgba(0x5F8A3E), SceneMath.rgba(0x4C7432), 0.5 + 0.5 * n)
            c = SceneMath.mix(park, SceneMath.rgba(0x8E8D88), patch * 1.2 - 0.1)
        case .forest:
            c = SceneMath.mix(SceneMath.rgba(0x4C6E2E), SceneMath.rgba(0x3A5A24), 0.5 + 0.5 * patch)
        case .countryside, .lakes:
            let field1 = SceneMath.rgba(0x6E9A3E), field2 = SceneMath.rgba(0xA9A75E), field3 = SceneMath.rgba(0x4E7A30)
            c = SceneMath.mix(field1, field2, patch * 1.6)
            c = SceneMath.mix(c, field3, -patch * 1.6)
            c = SceneMath.mix(c, SceneMath.rgba(0x8A7A5A), (slope - 0.55) / 0.25)
        }
        if let w = water {
            if elevation < w + 2.5 { c = SceneMath.mix(SceneMath.rgba(0xD7C9A2), c, Float((elevation - w) / 2.5)) }
        }
        if let rd = roadDistance, rd < 9 {
            // Worn verge next to the tarmac.
            c = SceneMath.mix(SceneMath.rgba(0x7A6A52), c, Float((rd - 5.5) / 3.5))
        }
        let shade = 1 + 0.08 * n
        return SIMD4(c.x * shade, c.y * shade, c.z * shade, 1)
    }

    private static let groundDetail = ProceduralTextures.groundDetail()

    static func terrainMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = groundDetail
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 8
        m.isDoubleSided = true
        return m
    }

    // MARK: - Far terrain (whole DEM area, coarse, with a hole along the road)

    static func farTerrain(route: Route, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let size = max(terrain.width, terrain.depth)
        let n = max(64, min(240, Int(size / 55)))
        var mesh = MeshData()
        var near = [Bool](repeating: false, count: n * n)
        var heights = [Double](repeating: 0, count: n * n)
        let sx = terrain.width / Double(n - 1), sy = terrain.depth / Double(n - 1)
        for j in 0..<n {
            for i in 0..<n {
                let x = terrain.minX + Double(i) * sx, y = terrain.minY + Double(j) * sy
                var h = terrain.naturalHeight(x: x, y: y)
                if let hit = terrain.nearestRoad(x: x, y: y, maxDistance: corridorHole) {
                    near[j * n + i] = true
                    h = min(h, hit.elevation) - 4
                }
                // Skirt the outer rim down so the world edge never shows daylight underneath.
                if i == 0 || j == 0 || i == n - 1 || j == n - 1 { h -= 60 }
                heights[j * n + i] = h
                mesh.addVertex(frame.point(x: x, y: y, elevation: h), uv: SIMD2(Float(x / 23), Float(y / 23)))
            }
        }
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = j * n + i, b = a + 1, c = a + n + 1, d = a + n
                if near[a] || near[b] || near[c] || near[d] { continue }
                mesh.addQuad(UInt32(a), UInt32(d), UInt32(c), UInt32(b))
            }
        }
        mesh.computeNormals()
        let water = terrain.waterLevel
        for k in 0..<(n * n) {
            let ny = mesh.normals[k * 3 + 1]
            let i = k % n, j = k / n
            let x = terrain.minX + Double(i) * sx, y = terrain.minY + Double(j) * sy
            let c = groundColor(biome: route.record.biome, elevation: heights[k], slope: 1 - ny, x: x, y: y, water: water, roadDistance: nil)
            mesh.colors.replaceSubrange((k * 4)..<(k * 4 + 4), with: [c.x, c.y, c.z, c.w])
        }
        let node = SCNNode(geometry: mesh.geometry(materials: [terrainMaterial()]))
        node.name = "terrain-far"
        node.castsShadow = false
        return node
    }

    // MARK: - Corridor terrain (fine, aligned with the road)

    static func corridorTerrain(route: Route, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let offsets = corridorOffsets.reversed().map { -$0 } + corridorOffsets
        let cols = offsets.count + 2                       // + skirt on each side
        let step = 6.0
        let rows = Int(route.length / step) + 1
        var mesh = MeshData()
        var vertexHeights: [Double] = []
        var vertexRoadDist: [Double?] = []
        // A vertex is "owned" by this stretch of road unless another part of the
        // route (the next switchback, the other side of a hairpin) is nearer.
        // Only triangles touching an owned vertex are kept, so corridor strips of
        // stacked hairpins never draw over each other's roads.
        var owned: [Bool] = []
        vertexHeights.reserveCapacity(rows * cols)

        for r in 0..<rows {
            let d = min(Double(r) * step, route.length)
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            var rowHeights: [Double] = []
            var rowOwned: [Bool] = []
            for o in offsets {
                let q = p + right * o
                let h = terrain.height(x: q.x, y: q.y)
                // Only a road nearer than our own (|o| away) can claim this vertex.
                let hit = terrain.nearestRoad(x: q.x, y: q.y, maxDistance: abs(o) + 5)
                var mine = true
                if let hit {
                    // Ours unless some *other* part of the road (not just this bend) is nearer than our own row.
                    var along = abs(hit.routeDistance - d)
                    if route.isLoop { along = min(along, route.length - along) }
                    mine = along < 20 || hit.distance > abs(o) - 2
                }
                rowHeights.append(h)
                rowOwned.append(mine)
                owned.append(mine)
                vertexRoadDist.append(hit?.distance)
                mesh.addVertex(frame.point(q, h), uv: SIMD2(Float(q.x / 23), Float(q.y / 23)))
                vertexHeights.append(h)
            }
            for (side, o) in [(-1.0, offsets.first!), (1.0, offsets.last!)] {
                let q = p + right * (o + side * 2)
                let h = (side < 0 ? rowHeights.first! : rowHeights.last!) - 14
                mesh.addVertex(frame.point(q, h), uv: SIMD2(Float(q.x / 23), Float(q.y / 23)))
                vertexHeights.append(h)
                vertexRoadDist.append(nil)
                owned.append(side < 0 ? rowOwned.first! : rowOwned.last!)
            }
        }
        func tri(_ a: Int, _ b: Int, _ c: Int) {
            if owned[a] || owned[b] || owned[c] { mesh.addTriangle(UInt32(a), UInt32(b), UInt32(c)) }
        }
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            tri(a, b, c)
            tri(a, c, d)
        }
        let roadGap = corridorOffsets.count - 1            // column index of −5.5; next column is +5.5
        let skirtL = offsets.count, skirtR = offsets.count + 1
        let lastCol = offsets.count - 1
        for r in 0..<(rows - 1) {
            let a0 = r * cols, b0 = (r + 1) * cols
            for c in 0..<lastCol where c != roadGap {
                quad(a0 + c, a0 + c + 1, b0 + c + 1, b0 + c)
            }
            // Skirts only where the outer edge is ours (never drop a wall into a neighbouring switchback).
            if owned[a0] && owned[b0] { quad(a0 + skirtL, a0, b0, b0 + skirtL) }
            if owned[a0 + lastCol] && owned[b0 + lastCol] { quad(a0 + lastCol, a0 + skirtR, b0 + skirtR, b0 + lastCol) }
        }
        mesh.computeNormals()
        let water = terrain.waterLevel
        for k in 0..<mesh.vertexCount {
            let ny = mesh.normals[k * 3 + 1]
            let x = Double(mesh.positions[k * 3]), y = -Double(mesh.positions[k * 3 + 2])
            let c = groundColor(biome: route.record.biome, elevation: vertexHeights[k], slope: 1 - abs(ny), x: x, y: y,
                                water: water, roadDistance: vertexRoadDist[k])
            mesh.colors.replaceSubrange((k * 4)..<(k * 4 + 4), with: [c.x, c.y, c.z, c.w])
        }
        let node = SCNNode(geometry: mesh.geometry(materials: [terrainMaterial()]))
        node.name = "terrain-corridor"
        return node
    }

    // MARK: - Road

    static func roadMaterial(_ surface: Surface, urban: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        switch surface {
        case .asphalt: m.diffuse.contents = ProceduralTextures.asphalt(urban: urban)
        case .cobbles: m.diffuse.contents = ProceduralTextures.cobbles()
        case .gravel: m.diffuse.contents = ProceduralTextures.gravel()
        }
        m.roughness.contents = surface == .cobbles ? 0.7 : 0.88
        m.metalness.contents = 0.0
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 16
        return m
    }

    static func road(route: Route, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let profile: [(offset: Double, lift: Double, u: Float)] = [
            (-5.5, -0.12, 0), (-3.6, 0.03, Float(ProceduralTextures.verge)), (0, 0.06, 0.5),
            (3.6, 0.03, Float(1 - ProceduralTextures.verge)), (5.5, -0.12, 1),
        ]
        let surfaces: [Surface] = [.asphalt, .cobbles, .gravel]
        let step = 2.0
        let rows = Int(route.length / step) + 1
        var mesh = MeshData()
        mesh.elements = [[], [], []]
        for r in 0..<rows {
            let d = min(Double(r) * step, route.length)
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            let e = route.elevation(at: d)
            for v in profile {
                let q = p + right * v.offset
                mesh.addVertex(frame.point(q, e + v.lift), uv: SIMD2(v.u, Float(d / 9.0)))
            }
            guard r > 0 else { continue }
            let el = surfaces.firstIndex(of: route.surface(at: d - step / 2)) ?? 0
            let a0 = UInt32((r - 1) * profile.count), b0 = UInt32(r * profile.count)
            for c in 0..<UInt32(profile.count - 1) {
                mesh.addQuad(a0 + c, a0 + c + 1, b0 + c + 1, b0 + c, element: el)
            }
        }
        mesh.computeNormals()
        let urban = route.record.biome == .urban
        let geo = mesh.geometry(materials: surfaces.map { roadMaterial($0, urban: urban) }, includeColors: false)
        let node = SCNNode(geometry: geo)
        node.name = "road"
        return node
    }

    static func guardrails(route: Route, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        var mesh = MeshData()
        let step = 4.0
        let steel = SIMD4<Float>(0.62, 0.64, 0.66, 1)
        for side in [-1.0, 1.0] {
            var prev: (top: UInt32, bottom: UInt32)?
            var d = 0.0
            while d <= route.length {
                let p = route.position(at: d)
                let dir = route.direction(at: d)
                let right = LocalPoint(x: dir.y, y: -dir.x)
                let e = route.elevation(at: d)
                let probe = p + right * (side * 14)
                let drop = e - terrain.height(x: probe.x, y: probe.y)
                if drop > 3.5, route.record.biome == .alpine || route.record.biome == .coastal || route.record.biome == .lakes {
                    let q = p + right * (side * 5.9)
                    let bottom = mesh.addVertex(frame.point(q, e + 0.35), normal: SIMD3(0, 0, 1), color: steel, uv: SIMD2(0, Float(d)))
                    let top = mesh.addVertex(frame.point(q, e + 0.85), normal: SIMD3(0, 0, 1), color: steel, uv: SIMD2(1, Float(d)))
                    if let prev { mesh.addQuad(prev.bottom, bottom, top, prev.top) }
                    prev = (top, bottom)
                } else {
                    prev = nil
                }
                d += step
            }
        }
        guard mesh.vertexCount > 0 else { return SCNNode() }
        mesh.computeNormals()
        let m = SceneMath.material(NSColor(white: 0.55, alpha: 1), roughness: 0.45, metalness: 0.6)
        m.isDoubleSided = true
        let node = SCNNode(geometry: mesh.geometry(materials: [m]))
        node.name = "guardrails"
        return node
    }

    static func water(level: Double, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(terrain.width * 1.4), height: CGFloat(terrain.depth * 1.4))
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.10, green: 0.33, blue: 0.48, alpha: 1)
        m.roughness.contents = 0.08
        m.metalness.contents = 0.25
        m.transparency = 0.92
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        node.simdPosition = SIMD3(Float((terrain.minX + terrain.maxX) / 2), Float(level - frame.baseElevation),
                                  Float(-(terrain.minY + terrain.maxY) / 2))
        node.name = "water"
        node.castsShadow = false
        return node
    }

    // MARK: - Vegetation

    enum TreeKind: CaseIterable { case conifer, deciduous, poplar, palm, olive }

    static func treePrototype(_ kind: TreeKind) -> SCNNode {
        let node = SCNNode()
        let bark = SceneMath.material(NSColor(srgbRed: 0.36, green: 0.27, blue: 0.19, alpha: 1), roughness: 0.9, lit: .lambert)
        func leaves(_ hex: UInt32) -> SCNMaterial {
            SceneMath.material(NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1), roughness: 0.9, lit: .lambert)
        }
        switch kind {
        case .conifer:
            let trunk = SCNCylinder(radius: 0.25, height: 3)
            trunk.radialSegmentCount = 6
            trunk.materials = [bark]
            let t = SCNNode(geometry: trunk)
            t.simdPosition = SIMD3(0, 1.5, 0)
            node.addChildNode(t)
            for (i, (r, h, y)) in [(2.6, 6.0, 4.6), (2.0, 5.0, 7.4), (1.3, 4.0, 9.8)].enumerated() {
                let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(r), height: CGFloat(h))
                cone.radialSegmentCount = 7
                cone.materials = [leaves(i == 0 ? 0x24452A : 0x2B5232)]
                let c = SCNNode(geometry: cone)
                c.simdPosition = SIMD3(0, Float(y), 0)
                node.addChildNode(c)
            }
        case .deciduous, .olive:
            let olive = kind == .olive
            let trunk = SCNCylinder(radius: olive ? 0.3 : 0.28, height: olive ? 2.2 : 3.5)
            trunk.radialSegmentCount = 6
            trunk.materials = [bark]
            let t = SCNNode(geometry: trunk)
            t.simdPosition = SIMD3(0, olive ? 1.1 : 1.75, 0)
            node.addChildNode(t)
            for k in 0..<3 {
                let s = SCNSphere(radius: olive ? 1.6 : 2.6 - CGFloat(k) * 0.3)
                s.segmentCount = 8
                let greens: [UInt32] = [0x3E6B2A, 0x4A7A30, 0x55813A]
                s.materials = [leaves(olive ? 0x7E8C5A : greens[k])]
                let n = SCNNode(geometry: s)
                n.simdPosition = SIMD3(Float(k == 1 ? 1.0 : (k == 2 ? -0.9 : 0)), olive ? 3.0 : 5.0 + Float(k) * 0.6, Float(k == 2 ? 0.7 : 0))
                n.simdScale = SIMD3(1, olive ? 0.7 : 0.9, 1)
                node.addChildNode(n)
            }
        case .poplar:
            let trunk = SCNCylinder(radius: 0.2, height: 2)
            trunk.materials = [bark]
            let t = SCNNode(geometry: trunk)
            t.simdPosition = SIMD3(0, 1, 0)
            node.addChildNode(t)
            let s = SCNSphere(radius: 1.6)
            s.segmentCount = 8
            s.materials = [leaves(0x3F6E2C)]
            let n = SCNNode(geometry: s)
            n.simdPosition = SIMD3(0, 7, 0)
            n.simdScale = SIMD3(1, 3.6, 1)
            node.addChildNode(n)
        case .palm:
            let trunk = SCNCylinder(radius: 0.22, height: 9)
            trunk.radialSegmentCount = 6
            trunk.materials = [bark]
            let t = SCNNode(geometry: trunk)
            t.simdPosition = SIMD3(0, 4.5, 0)
            node.addChildNode(t)
            for k in 0..<6 {
                let leaf = SCNBox(width: 0.6, height: 0.08, length: 4.2, chamferRadius: 0)
                leaf.materials = [leaves(0x4E7D2E)]
                let l = SCNNode(geometry: leaf)
                l.simdPosition = SIMD3(0, 9, 0)
                l.simdOrientation = simd_quatf(angle: Float(k) * .pi / 3, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: 0.35, axis: SIMD3(1, 0, 0))
                l.simdPivot = float4x4(translation: SIMD3(0, 0, 2.1))
                node.addChildNode(l)
            }
        }
        return node.flattenedClone()
    }

    static func vegetation(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let biome = route.record.biome
        let kinds: [(TreeKind, Double)]
        let density: Double
        switch biome {
        case .alpine: kinds = [(.conifer, 0.85), (.deciduous, 0.15)]; density = 1.6
        case .forest: kinds = [(.deciduous, 0.65), (.poplar, 0.15), (.conifer, 0.2)]; density = 4.5
        case .countryside: kinds = [(.deciduous, 0.6), (.poplar, 0.4)]; density = 0.8
        case .coastal: kinds = [(.olive, 0.5), (.palm, 0.2), (.conifer, 0.3)]; density = 0.9
        case .lakes: kinds = [(.deciduous, 0.55), (.conifer, 0.35), (.poplar, 0.1)]; density = 1.4
        case .urban: kinds = [(.deciduous, 0.8), (.poplar, 0.2)]; density = 0.55
        }
        let protos = Dictionary(uniqueKeysWithValues: TreeKind.allCases.map { ($0, treePrototype($0)) })
        let container = SCNNode()
        container.name = "vegetation"
        let chunkLength = 1500.0
        var chunk = SCNNode()
        var chunkStart = 0.0
        let treeline = 2050.0
        var d = 0.0
        while d < route.length {
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            let tries = Int(density * 2 + rng.range(0, 1))
            for _ in 0..<tries {
                // Exponential falloff: dense near the road, thinning into the distance.
                let lateral = (biome == .forest ? 7.5 : 10) + min(900, -log(max(rng.unit(), 1e-6)) * (biome == .forest ? 60 : 140))
                let side = rng.chance(0.5) ? 1.0 : -1.0
                let q = p + right * (side * lateral) + dir * rng.range(-6, 6)
                let forest = TerrainModel.fbm(q.x / 350, q.y / 350, octaves: 2, seed: 99)
                if forest < (biome == .forest ? -0.45 : -0.05) { continue }
                if terrain.nearestRoad(x: q.x, y: q.y, maxDistance: 9) != nil { continue }
                let h = terrain.height(x: q.x, y: q.y)
                if let w = terrain.waterLevel, h < w + 1.2 { continue }
                if biome == .alpine, h > treeline + 120 * forest { continue }
                let hx = terrain.height(x: q.x + 4, y: q.y), hy = terrain.height(x: q.x, y: q.y + 4)
                if abs(hx - h) > 3.6 || abs(hy - h) > 3.6 { continue } // too steep / cliff
                var pick = rng.unit()
                var kind = kinds[0].0
                for (k, w) in kinds {
                    if pick < w { kind = k; break }
                    pick -= w
                }
                if biome == .alpine, h > 1500 { kind = .conifer }
                let tree = protos[kind]!.clone()
                tree.simdPosition = frame.point(q, h - 0.3)
                let s = rng.float(0.7, 1.35)
                tree.simdScale = SIMD3(s, s * rng.float(0.85, 1.2), s)
                tree.simdEulerAngles = SIMD3(0, rng.float(0, 6.28), 0)
                chunk.addChildNode(tree)
            }
            d += 10
            if d - chunkStart > chunkLength || d >= route.length {
                if !chunk.childNodes.isEmpty {
                    let flat = chunk.flattenedClone()
                    flat.castsShadow = true
                    container.addChildNode(flat)
                }
                chunk = SCNNode()
                chunkStart = d
            }
        }
        // Boulders above the treeline.
        if biome == .alpine {
            let rock = SCNSphere(radius: 1)
            rock.segmentCount = 6
            rock.materials = [SceneMath.material(NSColor(white: 0.55, alpha: 1), roughness: 0.95, lit: .lambert)]
            let rocks = SCNNode()
            var dd = 0.0
            while dd < route.length {
                let p = route.position(at: dd)
                if route.elevation(at: dd) > treeline - 100, rng.chance(0.5) {
                    let dir = route.direction(at: dd)
                    let right = LocalPoint(x: dir.y, y: -dir.x)
                    let q = p + right * ((rng.chance(0.5) ? 1 : -1) * rng.range(8, 70))
                    if terrain.nearestRoad(x: q.x, y: q.y, maxDistance: 8) == nil {
                        let n = SCNNode(geometry: rock)
                        n.simdPosition = frame.point(q, terrain.height(x: q.x, y: q.y) - 0.3)
                        n.simdScale = SIMD3(rng.float(0.4, 2.2), rng.float(0.3, 1.2), rng.float(0.4, 2))
                        rocks.addChildNode(n)
                    }
                }
                dd += 25
            }
            if !rocks.childNodes.isEmpty { container.addChildNode(rocks.flattenedClone()) }
        }
        return container
    }

    // MARK: - Buildings

    static func buildings(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let biome = route.record.biome
        let container = SCNNode()
        container.name = "buildings"
        let walls: [UInt32]
        let roofs: [UInt32]
        switch biome {
        case .alpine: walls = [0x8B5E3C, 0xE9E1D0, 0x7A4E2D, 0xF1EADB]; roofs = [0x3B3B3B, 0x5A4632]
        case .coastal, .lakes: walls = [0xE8B38A, 0xF2D49B, 0xE4C9A8, 0xD98E6A, 0xF5E6CF]; roofs = [0xA7532E, 0x8F4A2C]
        case .urban: walls = [0xD8D2C4, 0xB8A48C, 0x9A8E80, 0xC9B79C, 0xE2DED5, 0x8C6E5A]; roofs = [0x4A4A4A, 0x5C5C5C]
        default: walls = [0xC4A484, 0xE6DCC8, 0x9C5B3C, 0xD8C6A8]; roofs = [0x6B3A2A, 0x4A4A4A]
        }
        func mat(_ hex: UInt32, _ rough: CGFloat = 0.85) -> SCNMaterial {
            SceneMath.material(NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1), roughness: rough, lit: .lambert)
        }
        let wallMats = walls.map { mat($0) }
        let roofMats = roofs.map { mat($0, 0.7) }
        let windowMat = mat(0x2A3440, 0.2)

        var chunk = SCNNode()
        var chunkStart = 0.0
        var d = 0.0
        let spacing = biome == .urban ? 16.0 : 22.0
        while d < route.length {
            // Settlements: towns at the ends of climbs, villages scattered, cities everywhere.
            let townFactor: Double
            switch biome {
            case .urban: townFactor = 0.85
            case .alpine:
                let ends = min(d, route.length - d)
                townFactor = ends < 1200 ? 0.55 : 0.03
            case .coastal, .lakes: townFactor = 0.35
            default: townFactor = 0.10 + 0.25 * max(0, TerrainModel.fbm(d / 2000, 0, octaves: 2, seed: 5))
            }
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            for side in [-1.0, 1.0] where rng.chance(townFactor) {
                let w = rng.range(7, biome == .urban ? 18 : 12), depth = rng.range(7, biome == .urban ? 16 : 11)
                let floors = biome == .urban ? Int(rng.range(2, 7)) : Int(rng.range(1, 3))
                let height = Double(floors) * 3.1 + 1
                let lateral = 9 + depth / 2 + rng.range(0, biome == .urban ? 4 : 18)
                let q = p + right * (side * lateral)
                // Another road (e.g. the next switchback) running through the plot.
                if let hit = terrain.nearestRoad(x: q.x, y: q.y, maxDistance: lateral - 2), hit.distance < max(w, depth) / 2 + 6 {
                    continue
                }
                let h0 = terrain.height(x: q.x, y: q.y)
                if let wl = terrain.waterLevel, h0 < wl + 1 { continue }
                let corners = [(-w / 2, -depth / 2), (w / 2, -depth / 2), (-w / 2, depth / 2), (w / 2, depth / 2)].map { c -> Double in
                    let cq = q + dir * c.0 + right * c.1
                    return terrain.height(x: cq.x, y: cq.y)
                }
                let lo = corners.min()!, hi = corners.max()!
                if hi - lo > 6 { continue }
                let house = SCNNode()
                let box = SCNBox(width: CGFloat(w), height: CGFloat(height + (hi - lo)), length: CGFloat(depth), chamferRadius: 0)
                box.materials = [rng.pick(wallMats)]
                let body = SCNNode(geometry: box)
                body.simdPosition = SIMD3(0, Float((height + (hi - lo)) / 2), 0)
                house.addChildNode(body)
                // Window band.
                let band = SCNBox(width: CGFloat(w) + 0.04, height: 1.0, length: CGFloat(depth) * 0.7, chamferRadius: 0)
                band.materials = [windowMat]
                for f in 0..<floors {
                    let b = SCNNode(geometry: band)
                    b.simdPosition = SIMD3(0, Float(hi - lo) + Float(f) * 3.1 + 2.0, 0)
                    house.addChildNode(b)
                }
                if biome != .urban || rng.chance(0.3) {
                    let roof = SCNPyramid(width: CGFloat(w) * 1.1, height: CGFloat(min(w, depth) * 0.45), length: CGFloat(depth) * 1.1)
                    roof.materials = [rng.pick(roofMats)]
                    let r = SCNNode(geometry: roof)
                    r.simdPosition = SIMD3(0, Float(height + (hi - lo)), 0)
                    house.addChildNode(r)
                }
                house.simdPosition = frame.point(q, lo - 0.3)
                house.simdOrientation = simd_quatf(angle: frame.yaw(dir), axis: SIMD3(0, 1, 0))
                chunk.addChildNode(house)
            }
            d += spacing * rng.range(0.7, 1.3)
            if d - chunkStart > 1500 || d >= route.length {
                if !chunk.childNodes.isEmpty { container.addChildNode(chunk.flattenedClone()) }
                chunk = SCNNode()
                chunkStart = d
            }
        }
        return container
    }

    // MARK: - Crowds

    static func crowds(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let container = SCNNode()
        container.name = "crowds"
        let shirtColors: [UInt32] = [0xD62828, 0xF77F00, 0xFCBF49, 0x2A9D8F, 0x264653, 0xE76F51, 0xFFFFFF, 0x1D3557, 0x8338EC, 0x06D6A0, 0xFFD60A]
        let skin: [UInt32] = [0xF1C27D, 0xC68E6A, 0x8D5A3B, 0xE0AC8B, 0x5C3A21]
        func mat(_ hex: UInt32) -> SCNMaterial {
            SceneMath.material(NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1), roughness: 0.8, lit: .lambert)
        }
        let bodies = shirtColors.map { c -> SCNGeometry in
            let g = SCNCapsule(capRadius: 0.21, height: 1.35)
            g.radialSegmentCount = 6
            g.heightSegmentCount = 1
            g.materials = [mat(c)]
            return g
        }
        let heads = skin.map { c -> SCNGeometry in
            let g = SCNSphere(radius: 0.12)
            g.segmentCount = 6
            g.materials = [mat(c)]
            return g
        }
        let flagColors: [UInt32] = [0xD62828, 0x1D3557, 0xFCBF49, 0x2A9D8F, 0xFFFFFF]
        let flagMats = flagColors.map { mat($0) }

        // Crowd zones: the final 3 km of big climbs, and the last 400 m before the line.
        var zones: [(start: Double, end: Double, peakAtEnd: Bool)] = route.climbs
            .filter { $0.category <= .cat3 }
            .map { (max($0.startDistance, $0.endDistance - 3000), $0.endDistance + 60, true) }
        zones.append((max(0, route.length - 400), route.length, true))
        if route.isLoop { zones.append((0, 150, false)) }

        for zone in zones {
            let node = SCNNode()
            var d = zone.start
            while d < min(zone.end, route.length) {
                let progress = (d - zone.start) / max(zone.end - zone.start, 1)
                let densityGap = zone.peakAtEnd ? 3.8 - 2.9 * progress : 1.5
                let p = route.position(at: d)
                let dir = route.direction(at: d)
                let right = LocalPoint(x: dir.y, y: -dir.x)
                let e = route.elevation(at: d)
                for side in [-1.0, 1.0] where rng.chance(0.8) {
                    let q = p + right * (side * rng.range(6.3, 8.6))
                    let h = max(terrain.height(x: q.x, y: q.y), e - 0.2)
                    let person = SCNNode()
                    let b = SCNNode(geometry: rng.pick(bodies))
                    b.simdPosition = SIMD3(0, 0.88, 0)
                    person.addChildNode(b)
                    let hd = SCNNode(geometry: rng.pick(heads))
                    hd.simdPosition = SIMD3(0, 1.68, 0)
                    person.addChildNode(hd)
                    if rng.chance(0.12) {
                        let pole = SCNCylinder(radius: 0.015, height: 1.6)
                        pole.materials = [mat(0xDDDDDD)]
                        let pn = SCNNode(geometry: pole)
                        pn.simdPosition = SIMD3(0.25, 2.0, 0)
                        person.addChildNode(pn)
                        let flag = SCNBox(width: 0.02, height: 0.5, length: 0.8, chamferRadius: 0)
                        flag.materials = [rng.pick(flagMats)]
                        let fn = SCNNode(geometry: flag)
                        fn.simdPosition = SIMD3(0.25, 2.55, 0.4)
                        person.addChildNode(fn)
                    }
                    person.simdPosition = frame.point(q, h)
                    person.simdOrientation = simd_quatf(angle: frame.yaw(LocalPoint(x: -right.x * side, y: -right.y * side)), axis: SIMD3(0, 1, 0))
                    node.addChildNode(person)
                }
                d += max(0.9, densityGap * rng.range(0.6, 1.4))
            }
            if !node.childNodes.isEmpty { container.addChildNode(node.flattenedClone()) }
        }
        return container
    }

    // MARK: - Signage

    static func arch(text: String, style: ProceduralTextures.BannerStyle, at d: Double, route: Route, frame: WorldFrame) -> SCNNode {
        let node = SCNNode()
        let p = route.position(at: d)
        let dir = route.direction(at: d)
        let e = route.elevation(at: d)
        let postMat = SceneMath.material(NSColor(white: 0.92, alpha: 1), roughness: 0.4, metalness: 0.3)
        for side in [-1.0, 1.0] {
            let post = SCNCylinder(radius: 0.18, height: 6.6)
            post.materials = [postMat]
            let pn = SCNNode(geometry: post)
            pn.simdPosition = SIMD3(Float(side * 6.6), 3.3, 0)
            node.addChildNode(pn)
        }
        let bannerMat = SCNMaterial()
        bannerMat.lightingModel = .physicallyBased
        bannerMat.diffuse.contents = ProceduralTextures.banner(text, style: style)
        bannerMat.roughness.contents = 0.6
        bannerMat.emission.contents = NSColor(white: 0.12, alpha: 1)
        let plain = SceneMath.material(NSColor(white: 0.95, alpha: 1))
        let box = SCNBox(width: 13.6, height: 1.8, length: 0.35, chamferRadius: 0.05)
        box.materials = [bannerMat, plain, bannerMat, plain, plain, plain]   // front, right, back, left, top, bottom
        let bn = SCNNode(geometry: box)
        bn.simdPosition = SIMD3(0, 6.2, 0)
        node.addChildNode(bn)
        node.simdPosition = frame.point(p, e)
        node.simdOrientation = simd_quatf(angle: frame.yaw(dir), axis: SIMD3(0, 1, 0))
        return node
    }

    static func signage(route: Route, frame: WorldFrame) -> SCNNode {
        let container = SCNNode()
        container.name = "signage"
        if route.isLoop {
            container.addChildNode(arch(text: "FINISH", style: .finish, at: 0, route: route, frame: frame))
        } else {
            container.addChildNode(arch(text: "DÉPART", style: .start, at: min(15, route.length * 0.1), route: route, frame: frame))
            container.addChildNode(arch(text: "ARRIVÉE", style: .finish, at: route.length - 1, route: route, frame: frame))
        }
        for climb in route.climbs where climb.category <= .cat3 {
            if !route.isLoop, climb.endDistance > route.length - 120 { continue } // finish arch already marks it
            container.addChildNode(arch(text: "KOM · \(climb.name.uppercased())", style: .kom, at: climb.endDistance, route: route, frame: frame))
        }
        // French-style kilometre markers counting down to each summit.
        let postMat = SceneMath.material(NSColor(white: 0.95, alpha: 1), roughness: 0.6)
        for climb in route.climbs where climb.length >= 2500 {
            let kms = Int(climb.length / 1000)
            for k in 1...kms {
                let d = climb.endDistance - Double(k) * 1000
                guard d > climb.startDistance else { continue }
                let next = (route.elevation(at: d + 1000) - route.elevation(at: d)) / 10
                let plate = SCNMaterial()
                plate.diffuse.contents = ProceduralTextures.marker([String(climb.name.prefix(14)), "\(k) km", String(format: "%.0f %%", next)],
                                                                   accent: climb.category <= .cat1 ? 0xD62828 : 0xF4D35E)
                plate.lightingModel = .lambert
                let box = SCNBox(width: 0.55, height: 0.7, length: 0.12, chamferRadius: 0.03)
                box.materials = [plate, postMat, plate, postMat, postMat, postMat]
                let p = route.position(at: d)
                let dir = route.direction(at: d)
                let right = LocalPoint(x: dir.y, y: -dir.x)
                let q = p + right * 6.4
                let n = SCNNode(geometry: box)
                n.simdPosition = frame.point(q, route.elevation(at: d) + 0.75)
                n.simdOrientation = simd_quatf(angle: frame.yaw(dir), axis: SIMD3(0, 1, 0))
                container.addChildNode(n)
            }
        }
        // Cobbled sector signs.
        for s in route.record.surfaces where s.surface != .asphalt {
            let d = s.startMeters
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            let mat = SCNMaterial()
            mat.diffuse.contents = ProceduralTextures.banner(s.name.uppercased(), style: .sector, width: 768, height: 192)
            mat.lightingModel = .lambert
            let board = SCNBox(width: 3.2, height: 0.8, length: 0.08, chamferRadius: 0)
            board.materials = [mat, postMat, mat, postMat, postMat, postMat]
            let n = SCNNode(geometry: board)
            let q = p - right * 6.8
            n.simdPosition = frame.point(q, route.elevation(at: d) + 2.2)
            n.simdOrientation = simd_quatf(angle: frame.yaw(dir), axis: SIMD3(0, 1, 0))
            container.addChildNode(n)
        }
        return container
    }
}

extension float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t.x, t.y, t.z, 1)
    }
}
