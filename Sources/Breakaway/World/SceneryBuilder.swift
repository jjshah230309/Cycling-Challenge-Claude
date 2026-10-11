import AppKit
import BreakawayCore
import SceneKit
import simd

/// Places the procedural scenery (forests, rocks, villages, crowds, camper vans,
/// verge grass, roadside furniture) along a route. Instances are merged into
/// route chunks with distance-based levels of detail, so thousands of objects
/// cost only a few draw calls each.
enum SceneryBuilder {
    /// Groups merged meshes by route chunk; positions are stored relative to the chunk centre
    /// so SceneKit's LOD distances are measured from somewhere sensible.
    struct Chunks {
        let length: Double
        let route: Route
        let frame: WorldFrame
        var meshes: [Int: ModelMesh] = [:]
        var origins: [Int: SIMD3<Float>] = [:]

        init(length: Double, route: Route, frame: WorldFrame) {
            self.length = length
            self.route = route
            self.frame = frame
        }

        mutating func origin(_ chunk: Int) -> SIMD3<Float> {
            if let o = origins[chunk] { return o }
            let mid = min(route.length, (Double(chunk) + 0.5) * length)
            let o = frame.point(route.position(at: mid), route.elevation(at: mid))
            origins[chunk] = o
            return o
        }

        /// Adds `mesh` at scene position `p`, rotated by `yaw` about +Y and scaled.
        mutating func add(_ mesh: ModelMesh, distance: Double, at p: SIMD3<Float>, yaw: Float, scale: SIMD3<Float> = SIMD3(1, 1, 1),
                          tint: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
            let chunk = max(0, Int(distance / length))
            let o = origin(chunk)
            let t = RigidTransform.rotation(axis: SIMD3(0, 1, 0), angle: yaw, origin: p - o)
            meshes[chunk, default: ModelMesh()].append(mesh, transform: t, scale: scale, tint: tint)
        }

        /// One node per chunk; `lods` maps a chunk mesh to (geometry, distance) pairs for farther levels.
        func nodes(material: (String) -> SCNMaterial, lods: [(distance: CGFloat, mesh: (Int) -> ModelMesh?)] = [],
                   name: String) -> SCNNode {
            let container = SCNNode()
            container.name = name
            for (chunk, mesh) in meshes.sorted(by: { $0.key < $1.key }) where mesh.vertexCount > 0 {
                let g = ModelGeometry.geometry(mesh, material: material)
                if !lods.isEmpty {
                    g.levelsOfDetail = lods.map { lod in
                        SCNLevelOfDetail(geometry: lod.mesh(chunk).map { ModelGeometry.geometry($0, material: material) },
                                         worldSpaceDistance: lod.distance)
                    }
                }
                let n = SCNNode(geometry: g)
                n.simdPosition = origins[chunk] ?? .zero
                container.addChildNode(n)
            }
            return container
        }
    }

    // MARK: - Forests

    static func treeKinds(_ biome: RouteRecord.Biome) -> (kinds: [(Scenery.TreeKind, Double)], density: Double) {
        switch biome {
        case .alpine: return ([(.spruce, 0.85), (.broadleaf, 0.15)], 1.7)
        case .forest: return ([(.broadleaf, 0.65), (.poplar, 0.1), (.spruce, 0.25)], 4.5)
        case .countryside: return ([(.broadleaf, 0.6), (.poplar, 0.4)], 0.8)
        case .coastal: return ([(.olive, 0.35), (.stonePine, 0.25), (.cypress, 0.2), (.palm, 0.2)], 1.0)
        case .lakes: return ([(.broadleaf, 0.55), (.spruce, 0.35), (.poplar, 0.1)], 1.4)
        case .urban: return ([(.broadleaf, 0.8), (.poplar, 0.2)], 0.55)
        }
    }

