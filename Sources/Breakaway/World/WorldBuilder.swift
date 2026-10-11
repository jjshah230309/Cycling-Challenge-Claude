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
        root.addChildNode(SceneryBuilder.roadside(route: route, terrain: terrain, frame: frame))
        if let w = terrain.waterLevel {
            root.addChildNode(water(level: w, terrain: terrain, frame: frame))
        }
        progress(0.68, "Forests & villages")
        var rng = SceneRandom(seed: UInt64(StableHash.hex(route.id), radix: 16) ?? 7)
        root.addChildNode(SceneryBuilder.vegetation(route: route, terrain: terrain, frame: frame, rng: &rng))
        root.addChildNode(SceneryBuilder.grass(route: route, terrain: terrain, frame: frame, rng: &rng))
        root.addChildNode(SceneryBuilder.buildings(route: route, terrain: terrain, frame: frame, rng: &rng))
        progress(0.85, "Crowds & signage")
        root.addChildNode(SceneryBuilder.crowds(route: route, terrain: terrain, frame: frame, rng: &rng))
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
        light.shadowRadius = 2.0
        light.shadowMapSize = CGSize(width: 4096, height: 4096)
        // Cascaded shadow maps: crisp under the riders, still present on trees and houses far up the road.
        light.shadowCascadeCount = 4
        light.shadowCascadeSplittingFactor = 0.35
        light.maximumShadowDistance = 600
        light.automaticallyAdjustsShadowProjection = true
        light.shadowColor = NSColor(white: 0, alpha: 0.55)
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
    private static let groundNormal = ProceduralTextures.normalMap(size: 256, scale: 8, strength: 2.5, seed: 4)

    static func terrainMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = groundDetail
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 8
        // Fine relief (clods, ruts, grass clumps) lit by the sun.
        m.normal.contents = groundNormal
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.mipFilter = .linear
        m.normal.intensity = 0.7
        m.normal.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
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

    static func water(level: Double, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(terrain.width * 1.4), height: CGFloat(terrain.depth * 1.4))
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: 0.07, green: 0.27, blue: 0.40, alpha: 1)
        m.roughness.contents = 0.06
        m.metalness.contents = 0.35
        m.transparency = 0.94
        // Ripples: a tiling normal map scrolled by the renderer every frame.
        m.normal.contents = ProceduralTextures.normalMap(size: 256, scale: 6, strength: 1.4, seed: 11)
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.intensity = 0.55
        m.normal.contentsTransform = SCNMatrix4MakeScale(CGFloat(terrain.width * 1.4 / 18), CGFloat(terrain.depth * 1.4 / 18), 1)
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
        node.simdPosition = SIMD3(Float((terrain.minX + terrain.maxX) / 2), Float(level - frame.baseElevation),
                                  Float(-(terrain.minY + terrain.maxY) / 2))
        node.name = "water"
        node.castsShadow = false
        return node
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
