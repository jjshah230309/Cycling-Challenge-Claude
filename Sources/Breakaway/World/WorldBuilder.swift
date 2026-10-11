import AppKit
import BreakawayCore
import Foundation
import ModelIO
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
        root.addChildNode(clouds(terrain: terrain, frame: frame))
        let sun = makeSun()
        root.addChildNode(sun)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 430
        ambient.light?.color = NSColor(srgbRed: 0.75, green: 0.82, blue: 0.95, alpha: 1)
        root.addChildNode(ambient)

        progress(0.12, "Valleys & mountains (DEM + satellite imagery)")
        let imagery = TerrainImagery.image(for: route.id)
        let groundMaterial = terrainMaterial(imagery: imagery)
        root.addChildNode(farTerrain(route: route, terrain: terrain, frame: frame, material: groundMaterial, draped: imagery != nil))
        progress(0.35, "Hillsides along the road")
        root.addChildNode(corridorTerrain(route: route, terrain: terrain, frame: frame, material: groundMaterial, draped: imagery != nil))
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

    /// Direction *towards* the sun in scene space (x east, y up, −z north): late morning,
    /// from the south-south-east and ~48° high — the same light the satellite imagery was
    /// captured under, so the photo's baked shading agrees with the real-time shadows.
    static let sunDirection = simd_normalize(SIMD3<Float>(0.32, 0.74, 0.59))

    static func setupEnvironment(scene: SCNScene, biome: RouteRecord.Biome, terrain: TerrainModel) {
        // Physically based clear-sky model (Hosek–Wilkie via ModelIO) for background and image-based light.
        let turbidity: Float = biome == .urban || biome == .countryside ? 0.7 : 0.55
        let sky = MDLSkyCubeTexture(name: "sky", channelEncoding: .uInt8, textureDimensions: vector_int2(512, 512),
                                    turbidity: turbidity, sunElevation: asin(sunDirection.y) / (.pi / 2),
                                    upperAtmosphereScattering: 0.55, groundAlbedo: 0.35)
        sky.sunAzimuth = atan2(sunDirection.x, sunDirection.z)
        if let raw = sky.imageFromTexture()?.takeUnretainedValue() {
            let cube = hazed(skyCube: raw)
            scene.background.contents = cube
            scene.lightingEnvironment.contents = cube
        } else {
            let fallback = ProceduralTextures.sky(biome: biome)
            scene.background.contents = fallback
            scene.lightingEnvironment.contents = fallback
        }
        scene.lightingEnvironment.intensity = 1.25
        // Aerial perspective: distant ridges fade into a pale blue haze.
        let size = max(terrain.width, terrain.depth)
        scene.fogStartDistance = CGFloat(min(1200, size * 0.06))
        scene.fogEndDistance = CGFloat(max(14000, size * 1.1))
        scene.fogDensityExponent = 1.25
        scene.fogColor = biome == .urban ? NSColor(srgbRed: 0.80, green: 0.85, blue: 0.90, alpha: 1)
            : NSColor(srgbRed: 0.74, green: 0.83, blue: 0.93, alpha: 1)
    }

    /// The clear-sky model is very saturated; real summer skies over the mountains carry
    /// haze. Wash each side face of the cube towards white near the horizon.
    static func hazed(skyCube image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard h == w * 6, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let haze = CGColor(srgbRed: 0.86, green: 0.9, blue: 0.95, alpha: 1)
        let clear = CGColor(srgbRed: 0.86, green: 0.9, blue: 0.95, alpha: 0)
        let s = CGFloat(w)
        // Vertical strip order (top to bottom): +X, −X, +Y, −Y, +Z, −Z. CG's origin is bottom-left.
        for face in [0, 1, 4, 5] {
            let top = CGFloat(h) - CGFloat(face) * s, bottom = top - s
            let mid = (top + bottom) / 2
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [clear, haze, haze] as CFArray,
                                  locations: [0, 0.75, 1]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: mid, width: s, height: s / 2))
                ctx.setAlpha(0.55)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: mid), options: [])
                ctx.restoreGState()
            }
        }
        // A light veil over the whole sky dome.
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.93, blue: 0.97, alpha: 0.16))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// A layer of fair-weather cumulus high above the route.
    static func clouds(terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let span = CGFloat(max(terrain.width, terrain.depth) * 3)
        let plane = SCNPlane(width: span, height: span)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = ProceduralTextures.clouds(size: 1024, seed: 21)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(span / 9000, span / 9000, 1)
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.name = "clouds"
        node.simdEulerAngles = SIMD3(.pi / 2, 0, 0)          // face down towards the riders
        node.simdPosition = SIMD3(Float((terrain.minX + terrain.maxX) / 2),
                                  Float(terrain.highestPoint - frame.baseElevation + 1800),
                                  Float(-(terrain.minY + terrain.maxY) / 2))
        node.castsShadow = false
        node.renderingOrder = -5
        return node
    }

    static func makeSun() -> SCNNode {
        let light = SCNLight()
        light.type = .directional
        light.intensity = 1500
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
        light.shadowColor = NSColor(white: 0, alpha: 0.45)
        let node = SCNNode()
        node.name = "sun"
        node.light = light
        // The light shines along the node's −Z, i.e. away from the sun.
        node.simdOrientation = simd_quatf(from: SIMD3(0, 0, -1), to: -sunDirection)
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
    private static let drapedDetail = ProceduralTextures.groundClumps()
    private static let asphaltNormal = ProceduralTextures.normalMap(size: 256, scale: 32, strength: 3.0, seed: 8)
    private static let cobbleNormal = ProceduralTextures.normalMap(fromHeight: ProceduralTextures.cobbles(), strength: 2.5)
    private static let groundNormal = ProceduralTextures.normalMap(size: 256, scale: 8, strength: 2.5, seed: 4)

    /// Texture coordinates into the route's satellite image (north up).
    static func imageryUV(_ terrain: TerrainModel, _ x: Double, _ y: Double) -> SIMD2<Float> {
        SIMD2(Float((x - terrain.minX) / terrain.width), Float((terrain.maxY - y) / terrain.depth))
    }

    /// Vertex tint over draped imagery: worn earth verges beside the tarmac and sand at the shore.
    static func drapedTint(elevation: Double, water: Double?, roadDistance: Double?) -> SIMD4<Float> {
        var c = SIMD4<Float>(1, 1, 1, 1)
        if let w = water, elevation < w + 2.5 { c = SceneMath.mix(SceneMath.rgba(0xF2E6C4), c, Float((elevation - w) / 2.5)) }
        if let rd = roadDistance, rd < 9 { c = SceneMath.mix(SIMD4(0.86, 0.78, 0.64, 1), c, Float((rd - 5.5) / 3.5)) }
        return c
    }

    static func terrainMaterial(imagery: CGImage?) -> SCNMaterial {
        guard let imagery else { return terrainMaterial() }
        let m = SCNMaterial()
        m.lightingModel = .lambert
        // Channel 0: satellite photo over the whole DEM area.
        m.diffuse.contents = imagery
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 16
        m.diffuse.mappingChannel = 0
        // Channel 1: metre-scale detail so the ground stays crisp up close.
        m.diffuse.intensity = 1.18
        m.multiply.contents = drapedDetail
        m.multiply.wrapS = .repeat
        m.multiply.wrapT = .repeat
        m.multiply.mipFilter = .linear
        m.multiply.maxAnisotropy = 8
        m.multiply.mappingChannel = 1
        m.multiply.contentsTransform = SCNMatrix4MakeScale(5, 5, 1)
        m.normal.contents = groundNormal
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.mipFilter = .linear
        m.normal.intensity = 0.8
        m.normal.mappingChannel = 1
        m.normal.contentsTransform = SCNMatrix4MakeScale(3, 3, 1)
        m.isDoubleSided = true
        return m
    }

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

    static func farTerrain(route: Route, terrain: TerrainModel, frame: WorldFrame, material: SCNMaterial, draped: Bool) -> SCNNode {
        let size = max(terrain.width, terrain.depth)
        let n = max(96, min(400, Int(size / 40)))
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
                    // Tuck the coarse far terrain well under the fine road corridor.
                    h = min(h, hit.elevation) - 9
                }
                // Skirt the outer rim down so the world edge never shows daylight underneath.
                if i == 0 || j == 0 || i == n - 1 || j == n - 1 { h -= 60 }
                heights[j * n + i] = h
                if draped {
                    mesh.addVertex(frame.point(x: x, y: y, elevation: h), uv: imageryUV(terrain, x, y), uv2: SIMD2(Float(x / 23), Float(y / 23)))
                } else {
                    mesh.addVertex(frame.point(x: x, y: y, elevation: h), uv: SIMD2(Float(x / 23), Float(y / 23)))
                }
            }
        }
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = j * n + i, b = a + 1, c = a + n + 1, d = a + n
                // Keep the far terrain continuous (tucked under the corridor near the road) so
                // wherever the corridor is trimmed at hairpins there is ground, not a hole.
                _ = near[a]
                mesh.addQuad(UInt32(a), UInt32(d), UInt32(c), UInt32(b))
            }
        }
        mesh.computeNormals()
        let water = terrain.waterLevel
        for k in 0..<(n * n) {
            let ny = mesh.normals[k * 3 + 1]
            let i = k % n, j = k / n
            let x = terrain.minX + Double(i) * sx, y = terrain.minY + Double(j) * sy
            let c = draped ? drapedTint(elevation: heights[k], water: water, roadDistance: nil)
                : groundColor(biome: route.record.biome, elevation: heights[k], slope: 1 - ny, x: x, y: y, water: water, roadDistance: nil)
            mesh.colors.replaceSubrange((k * 4)..<(k * 4 + 4), with: [c.x, c.y, c.z, c.w])
        }
        let node = SCNNode(geometry: mesh.geometry(materials: [material]))
        node.name = "terrain-far"
        node.castsShadow = false
        return node
    }

    // MARK: - Corridor terrain (fine, aligned with the road)

    static func corridorTerrain(route: Route, terrain: TerrainModel, frame: WorldFrame, material: SCNMaterial, draped: Bool) -> SCNNode {
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
                mesh.addVertex(frame.point(q, h), uv: draped ? imageryUV(terrain, q.x, q.y) : SIMD2(Float(q.x / 23), Float(q.y / 23)),
                               uv2: draped ? SIMD2(Float(q.x / 23), Float(q.y / 23)) : nil)
                vertexHeights.append(h)
            }
            for (side, o) in [(-1.0, offsets.first!), (1.0, offsets.last!)] {
                let q = p + right * (o + side * 2)
                let h = (side < 0 ? rowHeights.first! : rowHeights.last!) - 14
                mesh.addVertex(frame.point(q, h), uv: draped ? imageryUV(terrain, q.x, q.y) : SIMD2(Float(q.x / 23), Float(q.y / 23)),
                               uv2: draped ? SIMD2(Float(q.x / 23), Float(q.y / 23)) : nil)
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
            let c = draped ? drapedTint(elevation: vertexHeights[k], water: water, roadDistance: vertexRoadDist[k])
                : groundColor(biome: route.record.biome, elevation: vertexHeights[k], slope: 1 - abs(ny), x: x, y: y,
                              water: water, roadDistance: vertexRoadDist[k])
            mesh.colors.replaceSubrange((k * 4)..<(k * 4 + 4), with: [c.x, c.y, c.z, c.w])
        }
        let node = SCNNode(geometry: mesh.geometry(materials: [material]))
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
        // Aggregate / sett relief catching the low sun.
        m.normal.contents = surface == .cobbles ? cobbleNormal : asphaltNormal
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.mipFilter = .linear
        m.normal.intensity = surface == .cobbles ? 1.0 : 0.6
        m.normal.contentsTransform = surface == .cobbles ? SCNMatrix4MakeScale(1, 1, 1) : SCNMatrix4MakeScale(4, 4, 1)
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

    /// A painted message lying on the road surface, reading towards approaching riders.
    static func roadPaint(_ text: String, at d: Double, lateral: Double, route: Route, frame: WorldFrame) -> SCNNode {
        let length = 6.0, width = 3.2
        var mesh = MeshData()
        let rows = 4
        for k in 0...rows {
            let dd = d + length * Double(k) / Double(rows)
            let p = route.position(at: dd)
            let dir = route.direction(at: dd)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            let e = route.elevation(at: dd) + 0.07
            for side in [-1.0, 1.0] {
                let q = p + right * (lateral + side * width / 2)
                mesh.addVertex(frame.point(q, e - abs(lateral + side * width / 2) * 0.008), normal: SIMD3(0, 1, 0),
                               uv: SIMD2(side < 0 ? 0 : 1, 1 - Float(k) / Float(rows)))
            }
            if k > 0 {
                let a = UInt32((k - 1) * 2), b = UInt32(k * 2)
                mesh.addQuad(a, a + 1, b + 1, b)
            }
        }
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = ProceduralTextures.roadPaint(text)
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        let node = SCNNode(geometry: mesh.geometry(materials: [m], includeColors: false))
        node.castsShadow = false
        node.renderingOrder = 5
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
        // Fans' messages painted on the road over the last kilometres of the big climbs.
        let slogans = ["ALLEZ", "FORZA", "VAMOS", "HUP HUP", "ALLEZ ALLEZ", "VAI!", "GO GO GO", "♥ VÉLO", "CHAPEAU", "DAJE"]
        var paintRNG = SceneRandom(seed: UInt64(route.length))
        for climb in route.climbs where climb.category <= .cat2 && climb.length > 2000 {
            var d = max(climb.startDistance, climb.endDistance - 4000)
            while d < climb.endDistance - 60 {
                if paintRNG.chance(0.55) {
                    container.addChildNode(roadPaint(paintRNG.pick(slogans), at: d, lateral: paintRNG.range(-1.6, 1.6), route: route, frame: frame))
                }
                d += paintRNG.range(90, 220)
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