    static func vegetation(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let biome = route.record.biome
        let (kinds, density) = treeKinds(biome)
        // Three variants of each kind at three levels of detail.
        // Close up: a solid core plus alpha-tested needle/leaf cards; farther away the plain meshes.
        var protos: [Scenery.TreeKind: [[ModelMesh]]] = [:]
        var cardProtos: [Scenery.TreeKind: [ModelMesh]] = [:]
        var liteProtos: [Scenery.TreeKind: [Scenery.TreeParts]] = [:]
        for (kind, _) in kinds {
            var variants: [[ModelMesh]] = []
            var cards: [ModelMesh] = []
            for v in 0..<3 {
                let seed = UInt64(v * 7919 + 13)
                let real = Scenery.realisticTree(kind, seed: seed)
                variants.append([real.core, Scenery.tree(kind, seed: seed, detail: 0.5), Scenery.tree(kind, seed: seed, detail: 0.2)])
                cards.append(real.cards)
                liteProtos[kind, default: []].append(Scenery.realisticTree(kind, seed: seed, cardFraction: 0.3))
            }
            protos[kind] = variants
            cardProtos[kind] = cards
        }
        var nearCards = Chunks(length: 400, route: route, frame: frame)
        // Mid-distance forest: a simple core plus a third of the cards (larger), out to ~650 m.
        var farCores = Chunks(length: 400, route: route, frame: frame)
        var farCards = Chunks(length: 400, route: route, frame: frame)
        let chunkLength = 400.0
        var near = [Chunks](repeating: Chunks(length: chunkLength, route: route, frame: frame), count: 3)
        var far = [Chunks](repeating: Chunks(length: chunkLength, route: route, frame: frame), count: 2)
        let treeline = 2050.0
        var d = 0.0
        while d < route.length {
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            let tries = Int(density * 2 + rng.range(0, 1))
            for _ in 0..<tries {
                let falloff: Double = biome == .forest ? 60 : 140
                let minLateral: Double = biome == .forest ? 7.5 : 10
                let lateral: Double = minLateral + min(900, -log(max(rng.unit(), 1e-6)) * falloff)
                let side = rng.chance(0.5) ? 1.0 : -1.0
                let q = p + right * (side * lateral) + dir * rng.range(-6, 6)
                let forest = TerrainModel.fbm(q.x / 350, q.y / 350, octaves: 2, seed: 99)
                if forest < (biome == .forest ? -0.45 : -0.05) { continue }
                if terrain.nearestRoad(x: q.x, y: q.y, maxDistance: 9) != nil { continue }
                let h = terrain.height(x: q.x, y: q.y)
                if let w = terrain.waterLevel, h < w + 1.2 { continue }
                if biome == .alpine, h > treeline + 120 * forest { continue }
                let hx = terrain.height(x: q.x + 4, y: q.y), hy = terrain.height(x: q.x, y: q.y + 4)
                if abs(hx - h) > 3.6 || abs(hy - h) > 3.6 { continue }
                var pick = rng.unit()
                var kind = kinds[0].0
                for (k, w) in kinds {
                    if pick < w { kind = k; break }
                    pick -= w
                }
                if biome == .alpine, h > 1500 { kind = .spruce }
                let variant = Int(rng.unit() * 3) % 3
                let s = rng.float(0.65, 1.25)
                let stretch: Float = rng.float(0.85, 1.15)
                let scale = SIMD3<Float>(s, s * stretch, s)
                let tr: Float = rng.float(0.88, 1.08), tg: Float = rng.float(0.9, 1.08), tb: Float = rng.float(0.85, 1.05)
                let tint = SIMD4<Float>(tr, tg, tb, 1)
                let pos = frame.point(q, h - 0.2)
                let yaw = rng.float(0, 6.28)
                let lods = protos[kind]![variant]
                if lateral < 90 {
                    for l in 0..<3 { near[l].add(lods[l], distance: d, at: pos, yaw: yaw, scale: scale, tint: tint) }
                    nearCards.add(cardProtos[kind]![variant], distance: d, at: pos, yaw: yaw, scale: scale, tint: tint)
                } else {
                    far[1].add(lods[2], distance: d, at: pos, yaw: yaw, scale: scale, tint: tint)
                    let lite = liteProtos[kind]![variant]
                    farCores.add(lite.core, distance: d, at: pos, yaw: yaw, scale: scale, tint: tint)
                    farCards.add(lite.cards, distance: d, at: pos, yaw: yaw, scale: scale, tint: tint)
                }
            }
            d += 10
        }
        // Boulders and scree above the treeline, outcrops on steep alpine ground.
        var rockChunks = Chunks(length: chunkLength, route: route, frame: frame)
        if biome == .alpine || biome == .coastal {
            let rocks = (0..<6).map { Scenery.rock(seed: UInt64($0 * 31 + 5), detail: 0.5) }
            var dd = 0.0
            while dd < route.length {
                let high = route.elevation(at: dd) > treeline - 150
                if rng.chance(high ? 0.75 : 0.25) {
                    let p = route.position(at: dd)
                    let dir = route.direction(at: dd)
                    let right = LocalPoint(x: dir.y, y: -dir.x)
                    let rockSide: Double = rng.chance(0.5) ? 1 : -1
                    let rockLateral: Double = rng.range(8, high ? 120 : 60)
                    let q = p + right * (rockSide * rockLateral)
                    if terrain.nearestRoad(x: q.x, y: q.y, maxDistance: 8) == nil {
                        let size: Float = rng.float(0.5, high ? 3.2 : 1.6)
                        let squash: Float = rng.float(0.6, 1.1)
                        rockChunks.add(rng.pick(rocks), distance: dd, at: frame.point(q, terrain.height(x: q.x, y: q.y) - 0.25 * Double(size)),
                                    yaw: rng.float(0, 6.28), scale: SIMD3<Float>(size, size * squash, size))
                    }
                }
                dd += 20
            }
        }
        let container = SCNNode()
        container.name = "vegetation"
        let mats = SceneryMaterials.shared
        // Near trees: full detail close by, simpler beyond ~200 m, minimal beyond ~600 m.
        container.addChildNode(near[0].nodes(material: mats.material, lods: [(200, { near[1].meshes[$0] }), (650, { near[2].meshes[$0] })],
                                             name: "trees-near"))
        // Foliage cards: no shadows (the cores cast them), hidden beyond the near range.
        let cardsNode = nearCards.nodes(material: mats.material, lods: [(230, { _ in nil })], name: "foliage-cards")
        // Up to ~650 m: lite cores + cards; beyond: the plain low-detail meshes.
        container.addChildNode(farCores.nodes(material: mats.material, lods: [(650, { far[1].meshes[$0] })], name: "trees-far"))
        let farCardsNode = farCards.nodes(material: mats.material, lods: [(650, { _ in nil })], name: "foliage-cards-far")
        container.addChildNode(rockChunks.nodes(material: mats.material, name: "rocks"))
        container.enumerateChildNodes { n, _ in n.castsShadow = true }
        cardsNode.enumerateChildNodes { n, _ in n.castsShadow = false }
        farCardsNode.enumerateChildNodes { n, _ in n.castsShadow = false }
        container.addChildNode(cardsNode)
        container.addChildNode(farCardsNode)
        return container
    }

    // MARK: - Verge grass

    static func grass(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let biome = route.record.biome
        guard biome != .urban else { return SCNNode() }
        var tufts: [ModelMesh] = []
        let dry = biome == .coastal
        for k in 0..<10 {
            tufts.append(Scenery.grassClump(seed: UInt64(k * 17 + 3), height: dry ? 0.35 : 0.5, dry: dry))
        }
        var chunks = Chunks(length: 150, route: route, frame: frame)
        var d = 0.0
        while d < route.length {
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            for _ in 0..<9 {
                let side = rng.chance(0.5) ? 1.0 : -1.0
                let lateral = rng.range(6.2, 16)
                let q = p + right * (side * lateral) + dir * rng.range(-1.5, 1.5)
                if let hit = terrain.nearestRoad(x: q.x, y: q.y, maxDistance: 6), hit.distance < 6 { continue }
                let h = terrain.height(x: q.x, y: q.y)
                if let w = terrain.waterLevel, h < w + 0.5 { continue }
                let s = rng.float(0.8, 1.5)
                chunks.add(rng.pick(tufts), distance: d, at: frame.point(q, h - 0.02), yaw: rng.float(0, 6.28), scale: SIMD3(s, s, s))
            }
            d += 3
        }
        let node = chunks.nodes(material: SceneryMaterials.shared.material, lods: [(130, { _ in nil })], name: "grass")
        node.enumerateChildNodes { n, _ in n.castsShadow = false }
        return node
    }

    // MARK: - Villages and towns

    static func houseStyles(_ biome: RouteRecord.Biome) -> [Scenery.HouseStyle] {
        switch biome {
        case .alpine: return [.chalet, .chalet, .farmhouse]
        case .coastal, .lakes: return [.mediterranean, .mediterranean, .townhouse]
        case .urban: return [.apartment, .apartment, .townhouse]
        case .countryside, .forest: return [.brick, .farmhouse, .brick]
        }
    }

    static func buildings(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let biome = route.record.biome
        let styles = houseStyles(biome)
        let walls: [UInt32]
        let roofs: [UInt32]
        switch biome {
        case .alpine: walls = [0xF3EEE2, 0xE9DCC6, 0xF6F2EA, 0xE6D2B0]; roofs = [0x4A4644, 0x5A4632, 0x3C3C3C]
        case .coastal, .lakes: walls = [0xF2C894, 0xF5DDA8, 0xEBC3A0, 0xE59E78, 0xF7E8D0, 0xE8B4A0]; roofs = [0xB0582F, 0x9A4C2C]
        case .urban: walls = [0xE2DCCF, 0xCDBFAA, 0xB8AFA4, 0xD6C7AE, 0xEDEAE3, 0xA88E7A]; roofs = [0x4A4A4A, 0x5C5C5C]
        default: walls = [0xF2F0EA, 0xE9E2D2, 0xF5F5F5, 0xE2D6C0]; roofs = [0x8A3A26, 0x4A4A4A, 0x6B3A2A]
        }
        var chunks = Chunks(length: 500, route: route, frame: frame)
        var d = 0.0
        let spacing = biome == .urban ? 16.0 : 22.0
        while d < route.length {
            let townFactor: Double
            switch biome {
            case .urban: townFactor = 0.85
            case .alpine:
                let ends = min(d, route.length - d)
                townFactor = ends < 1200 ? 0.55 : 0.04
            case .coastal, .lakes: townFactor = 0.35
            default: townFactor = 0.12 + 0.3 * max(0, TerrainModel.fbm(d / 2000, 0, octaves: 2, seed: 5))
            }
            let p = route.position(at: d)
            let dir = route.direction(at: d)
            let right = LocalPoint(x: dir.y, y: -dir.x)
            for side in [-1.0, 1.0] where rng.chance(townFactor) {
                let style = rng.pick(styles)
                let w = rng.range(8, style == .apartment ? 20 : 13), depth = rng.range(7, style == .apartment ? 16 : 11)
                let floors = style == .apartment ? Int(rng.range(3, 7)) : Int(rng.range(1.6, 3.4))
                let setback: Double = rng.range(0, biome == .urban ? 4 : 18)
                let lateral: Double = 9 + depth / 2 + setback
                let q = p + right * (side * lateral)
                if let hit = terrain.nearestRoad(x: q.x, y: q.y, maxDistance: lateral - 2), hit.distance < max(w, depth) / 2 + 6 { continue }
                let h0 = terrain.height(x: q.x, y: q.y)
                if let wl = terrain.waterLevel, h0 < wl + 1 { continue }
                let corners = [(-w / 2, -depth / 2), (w / 2, -depth / 2), (-w / 2, depth / 2), (w / 2, depth / 2)].map { c -> Double in
                    let cq = q + dir * c.0 + right * c.1
                    return terrain.height(x: cq.x, y: cq.y)
                }
                let lo = corners.min()!, hi = corners.max()!
                if hi - lo > 6 { continue }
                let house = Scenery.house(style, width: Float(w), depth: Float(depth), floors: max(1, floors), foundation: Float(hi - lo) + 0.3,
                                          wallColor: Scenery.rgbColor(rng.pick(walls)), roofColor: Scenery.rgbColor(rng.pick(roofs)),
                                          seed: UInt64(d * 10) &+ (side > 0 ? 1 : 0))
                // Local +X runs along the road.
                chunks.add(house, distance: d, at: frame.point(q, hi), yaw: frame.yaw(dir) + .pi / 2)
            }
            d += spacing * rng.range(0.7, 1.3)
        }
        let node = chunks.nodes(material: SceneryMaterials.shared.material, name: "buildings")
        node.enumerateChildNodes { n, _ in n.castsShadow = true }
        return node
    }

    // MARK: - Crowds, flags and camper vans

    static func crowds(route: Route, terrain: TerrainModel, frame: WorldFrame, rng: inout SceneRandom) -> SCNNode {
        let shirts: [UInt32] = [0xD62828, 0xF77F00, 0xFCBF49, 0x2A9D8F, 0x264653, 0xE76F51, 0xFFFFFF, 0x1D3557, 0x8338EC, 0x06D6A0, 0xFFD60A, 0xF4D35E]
        let trousers: [UInt32] = [0x1D2433, 0x2B2B2B, 0x4A5A6A, 0xC9B79C, 0x3A3A3A]
        let skins: [UInt32] = [0xF1C27D, 0xC68E6A, 0x8D5A3B, 0xE0AC8B, 0x5C3A21]
        let flags: [UInt32] = [0xD62828, 0x1D3557, 0xFCBF49, 0x2A9D8F, 0xFFFFFF, 0x0055A4, 0x009246]
        let vans: [UInt32] = [0xF5F5F0, 0xEDE6D6, 0xFFFFFF, 0xDCE3E8]
        var zones: [(start: Double, end: Double, peakAtEnd: Bool, vans: Bool)] = route.climbs
            .filter { $0.category <= .cat3 }
            .map { (max($0.startDistance, $0.endDistance - 3000), $0.endDistance + 60, true, route.record.biome == .alpine) }
        zones.append((max(0, route.length - 400), route.length, true, false))
        if route.isLoop { zones.append((0, 150, false, false)) }
        var chunks = Chunks(length: 300, route: route, frame: frame)
        let poses = Scenery.SpectatorPose.allCases
        for zone in zones {
            var d = zone.start
            while d < min(zone.end, route.length) {
                let progress = (d - zone.start) / max(zone.end - zone.start, 1)
                let gap = zone.peakAtEnd ? 3.6 - 2.8 * progress : 1.4
                let p = route.position(at: d)
                let dir = route.direction(at: d)
                let right = LocalPoint(x: dir.y, y: -dir.x)
                let e = route.elevation(at: d)
                for side in [-1.0, 1.0] where rng.chance(0.82) {
                    let q = p + right * (side * rng.range(6.2, 8.4)) + dir * rng.range(-0.5, 0.5)
                    let h = max(terrain.height(x: q.x, y: q.y), e - 0.2)
                    // More arms in the air near the summit.
                    let cheer: Bool = rng.chance(0.25 + 0.4 * progress)
                    let anyPose: Scenery.SpectatorPose = poses[Int(rng.unit() * Double(poses.count)) % poses.count]
                    let pose: Scenery.SpectatorPose = cheer ? .cheering : anyPose
                    let person = Scenery.spectator(pose: pose, shirt: Scenery.rgbColor(rng.pick(shirts)), trousers: Scenery.rgbColor(rng.pick(trousers)),
                                                   skin: Scenery.rgbColor(rng.pick(skins)), flag: Scenery.rgbColor(rng.pick(flags)),
                                                   seed: UInt64(d * 7) &+ (side > 0 ? 3 : 0), detail: 0.5)
                    // Face the road.
                    let facing = LocalPoint(x: -right.x * side, y: -right.y * side)
                    chunks.add(person, distance: d, at: frame.point(q, h), yaw: frame.yaw(facing) + rng.float(-0.4, 0.4))
                }
                // Camper vans parked behind the crowd on the big mountain climbs.
                if zone.vans, rng.chance(0.09) {
                    let side = rng.chance(0.5) ? 1.0 : -1.0
                    let q = p + right * (side * rng.range(11, 14))
                    if terrain.nearestRoad(x: q.x, y: q.y, maxDistance: 9) == nil {
                        let h = terrain.height(x: q.x, y: q.y)
                        let ahead = q + dir * 3, behind = q - dir * 3
                        if abs(terrain.height(x: ahead.x, y: ahead.y) - terrain.height(x: behind.x, y: behind.y)) < 1.5 {
                            let van = Scenery.campervan(color: Scenery.rgbColor(rng.pick(vans)), seed: UInt64(d))
                            chunks.add(van, distance: d, at: frame.point(q, h - 0.1), yaw: frame.yaw(dir) + .pi)
                        }
                    }
                }
                d += max(0.9, gap * rng.range(0.6, 1.4))
            }
        }
        let node = chunks.nodes(material: SceneryMaterials.shared.material, name: "crowds")
        node.enumerateChildNodes { n, _ in n.castsShadow = true }
        return node
    }

    // MARK: - Roadside furniture

    /// Guardrails (W-beam on posts) where the road runs along a drop, reflector posts on
    /// open roads and snow poles on high mountain passes.
    static func roadside(route: Route, terrain: TerrainModel, frame: WorldFrame) -> SCNNode {
        let biome = route.record.biome
        var chunks = Chunks(length: 400, route: route, frame: frame)
        // W-beam profile (counter-clockwise; section x is horizontal away from the road, y up).
        let wBeam: [SIMD2<Float>] = [SIMD2(0, 0.16), SIMD2(-0.012, 0.11), SIMD2(0.018, 0.0), SIMD2(-0.012, -0.11), SIMD2(0, -0.16),
                                     SIMD2(0.04, -0.11), SIMD2(0.012, 0.0), SIMD2(0.04, 0.11)]
        var post = ModelMesh()
        post.box(center: SIMD3(0, 0.35, 0), size: SIMD3(0.1, 1.0, 0.12), material: Scenery.Material.trim)
        var reflector = ModelMesh()
        reflector.box(center: SIMD3(0, 0.6, 0), size: SIMD3(0.12, 1.2, 0.12), material: Scenery.Material.trim)
        let band = reflector.vertexCount
        reflector.box(center: SIMD3(0, 1.0, 0), size: SIMD3(0.13, 0.18, 0.13), material: Scenery.Material.trim)
        reflector.colorize(from: band) { _, _ in SIMD4(0.08, 0.08, 0.08, 1) }
        reflector.box(center: SIMD3(0, 1.02, -0.066), size: SIMD3(0.05, 0.08, 0.01), material: Scenery.Material.glass)
        var pole = ModelMesh()
        pole.tube(path: [SIMD3(0, 0, 0), SIMD3(0, 2.4, 0)], radius: { _ in 0.025 }, sides: 6, material: Scenery.Material.trim)
        pole.colorize { p, _ in Int(p.y / 0.4) % 2 == 0 ? SIMD4(0.95, 0.45, 0.1, 1) : SIMD4(0.1, 0.1, 0.1, 1) }
        let open = biome == .alpine || biome == .coastal || biome == .lakes || biome == .countryside
        for side in [-1.0, 1.0] {
            var rail: [SIMD3<Float>] = []
            var railStart = 0.0
            func flushRail() {
                if rail.count >= 2 {
                    var m = ModelMesh()
                    let o = chunks.origin(Int(railStart / chunks.length))
                    m.loft(path: rail.map { $0 - o }, up: SIMD3(0, 1, 0), section: { _, _ in wBeam },
                           material: { _ in "guardrail" })
                    chunks.meshes[Int(railStart / chunks.length), default: ModelMesh()].append(m)
                }
                rail.removeAll()
            }
            var d = 0.0
            var k = 0
            while d <= route.length {
                let p = route.position(at: d)
                let dir = route.direction(at: d)
                let right = LocalPoint(x: dir.y, y: -dir.x)
                let e = route.elevation(at: d)
                let probe = p + right * (side * 14)
                let drop = e - terrain.height(x: probe.x, y: probe.y)
                let edge = p + right * (side * 6.0)
                let yaw = frame.yaw(dir)
                if drop > 3.5, biome == .alpine || biome == .coastal || biome == .lakes {
                    if rail.isEmpty { railStart = d }
                    rail.append(frame.point(edge, e + 0.6))
                    // Rails are split per chunk so each piece is near its chunk origin.
                    if Int(d / chunks.length) != Int(railStart / chunks.length) {
                        let last = rail.last!
                        flushRail()
                        rail.append(last)
                        railStart = d
                    }
                    chunks.add(post, distance: d, at: frame.point(edge + right * (side * 0.08), e - 0.1), yaw: yaw)
                } else {
                    flushRail()
                    if open, k % 12 == 0 {
                        chunks.add(reflector, distance: d, at: frame.point(p + right * (side * 6.3), e - 0.05), yaw: yaw + (side > 0 ? 0 : .pi))
                    }
                }
                if biome == .alpine, e > 1900, k % 6 == 3, side > 0 {
                    chunks.add(pole, distance: d, at: frame.point(p + right * (side * 6.6), e - 0.05), yaw: 0)
                }
                d += 4
                k += 1
            }
            flushRail()
        }
        let node = chunks.nodes(material: SceneryMaterials.shared.material, lods: [(500, { _ in nil })], name: "roadside")
        return node
    }
}

extension Scenery {
    static func rgbColor(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }
}

/// Shared materials for scenery meshes (colour comes from vertex colours).
final class SceneryMaterials {
    static let shared = SceneryMaterials()
    private var table: [String: SCNMaterial] = [:]

    private init() {
        func lambert(_ image: Any? = nil, doubleSided: Bool = false, repeatScale: CGFloat = 1) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = image ?? NSColor.white
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.mipFilter = .linear
            if repeatScale != 1 { m.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatScale, repeatScale, 1) }
            m.isDoubleSided = doubleSided
            return m
        }
        let M = Scenery.Material.self
        let bark = lambert(SceneryTextures.bark())
        bark.multiply.contents = NSColor(srgbRed: 0.42, green: 0.33, blue: 0.25, alpha: 1)
        table[M.bark] = bark
        table[M.needles] = lambert(SceneryTextures.foliage(), repeatScale: 3)
        table[M.leaves] = lambert(SceneryTextures.foliage(), repeatScale: 3)
        let palm = lambert(doubleSided: true)
        palm.diffuse.contents = NSColor(srgbRed: 0.33, green: 0.5, blue: 0.2, alpha: 1)
        table[M.palm] = palm
        table[M.rock] = lambert(ProceduralTextures.groundDetail(), repeatScale: 2)
        table[M.grass] = lambert(doubleSided: true)
        table[M.needleCard] = SceneryMaterials.cutout(SceneryTextures.needleFrond())
        table[M.leafCard] = SceneryMaterials.cutout(SceneryTextures.leafCluster(olive: false))
        table[M.oliveCard] = SceneryMaterials.cutout(SceneryTextures.leafCluster(olive: true))
        table[M.grassCard] = SceneryMaterials.cutout(SceneryTextures.grassCard())
        for style in Scenery.HouseStyle.allCases {
            table["\(M.wall).\(style.rawValue)"] = lambert(SceneryTextures.facade(style))
        }
        table[M.roof] = lambert(SceneryTextures.roofTiles())
        let wood = lambert()
        wood.diffuse.contents = NSColor(srgbRed: 0.45, green: 0.29, blue: 0.17, alpha: 1)
        table[M.wood] = wood
        table[M.trim] = lambert()
        table[M.plinth] = lambert()
        let glass = SCNMaterial()
        glass.lightingModel = .blinn
        glass.diffuse.contents = NSColor.white
        glass.specular.contents = NSColor(white: 0.8, alpha: 1)
        glass.shininess = 60
        table[M.glass] = glass
        table[M.person] = lambert()
        let vehicle = SCNMaterial()
        vehicle.lightingModel = .blinn
        vehicle.diffuse.contents = NSColor.white
        vehicle.specular.contents = NSColor(white: 0.5, alpha: 1)
        vehicle.shininess = 40
        table[M.vehicle] = vehicle
        table[M.tyre] = lambert()
        table[M.flag] = lambert(doubleSided: true)
        let rail = SCNMaterial()
        rail.lightingModel = .physicallyBased
        rail.diffuse.contents = NSColor(white: 0.62, alpha: 1)
        rail.metalness.contents = 0.75
        rail.roughness.contents = 0.4
        rail.isDoubleSided = true
        table["guardrail"] = rail
    }

    /// Alpha-tested foliage: texels below half coverage are discarded, so cards sort and
    /// depth-test like solid geometry (no blending, no ordering artefacts).
    static func cutout(_ image: CGImage) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = image
        m.diffuse.mipFilter = .linear
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.isDoubleSided = true
        m.blendMode = .replace
        m.writesToDepthBuffer = true
        m.shaderModifiers = [.fragment: "if (_output.color.a < 0.4) { discard_fragment(); }\n_output.color.a = 1.0;"]
        return m
    }

    func material(_ name: String) -> SCNMaterial {
        if let m = table[name] { return m }
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor.white
        table[name] = m
        return m
    }
}

/// Textures for scenery (all drawn at runtime).
enum SceneryTextures {
    /// A spruce/fir frond: a twig up the middle (v) with needles angled forward, on transparency.
    static func needleFrond() -> CGImage {
        let w = 256, h = 512
        let ctx = ProceduralTextures.context(w, h)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        var r = SceneRandom(seed: 41)
        let W = Double(w), H = Double(h)
        // Side shoots.
        var shoots: [(x0: Double, y0: Double, x1: Double, y1: Double)] = [(W / 2, 0, W / 2, H * 0.97)]
        var y = H * 0.08
        while y < H * 0.9 {
            let span: Double = sin((y / H) * .pi) * W * 0.44 + 10
            for s in [-1.0, 1.0] { shoots.append((W / 2, y, W / 2 + s * span, y + span * 0.55)) }
            y += r.range(26, 40)
        }
        ctx.setLineCap(.round)
        for sh in shoots {
            ctx.setStrokeColor(ProceduralTextures.cg(0x4A3320))
            ctx.setLineWidth(sh.x0 == sh.x1 ? 4 : 2)
            ctx.move(to: CGPoint(x: sh.x0, y: sh.y0))
            ctx.addLine(to: CGPoint(x: sh.x1, y: sh.y1))
            ctx.strokePath()
            // Needles along the shoot.
            let len = hypot(sh.x1 - sh.x0, sh.y1 - sh.y0)
            let n = Int(len / 2.2)
            for k in 0..<n {
                let t = Double(k) / Double(max(n, 1))
                let px = sh.x0 + (sh.x1 - sh.x0) * t, py = sh.y0 + (sh.y1 - sh.y0) * t
                let dirx = (sh.x1 - sh.x0) / max(len, 1), diry = (sh.y1 - sh.y0) / max(len, 1)
                for side in [-1.0, 1.0] {
                    let nl = r.range(9, 16) * (1 - 0.4 * t)
                    // Rotate the shoot direction by ±55° for the needle.
                    let a = side * 0.95
                    let nx = dirx * cos(a) - diry * sin(a), ny = dirx * sin(a) + diry * cos(a)
                    let light: Double = r.range(0.0, 1.0) * 0.6 + t * 0.4
                    let cr = CGFloat(0.12 + 0.12 * light), cgr = CGFloat(0.28 + 0.2 * light), cb = CGFloat(0.1 + 0.08 * light)
                    ctx.setStrokeColor(CGColor(srgbRed: cr, green: cgr, blue: cb, alpha: 1))
                    ctx.setLineWidth(r.range(1.4, 2.4))
                    ctx.move(to: CGPoint(x: px, y: py))
                    ctx.addLine(to: CGPoint(x: px + nx * nl, y: py + ny * nl))
                    ctx.strokePath()
                }
            }
        }
        return ctx.makeImage()!
    }

    /// A spray of broad leaves (or narrow silvery olive leaves) on transparency.
    static func leafCluster(olive: Bool) -> CGImage {
        let n = 512
        let ctx = ProceduralTextures.context(n, n)
        ctx.clear(CGRect(x: 0, y: 0, width: n, height: n))
        var r = SceneRandom(seed: olive ? 77 : 55)
        let N = Double(n)
        // Twigs.
        ctx.setStrokeColor(ProceduralTextures.cg(0x4A3828))
        ctx.setLineCap(.round)
        for k in 0..<7 {
            let a = Double(k) / 7 * 2 * .pi + r.range(0, 0.6)
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: N / 2, y: N / 2))
            ctx.addLine(to: CGPoint(x: N / 2 + cos(a) * N * 0.36, y: N / 2 + sin(a) * N * 0.36))
            ctx.strokePath()
        }
        let leaves = olive ? 900 : 700
        for _ in 0..<leaves {
            let a: Double = r.range(0, 2 * .pi)
            let rad: Double = pow(r.unit(), 0.6) * N * 0.44
            let x = N / 2 + cos(a) * rad, y = N / 2 + sin(a) * rad
            let len = olive ? r.range(16, 26) : r.range(16, 30)
            let wid = olive ? len * 0.22 : len * r.range(0.5, 0.7)
            let light: Double = r.unit()
            let lr: Double = olive ? 0.42 + 0.18 * light : 0.16 + 0.16 * light
            let lg: Double = olive ? 0.48 + 0.16 * light : 0.3 + 0.22 * light
            let lb: Double = olive ? 0.34 + 0.12 * light : 0.1 + 0.08 * light
            let c = CGColor(srgbRed: CGFloat(lr), green: CGFloat(lg), blue: CGFloat(lb), alpha: 1)
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: r.range(0, 2 * .pi))
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: -len / 2, y: -wid / 2, width: len, height: wid))
            // Midrib highlight.
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: -len / 2, y: 0))
            ctx.addLine(to: CGPoint(x: len / 2, y: 0))
            ctx.strokePath()
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    /// Grass blades rising from the bottom edge, with the odd seed head.
    static func grassCard() -> CGImage {
        let w = 512, h = 256
        let ctx = ProceduralTextures.context(w, h)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        var r = SceneRandom(seed: 19)
        ctx.setLineCap(.round)
        for _ in 0..<420 {
            let x = r.range(6, Double(w) - 6)
            let centred: Double = 1 - abs(x - Double(w) / 2) / Double(w) * 0.6
            let bh: Double = r.range(50, Double(h) - 6) * centred
            let bend = r.range(-40, 40)
            let light: Double = r.unit()
            let gr = CGFloat(0.2 + 0.25 * light), gg = CGFloat(0.32 + 0.3 * light), gb = CGFloat(0.1 + 0.08 * light)
            ctx.setStrokeColor(CGColor(srgbRed: gr, green: gg, blue: gb, alpha: 1))
            ctx.setLineWidth(r.range(1.6, 3.4))
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addQuadCurve(to: CGPoint(x: x + bend, y: bh), control: CGPoint(x: x + bend * 0.2, y: bh * 0.6))
            ctx.strokePath()
            if r.chance(0.03) {
                ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.68, blue: 0.45, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: x + bend - 3, y: bh - 4, width: 6, height: 16))
            }
        }
        return ctx.makeImage()!
    }

    static func bark() -> CGImage {
        let ctx = ProceduralTextures.context(64, 256)
        ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 256))
        var r = SceneRandom(seed: 3)
        for _ in 0..<60 {
            ctx.setFillColor(CGColor(gray: r.chance(0.5) ? 0.45 : 0.95, alpha: 0.5))
            ctx.fill(CGRect(x: r.range(0, 64), y: r.range(0, 256), width: r.range(1, 4), height: r.range(20, 90)))
        }
        return ctx.makeImage()!
    }

    /// Clumpy light/dark variation multiplied over leaf and needle colours.
    static func foliage() -> CGImage {
        let n = 256
        let ctx = ProceduralTextures.context(n, n)
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        var r = SceneRandom(seed: 9)
        for _ in 0..<2600 {
            let s = r.range(3, 10)
            ctx.setFillColor(CGColor(gray: r.chance(0.5) ? 1.0 : 0.55, alpha: 0.55))
            ctx.fillEllipse(in: CGRect(x: r.range(0, Double(n)), y: r.range(0, Double(n)), width: s, height: s * 0.7))
        }
        return ctx.makeImage()!
    }

    static func roofTiles() -> CGImage {
        let ctx = ProceduralTextures.context(128, 128)
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        // One texture repeat = 1.5 m; courses of tiles ~19 cm.
        for row in 0..<8 {
            let y = CGFloat(row) * 16
            ctx.setFillColor(CGColor(gray: 0.62, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: 128, height: 3))
            let offset: CGFloat = row % 2 == 0 ? 0 : 8
            ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
            var x = offset
            while x < 128 {
                ctx.fill(CGRect(x: x, y: y + 3, width: 1.5, height: 13))
                x += 16
            }
        }
        return ctx.makeImage()!
    }

    /// One window bay (3 m) × one storey (3 m) of facade, tinted by the wall's vertex colour.
    static func facade(_ style: Scenery.HouseStyle) -> CGImage {
        let n = 512
        let ctx = ProceduralTextures.context(n, n)
        let N = CGFloat(n)
        func px(_ m: CGFloat) -> CGFloat { m / 3 * N }
        let k = N / 256                       // pixel sizes below were authored at 256 px
        // Wall surface.
        switch style {
        case .brick:
            ctx.setFillColor(ProceduralTextures.cg(0xB5654A))
            ctx.fill(CGRect(x: 0, y: 0, width: N, height: N))
            ctx.setFillColor(ProceduralTextures.cg(0xD8CFC0))
            var y: CGFloat = 0
            var row = 0
            while y < N {
                ctx.fill(CGRect(x: 0, y: y, width: N, height: 1.5 * k))
                var x: CGFloat = row % 2 == 0 ? 0 : 9 * k
                while x < N {
                    ctx.fill(CGRect(x: x, y: y, width: 1.5 * k, height: 6 * k))
                    x += 18 * k
                }
                y += 6 * k
                row += 1
            }
        case .chalet:
            ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: N, height: N))
            // Horizontal timber boarding on the upper half of each storey.
            ctx.setFillColor(ProceduralTextures.cg(0x8A5A35))
            ctx.fill(CGRect(x: 0, y: N * 0.45, width: N, height: N * 0.55))
            ctx.setFillColor(ProceduralTextures.cg(0x6E4527))
            var y = N * 0.45
            while y < N {
                ctx.fill(CGRect(x: 0, y: y, width: N, height: 2 * k))
                y += 10 * k
            }
        default:
            ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: N, height: N))
            var r = SceneRandom(seed: 77)
            for _ in 0..<500 {
                ctx.setFillColor(CGColor(gray: r.chance(0.5) ? 0.9 : 1, alpha: 0.4))
                ctx.fill(CGRect(x: r.range(0, Double(N)), y: r.range(0, Double(N)), width: 3 * k, height: 3 * k))
            }
        }
        // Window.
        let tall = style == .townhouse || style == .mediterranean || style == .apartment
        let win = CGRect(x: px(1.0), y: px(tall ? 0.7 : 0.95), width: px(1.0), height: px(tall ? 1.7 : 1.25))
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(win.insetBy(dx: -px(0.08), dy: -px(0.08)))         // frame / sill
        ctx.setFillColor(ProceduralTextures.cg(0x2B3A48))
        ctx.fill(win)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
        ctx.fill(CGRect(x: win.minX, y: win.midY, width: win.width, height: win.height / 2))   // sky reflection
        ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
        ctx.fill(CGRect(x: win.midX - 2 * k, y: win.minY, width: 4 * k, height: win.height))
        ctx.fill(CGRect(x: win.minX, y: win.midY - 2 * k, width: win.width, height: 4 * k))
        // Shutters.
        let shutter: UInt32?
        switch style {
        case .mediterranean: shutter = 0x3E7D5A
        case .chalet: shutter = 0x7A2E22
        case .farmhouse: shutter = 0x55708A
        default: shutter = nil
        }
        if let shutter {
            ctx.setFillColor(ProceduralTextures.cg(shutter))
            ctx.fill(CGRect(x: win.minX - px(0.5), y: win.minY, width: px(0.45), height: win.height))
            ctx.fill(CGRect(x: win.maxX + px(0.05), y: win.minY, width: px(0.45), height: win.height))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
            var y = win.minY + 4 * k
            while y < win.maxY {
                ctx.fill(CGRect(x: win.minX - px(0.5), y: y, width: px(0.45), height: 1.5 * k))
                ctx.fill(CGRect(x: win.maxX + px(0.05), y: y, width: px(0.45), height: 1.5 * k))
                y += 7 * k
            }
        }
        if style == .apartment {
            // Balcony railing below the window.
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
            ctx.fill(CGRect(x: px(0.6), y: px(0.55), width: px(1.8), height: 3 * k))
            ctx.fill(CGRect(x: px(0.6), y: px(0.1), width: px(1.8), height: 3 * k))
            var x = px(0.6)
            while x < px(2.4) {
                ctx.fill(CGRect(x: x, y: px(0.1), width: 2 * k, height: px(0.45)))
                x += 8 * k
            }
        }
        return ctx.makeImage()!
    }
}
