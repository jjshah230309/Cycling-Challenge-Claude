import Foundation

/// Procedural scenery: trees, rocks, buildings, spectators, vehicles and ground cover.
/// Colour variation is carried in vertex colours so a whole forest or crowd can be
/// merged into a handful of draw calls.
public enum Scenery {
    public enum Material {
        public static let bark = "bark", leaves = "leaves", needles = "needles", palm = "palmLeaf"
        public static let rock = "rock", grass = "grass"
        public static let wall = "wall", roof = "roof", wood = "wood", trim = "trim", glass = "glass", plinth = "plinth"
        public static let person = "person", vehicle = "vehicle", tyre = "vehicleTyre", flag = "flag"
        /// Alpha-cutout foliage cards (textures with transparent backgrounds).
        public static let needleCard = "needleCard", leafCard = "leafCard", oliveCard = "oliveCard", grassCard = "grassCard"
    }

    public enum TreeKind: String, CaseIterable, Sendable {
        case spruce, broadleaf, poplar, palm, olive, stonePine, cypress
    }

    /// Smooth value noise in 3D (−1…1), for organic displacement.
    static func noise3(_ p: V3, seed: Int) -> Float {
        func hash(_ x: Int, _ y: Int, _ z: Int) -> Float {
            let a: Int = x &* 73_856_093
            let b: Int = y &* 19_349_663
            let c: Int = z &* 83_492_791
            let d: Int = seed &* 2_654_435_761
            var h = UInt64(bitPattern: Int64(a ^ b ^ c ^ d))
            h ^= h >> 33
            h = h &* 0xFF51_AFD7_ED55_8CCD
            h ^= h >> 33
            return Float(h & 0xFFFF) / 32_767.5 - 1
        }
        let xi = Int(floor(p.x)), yi = Int(floor(p.y)), zi = Int(floor(p.z))
        let f = p - V3(Float(xi), Float(yi), Float(zi))
        let u = f * f * (V3(3, 3, 3) - f * 2)
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let x00 = lerp(hash(xi, yi, zi), hash(xi + 1, yi, zi), u.x)
        let x10 = lerp(hash(xi, yi + 1, zi), hash(xi + 1, yi + 1, zi), u.x)
        let x01 = lerp(hash(xi, yi, zi + 1), hash(xi + 1, yi, zi + 1), u.x)
        let x11 = lerp(hash(xi, yi + 1, zi + 1), hash(xi + 1, yi + 1, zi + 1), u.x)
        return lerp(lerp(x00, x10, u.y), lerp(x01, x11, u.y), u.z)
    }

    static func fbm3(_ p: V3, seed: Int, octaves: Int = 3) -> Float {
        var sum: Float = 0, amp: Float = 0.5, freq: Float = 1
        for o in 0..<octaves {
            sum += amp * noise3(p * freq, seed: seed + o * 31)
            amp *= 0.5
            freq *= 2.03
        }
        return sum
    }

    /// True with probability `p`.
    static func chance(_ rng: inout SplitMix64, _ p: Double) -> Bool { rng.nextUnit() < p }

    static func rgb(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }

    static func mix4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * max(0, min(1, t)) }

    // MARK: - Trees

    /// A tree standing on the origin, +Y up. `detail` 1 = close-up, ~0.5 = mid-distance, ≤ 0.25 = far.
    public static func tree(_ kind: TreeKind, seed: UInt64, detail: Float = 1) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let hi = detail >= 0.75, mid = detail >= 0.4
        func r(_ a: Float, _ b: Float) -> Float { Float(rng.range(Double(a), Double(b))) }
        let barkSides = hi ? 8 : (mid ? 6 : 4)

        func trunk(height: Float, base: Float, top: Float, lean: V3 = .zero, bend: Float = 0) {
            let steps = hi ? 6 : 3
            let path = (0...steps).map { k -> V3 in
                let t = Float(k) / Float(steps)
                return V3(0, height * t, 0) + lean * (t * t) + V3(bend * sin(t * 3), 0, 0)
            }
            m.tube(path: path, radius: { t in
                let flare = 1 + 0.6 * max(0, 1 - t * 8)
                return mixf(base, top, t) * flare
            }, sides: barkSides, material: Material.bark, caps: false)
        }

        switch kind {
        case .spruce:
            let H = r(14, 22)
            trunk(height: H * 0.97, base: 0.24 * H / 18, top: 0.03)
            let whorls = hi ? 10 : (mid ? 6 : 3)
            let segs = hi ? 18 : (mid ? 10 : 6)
            let y0 = H * r(0.08, 0.16)
            let start = m.vertexCount
            for k in 0..<whorls {
                let t = Float(k) / Float(whorls)
                let y = y0 + (H * 0.95 - y0) * t
                let R = (0.3 * H * pow(1 - t, 0.85) + 0.35) * r(0.9, 1.1)
                let spacing = (H * 0.95 - y0) / Float(whorls)
                let droop = spacing * 0.9 + R * 0.12
                let phase = r(0, 6.28), lobes = Float(Int(r(6, 9)))
                // Rows: crown (near the trunk, above), mid, drooping tips, underside back to the trunk.
                let rows: [(rf: Float, dy: Float, lobed: Bool)] = hi
                    ? [(0.08, spacing * 1.25, false), (0.55, spacing * 0.35, true), (1.0, -droop * 0.75, true), (0.82, -droop, true), (0.15, -droop * 0.25, false)]
                    : [(0.08, spacing * 1.2, false), (1.0, -droop * 0.7, true), (0.2, -droop * 0.3, false)]
                m.addGrid(rows: rows.count, cols: segs, wrap: true, material: { _ in Material.needles }, point: { i, j in
                    let a = Float(j) / Float(segs) * 2 * .pi
                    let row = rows[rows.count - 1 - i]       // bottom → top so normals face outwards
                    let lobe: Float = row.lobed ? 1 + 0.2 * sin(lobes * a + phase) + 0.1 * noise3(V3(cos(a) * 3, Float(k), sin(a) * 3), seed: Int(seed % 997)) : 1
                    let rr = R * row.rf * lobe
                    return V3(rr * cos(a), y + row.dy, -rr * sin(a))
                }, uv: { i, j in V2(Float(j) / Float(segs), Float(i)) })
            }
            let dark = rgb(0x1E3A22), light = rgb(0x3F6B3A), tip = rgb(0x5C8A45)
            let tintShift = r(0.88, 1.1)
            m.colorize(from: start) { p, n in
                let radial = (p.x * p.x + p.z * p.z).squareRoot()
                let height = p.y / H
                var c = mix4(dark, light, 0.25 + height * 0.5 + n.y * 0.25)
                c = mix4(c, tip, (radial / max(0.5, 0.3 * H * (1 - height))) - 0.75)
                return SIMD4(c.x * tintShift, c.y * tintShift, c.z * tintShift, 1)
            }

        case .broadleaf:
            let H = r(10, 16)
            let crownY = H * 0.62
            trunk(height: crownY + 1, base: 0.3 * H / 13, top: 0.16, lean: V3(r(-0.4, 0.4), 0, r(-0.4, 0.4)))
            if hi {
                for b in 0..<4 {
                    let a = Float(b) / 4 * 2 * .pi + r(0, 1)
                    let p0 = V3(0, H * r(0.38, 0.5), 0)
                    let p1 = p0 + V3(cos(a) * H * 0.18, H * 0.2, sin(a) * H * 0.18)
                    m.tube(path: [p0, p0 + (p1 - p0) * 0.5 + V3(0, 0.5, 0), p1], radius: { t in mixf(0.12, 0.04, t) }, sides: 5,
                           material: Material.bark, caps: false)
                }
            }
            let start = m.vertexCount
            let blobs = hi ? 9 : (mid ? 5 : 2)
            let crownR = H * r(0.3, 0.38)
            for b in 0..<blobs {
                let a = Float(b) * 2.4 + r(0, 0.5)
                let rr = b == 0 ? 0 : crownR * r(0.35, 0.65)
                let c = V3(cos(a) * rr, crownY + r(-0.1, 0.35) * crownR + (b == 0 ? crownR * 0.25 : 0), sin(a) * rr)
                let size = crownR * (b == 0 ? 0.75 : r(0.45, 0.62))
                let s = Int(seed % 10_000) + b
                m.icosphere(center: c, radius: size, subdivisions: hi ? 2 : 1, material: Material.leaves,
                            scale: V3(1, r(0.75, 0.95), 1)) { d in 0.22 * fbm3(d * 2.2, seed: s) }
            }
            let shade = r(0.85, 1.12)
            let base = [rgb(0x3E6B2A), rgb(0x4C7A30), rgb(0x56803A), rgb(0x5E7F32)][Int(rng.next() % 4)]
            m.colorize(from: start) { p, n in
                let h = (p.y - crownY + crownR) / (2.2 * crownR)
                let ao: Float = 0.55 + 0.45 * max(0, min(1, h * 0.8 + n.y * 0.35 + 0.15))
                return SIMD4(base.x * ao * shade, base.y * ao * shade, base.z * ao * shade, 1)
            }

        case .poplar:
            let H = r(16, 24)
            trunk(height: H * 0.4, base: 0.22, top: 0.12)
            let start = m.vertexCount
            m.icosphere(center: V3(0, H * 0.58, 0), radius: 1, subdivisions: hi ? 2 : 1, material: Material.leaves,
                        scale: V3(H * 0.09, H * 0.42, H * 0.09)) { d in 0.18 * fbm3(d * 3, seed: Int(seed % 777)) }
            m.colorize(from: start) { p, n in
                let ao: Float = 0.55 + 0.45 * max(0, min(1, p.y / H + n.x * 0.15))
                let c = rgb(0x426E2E)
                return SIMD4(c.x * ao, c.y * ao, c.z * ao, 1)
            }

        case .cypress:
            let H = r(9, 15)
            trunk(height: H * 0.2, base: 0.14, top: 0.1)
            let start = m.vertexCount
            m.icosphere(center: V3(0, H * 0.52, 0), radius: 1, subdivisions: hi ? 2 : 1, material: Material.needles,
                        scale: V3(H * 0.075, H * 0.5, H * 0.075)) { d in 0.15 * fbm3(d * 4, seed: Int(seed % 555)) - (d.y > 0.6 ? (d.y - 0.6) * 0.8 : 0) }
            m.colorize(from: start) { p, _ in
                let c = rgb(0x253F24)
                let ao: Float = 0.7 + 0.3 * min(1, p.y / H)
                return SIMD4(c.x * ao, c.y * ao, c.z * ao, 1)
            }

        case .stonePine:
            let H = r(12, 18)
            let lean = V3(r(-1.2, 1.2), 0, r(-1.2, 1.2))
            trunk(height: H * 0.78, base: 0.28, top: 0.14, lean: lean, bend: 0.4)
            let start = m.vertexCount
            let top = V3(0, H * 0.82, 0) + lean
            let blobs = hi ? 7 : (mid ? 4 : 1)
            for b in 0..<blobs {
                let a = Float(b) * 2.1 + r(0, 0.7)
                let rr = b == 0 ? 0 : H * r(0.15, 0.27)
                m.icosphere(center: top + V3(cos(a) * rr, r(-0.2, 0.5), sin(a) * rr), radius: H * r(0.18, 0.24), subdivisions: hi ? 2 : 1,
                            material: Material.needles, scale: V3(1, 0.42, 1)) { d in 0.15 * fbm3(d * 3, seed: Int(seed % 333) + b) }
            }
            m.colorize(from: start) { p, n in
                let c = rgb(0x3B5A2C)
                let ao: Float = 0.55 + 0.45 * max(0, n.y)
                return SIMD4(c.x * ao, c.y * ao, c.z * ao, 1)
            }

        case .olive:
            let H = r(4, 6.5)
            for k in 0..<(hi ? 3 : 1) {
                let a = Float(k) * 2.1
                m.tube(path: [V3(cos(a) * 0.1, 0, sin(a) * 0.1), V3(cos(a) * 0.35, H * 0.25, sin(a) * 0.3), V3(cos(a) * 0.6, H * 0.45, sin(a) * 0.6)],
                       radius: { t in mixf(0.2, 0.08, t) }, sides: barkSides, material: Material.bark, caps: false)
            }
            let start = m.vertexCount
            for b in 0..<(hi ? 6 : (mid ? 3 : 1)) {
                let a = Float(b) * 2.3 + r(0, 0.6)
                let rr = b == 0 ? 0 : H * 0.28
                m.icosphere(center: V3(cos(a) * rr, H * r(0.6, 0.78), sin(a) * rr), radius: H * r(0.26, 0.34), subdivisions: hi ? 2 : 1,
                            material: Material.leaves, scale: V3(1, 0.7, 1)) { d in 0.25 * fbm3(d * 2.5, seed: Int(seed % 444) + b) }
            }
            m.colorize(from: start) { p, n in
                let c = rgb(0x7C8A5A)
                let ao: Float = 0.6 + 0.4 * max(0, n.y * 0.6 + 0.4)
                return SIMD4(c.x * ao, c.y * ao, c.z * ao, 1)
            }

        case .palm:
            let H = r(8, 13)
            let lean = V3(r(-1, 1), 0, r(-1, 1))
            trunk(height: H, base: 0.26, top: 0.2, lean: lean)
            let crown = V3(0, H, 0) + lean
            let fronds = hi ? 12 : (mid ? 7 : 4)
            for f in 0..<fronds {
                let a = Float(f) / Float(fronds) * 2 * .pi + r(0, 0.3)
                let dir = V3(cos(a), 0, sin(a))
                let len = r(3.2, 4.5)
                let lift = r(0.2, 0.9)
                let steps = hi ? 6 : 3
                let path = (0...steps).map { k -> V3 in
                    let t = Float(k) / Float(steps)
                    return crown + dir * (len * t) + V3(0, lift * t * 2 - t * t * (lift * 2 + 1.4), 0)
                }
                m.loft(path: path, up: V3(0, 1, 0), section: { _, t in
                    let w = 0.75 * sin(min(1, t * 1.3) * .pi) + 0.05
                    // A shallow V-shaped blade (folded along the rib).
                    return [SIMD2(-w, 0.12 * w), SIMD2(0, -0.02), SIMD2(w, 0.12 * w), SIMD2(0, 0.02)]
                }, material: { _ in Material.palm })
            }
        }
        return m
    }

    // MARK: - Realistic foliage (cards over a solid core)

    /// The parts of a close-up tree: `core` is the trunk, branches and a shrunken, darker
    /// solid canopy (it casts the shadow and fills gaps); `cards` are alpha-textured
    /// sprays of needles or leaves scattered over the canopy surface (render double-sided,
    /// alpha-tested, without shadows).
    public struct TreeParts: Sendable {
        public var core: ModelMesh
        public var cards: ModelMesh
    }

    public static func realisticTree(_ kind: TreeKind, seed: UInt64) -> TreeParts {
        let solid = tree(kind, seed: seed, detail: 1)
        var rng = SplitMix64(seed: seed ^ 0xC0FFEE)
        func r(_ a: Float, _ b: Float) -> Float { Float(rng.range(Double(a), Double(b))) }
        let foliageNames: Set<String> = [Material.leaves, Material.needles]
        // Which vertices belong to the canopy?
        var isFoliage = [Bool](repeating: false, count: solid.vertexCount)
        for part in solid.parts where foliageNames.contains(part.material) {
            for i in part.indices { isFoliage[Int(i)] = true }
        }
        let foliageIdx = (0..<solid.vertexCount).filter { isFoliage[$0] }
        if kind == .palm || foliageIdx.isEmpty { return TreeParts(core: solid, cards: ModelMesh()) }

        // Shrink the solid canopy towards each crown's middle and darken it: it becomes the
        // shadowed interior that the cards poke out of.
        var core = solid
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in foliageIdx {
            let p = solid.positions[i]
            lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        let crownCentre = (lo + hi) / 2
        let height = hi.y
        let shrink: Float = kind == .spruce ? 0.66 : (kind == .cypress || kind == .poplar ? 0.78 : 0.74)
        for i in foliageIdx {
            let p = solid.positions[i]
            let axis = kind == .spruce || kind == .cypress || kind == .poplar ? SIMD3(0, p.y, 0) : crownCentre
            core.positions[i] = axis + (p - axis) * shrink
            core.colors[i] = core.colors[i] * SIMD4(0.78, 0.8, 0.76, 1)
        }

        // Cards.
        let material: String
        let count: Int
        let size: (Float, Float)
        switch kind {
        case .spruce: material = Material.needleCard; count = 480; size = (1.2, 1.9)
        case .cypress: material = Material.needleCard; count = 160; size = (1.0, 1.5)
        case .stonePine: material = Material.needleCard; count = 220; size = (2.0, 3.0)
        case .olive: material = Material.oliveCard; count = 130; size = (1.3, 1.9)
        case .poplar: material = Material.leafCard; count = 200; size = (1.5, 2.2)
        case .broadleaf, .palm: material = Material.leafCard; count = 280; size = (2.2, 3.2)
        }
        var cards = ModelMesh()
        let up = SIMD3<Float>(0, 1, 0)
        for _ in 0..<count {
            let i = foliageIdx[Int(rng.next() % UInt64(foliageIdx.count))]
            let p = solid.positions[i]
            var n = solid.normals[i]
            if n.norm < 0.5 { n = up }
            let s = r(size.0, size.1) * max(0.6, height / 15)
            let radial = SIMD3(p.x, 0, p.z)
            // Spruce fronds droop outwards; leaf sprays are oriented at random.
            var along: SIMD3<Float>
            if kind == .spruce || kind == .stonePine {
                along = (radial.norm > 0.01 ? radial.unit : SIMD3(1, 0, 0)) + SIMD3(0, -0.45, 0)
            } else {
                let a = r(0, 6.28)
                along = SIMD3(cos(a), r(-0.3, 0.6), sin(a))
            }
            along = (along - n * along.dotp(n)).unit
            let side = n.crossp(along).unit
            let centre = p + n * (s * r(0.05, 0.25)) + along * (s * 0.25)
            // Light the card as part of the crown, not as a flat plane.
            let shadeN = (n * 0.75 + up * 0.25).unit
            let base = UInt32(cards.vertexCount)
            let corners: [(Float, Float)] = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
            let pts = corners.map { centre + side * ($0.0 * s) + along * ($0.1 * s) }
            // Never let a low frond dip into the ground.
            let lift = max(0, 0.25 - pts.map(\.y).min()!)
            for (k, (u, v)) in corners.enumerated() {
                cards.addVertex(pts[k] + SIMD3(0, lift, 0), shadeN, SIMD2(u + 0.5, v + 0.5))
            }
            cards.addIndices([base, base + 1, base + 2, base, base + 2, base + 3], material: material)
        }
        // Colour: darker low down and inside the crown, sun-bleached at the top; random hue shift.
        let tintR = r(0.9, 1.1), tintG = r(0.92, 1.08)
        cards.colorize { p, n in
            let h = max(0, min(1, p.y / max(height, 1)))
            let light: Float = 0.62 + 0.38 * max(0, min(1, h * 0.7 + n.y * 0.3 + 0.1))
            return SIMD4(light * tintR, light * tintG, light, 1)
        }
        return TreeParts(core: core, cards: cards)
    }

    /// A clump of grass: three crossed alpha cards with the grass texture.
    public static func grassClump(seed: UInt64, height: Float = 0.45, dry: Bool = false) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let start = Float(rng.range(0, 3.14))
        for k in 0..<3 {
            let a = start + Float(k) * .pi / 3
            let d = SIMD3<Float>(cos(a), 0, sin(a))
            let w = Float(rng.range(0.55, 0.9)), h = height * Float(rng.range(0.75, 1.25))
            let lean = SIMD3<Float>(-sin(a), 0, cos(a)) * Float(rng.range(-0.08, 0.08))
            let n = SIMD3<Float>(0, 1, 0)
            let b = UInt32(m.vertexCount)
            m.addVertex(-d * (w / 2), n, SIMD2(0, 0))
            m.addVertex(d * (w / 2), n, SIMD2(1, 0))
            m.addVertex(d * (w / 2) + lean + SIMD3(0, h, 0), n, SIMD2(1, 1))
            m.addVertex(-d * (w / 2) + lean + SIMD3(0, h, 0), n, SIMD2(0, 1))
            m.addIndices([b, b + 1, b + 2, b, b + 2, b + 3], material: Material.grassCard)
        }
        let shade = Float(rng.range(0.62, 0.9))
        let tint: SIMD4<Float> = dry ? SIMD4(1.1, 0.98, 0.72, 1) * shade : SIMD4(Float(rng.range(0.85, 1.05)), Float(rng.range(0.85, 1.0)), Float(rng.range(0.7, 0.95)), 1) * shade
        m.colorize { p, _ in
            let ao: Float = 0.5 + 0.5 * min(1, p.y / 0.4)
            return SIMD4(tint.x * ao, tint.y * ao, tint.z * ao, 1)
        }
        return m
    }

    // MARK: - Rocks

    public static func rock(seed: UInt64, detail: Float = 1) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let s = Int(seed % 9973)
        let flat = Float(rng.range(0.45, 0.85))
        m.icosphere(center: .zero, radius: 1, subdivisions: detail >= 0.75 ? 3 : (detail >= 0.4 ? 2 : 1), material: Material.rock,
                    scale: V3(Float(rng.range(0.8, 1.3)), flat, Float(rng.range(0.8, 1.3)))) { d in
            // Blocky, fractured shape: noise plus a few planar cuts.
            let n = 0.28 * fbm3(d * 1.8, seed: s, octaves: 4)
            let cut = max(0, d.dotp(V3(0.6, 0.3, 0.74).unit) - 0.55) * 0.8
            return n - cut
        }
        let grey = Float(rng.range(0.42, 0.62)), warm = Float(rng.range(-0.03, 0.05))
        m.colorize { p, n in
            let strata = 0.06 * sin(p.y * 9 + Float(s))
            var c = SIMD4<Float>(grey + warm + strata, grey + strata, grey - warm + strata, 1)
            // Lichen on top.
            if n.y > 0.55 && noise3(p * 3, seed: s) > 0.1 { c = mix4(c, rgb(0x8A8E52), 0.45) }
            return c
        }
        return m
    }

    // MARK: - Buildings

    public enum HouseStyle: String, CaseIterable, Sendable {
        case chalet, farmhouse, mediterranean, townhouse, apartment, brick
    }

    /// A building standing on the origin (ground at y = 0, extended down by `foundation`),
    /// `width` along X, `depth` along Z. Walls use metre UVs (u = metres / 3 per window bay,
    /// v = metres / 3 per storey) so a facade texture tiles one window per bay and storey.
    public static func house(_ style: HouseStyle, width w: Float, depth d: Float, floors: Int, foundation: Float = 0,
                             wallColor: SIMD4<Float>, roofColor: SIMD4<Float>, seed: UInt64) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let storey: Float = 3.0
        let wallH = Float(floors) * storey + 0.4
        let x0 = -w / 2, x1 = w / 2, z0 = -d / 2, z1 = d / 2
        let yb = -foundation
        // Walls (each face its own quad strip with metre UVs).
        func wall(_ a: V3, _ b: V3, height: Float, material: String, tint: SIMD4<Float>, gableTop: Float = 0) {
            let base = UInt32(m.vertexCount)
            let along = b - a
            let len = along.norm
            let n = V3(-along.z, 0, along.x).unit
            m.addVertex(a + V3(0, yb, 0), n, V2(0, yb / storey))
            m.addVertex(b + V3(0, yb, 0), n, V2(len / 3, yb / storey))
            m.addVertex(b + V3(0, height, 0), n, V2(len / 3, height / storey))
            m.addVertex(a + V3(0, height, 0), n, V2(0, height / storey))
            m.addIndices([base, base + 1, base + 2, base, base + 2, base + 3], material: material)
            if gableTop > 0 {
                let mid = (a + b) / 2 + V3(0, height + gableTop, 0)
                let g = m.addVertex(mid, n, V2(len / 6, (height + gableTop) / storey))
                m.addIndices([base + 3, base + 2, g], material: material)
            }
            for k in Int(base)..<m.vertexCount { m.colors[k] = tint }
        }
        let wallMat = style == .brick ? "\(Material.wall).brick" : "\(Material.wall).\(style.rawValue)"
        let pitch: Float
        let overhang: Float
        switch style {
        case .chalet: pitch = 0.32; overhang = 1.1
        case .farmhouse: pitch = 0.55; overhang = 0.5
        case .brick: pitch = 0.75; overhang = 0.25
        case .townhouse: pitch = 0.6; overhang = 0.3
        case .mediterranean: pitch = 0.28; overhang = 0.45
        case .apartment: pitch = 0; overhang = 0
        }
        // Ridge runs along the longer side.
        let ridgeAlongX = w >= d
        let span = ridgeAlongX ? d : w
        let rise = span / 2 * pitch
        let gable = style != .mediterranean && style != .apartment
        let corners = [V3(x0, 0, z1), V3(x1, 0, z1), V3(x1, 0, z0), V3(x0, 0, z0)]   // counter-clockwise from above
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let isGableEnd = gable && (ridgeAlongX ? (k == 1 || k == 3) : (k == 0 || k == 2))
            wall(a, b, height: wallH, material: wallMat, tint: wallColor, gableTop: isGableEnd ? rise : 0)
        }
        // Plinth band.
        let plinth = rgb(0x6E6A62)
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let out = V3(-(b - a).z, 0, (b - a).x).unit * 0.04
            let base = UInt32(m.vertexCount)
            m.addVertex(a + out + V3(0, yb, 0), out.unit)
            m.addVertex(b + out + V3(0, yb, 0), out.unit)
            m.addVertex(b + out + V3(0, 0.45, 0), out.unit)
            m.addVertex(a + out + V3(0, 0.45, 0), out.unit)
            m.addIndices([base, base + 1, base + 2, base, base + 2, base + 3], material: Material.plinth)
            for i in Int(base)..<m.vertexCount { m.colors[i] = plinth }
        }
        // Roof.
        let roofStart = m.vertexCount
        let ov = overhang
        if style == .apartment {
            // Flat roof with a parapet.
            m.box(center: V3(0, wallH + 0.05, 0), size: V3(w + 0.1, 0.1, d + 0.1), material: Material.roof)
            for (c, s) in [(V3(0, wallH + 0.45, z0), V3(w + 0.2, 0.8, 0.25)), (V3(0, wallH + 0.45, z1), V3(w + 0.2, 0.8, 0.25)),
                           (V3(x0, wallH + 0.45, 0), V3(0.25, 0.8, d)), (V3(x1, wallH + 0.45, 0), V3(0.25, 0.8, d))] {
                m.box(center: c, size: s, material: Material.trim)
            }
            if Scenery.chance(&rng, 0.6) {
                m.box(center: V3(Float(rng.range(-0.25, 0.25)) * w, wallH + 1.1, Float(rng.range(-0.25, 0.25)) * d), size: V3(2.2, 2, 2.2),
                      material: Material.trim)
            }
        } else if gable {
            let half = span / 2 + ov
            let len = (ridgeAlongX ? w : d) / 2 + ov * 0.6
            let eave = wallH - ov * pitch
            let ridge = wallH + rise
            for side: Float in [-1, 1] {
                // Each slope: eave edge → ridge, with a little thickness.
                let p = { (along: Float, across: Float, y: Float) -> V3 in
                    ridgeAlongX ? V3(along, y, across) : V3(across, y, along)
                }
                let eA = p(-len, side * half, eave), eB = p(len, side * half, eave)
                let rA = p(-len, 0, ridge), rB = p(len, 0, ridge)
                let n = (eB - eA).crossp(rA - eA).unit * (side * (ridgeAlongX ? -1 : 1))
                let nn = n.y < 0 ? n * -1 : n
                let base = UInt32(m.vertexCount)
                let slopeLen = (rA - eA).norm
                m.addVertex(eA, nn, V2(0, 0))
                m.addVertex(eB, nn, V2(2 * len / 1.5, 0))
                m.addVertex(rB, nn, V2(2 * len / 1.5, slopeLen / 1.5))
                m.addVertex(rA, nn, V2(0, slopeLen / 1.5))
                let tri: [UInt32] = (eB - eA).crossp(rA - eA).dotp(nn) > 0 ? [0, 1, 2, 0, 2, 3] : [0, 2, 1, 0, 3, 2]
                m.addIndices(tri.map { base + $0 }, material: Material.roof)
                // Underside of the overhang.
                let base2 = UInt32(m.vertexCount)
                let down = nn * -1
                for v in [eA, eB, rB, rA] { m.addVertex(v - V3(0, 0.12, 0), down, .zero) }
                let under: [UInt32] = tri == [0, 1, 2, 0, 2, 3] ? [0, 2, 1, 0, 3, 2] : [0, 1, 2, 0, 2, 3]
                m.addIndices(under.map { base2 + $0 }, material: Material.wood)
                // Fascia board along the eave.
                m.box(center: (eA + eB) / 2 - V3(0, 0.08, 0), size: ridgeAlongX ? V3(2 * len, 0.18, 0.05) : V3(0.05, 0.18, 2 * len),
                      material: Material.wood)
            }
            // Chimney.
            if style != .chalet || Scenery.chance(&rng, 0.5) {
                let cx = Float(rng.range(-0.3, 0.3)) * (ridgeAlongX ? w : 0), cz = Float(rng.range(-0.3, 0.3)) * (ridgeAlongX ? 0 : d)
                m.box(center: V3(cx, ridge + 0.3, cz), size: V3(0.6, 1.6, 0.6), material: Material.trim)
            }
        } else {
            // Hip roof (four shallow slopes meeting at a short ridge).
            let hx = w / 2 + ov, hz = d / 2 + ov
            let eave = wallH - ov * pitch
            let rise2 = min(w, d) / 2 * pitch
            let rl = max(0, (ridgeAlongX ? w - d : d - w) / 2)
            let r0 = ridgeAlongX ? V3(-rl, wallH + rise2, 0) : V3(0, wallH + rise2, -rl)
            let r1 = ridgeAlongX ? V3(rl, wallH + rise2, 0) : V3(0, wallH + rise2, rl)
            let e = [V3(-hx, eave, hz), V3(hx, eave, hz), V3(hx, eave, -hz), V3(-hx, eave, -hz)]
            // Faces: front (z+), right (x+), back (z−), left (x−).
            let faces: [[V3]] = ridgeAlongX
                ? [[e[0], e[1], r1, r0], [e[1], e[2], r1], [e[2], e[3], r0, r1], [e[3], e[0], r0]]
                : [[e[0], e[1], r1], [e[1], e[2], r0, r1], [e[2], e[3], r0], [e[3], e[0], r1, r0]]
            for f in faces {
                var n = (f[1] - f[0]).crossp(f[2] - f[0]).unit
                if n.y < 0 { n = n * -1 }
                let base = UInt32(m.vertexCount)
                for v in f { m.addVertex(v, n, V2(v.x / 1.5 + v.z / 1.5, v.y / 1.5)) }
                let ccw = (f[1] - f[0]).crossp(f[2] - f[0]).dotp(n) > 0
                var idx: [UInt32] = ccw ? [0, 1, 2] : [0, 2, 1]
                if f.count == 4 { idx += ccw ? [0, 2, 3] : [0, 3, 2] }
                m.addIndices(idx.map { base + $0 }, material: Material.roof)
            }
        }
        for k in roofStart..<m.vertexCount where m.colors[k] == SIMD4(1, 1, 1, 1) { m.colors[k] = roofColor }

        // Alpine chalet: wooden balcony along the front at first-floor level.
        if style == .chalet && floors >= 2 {
            let y = storey + 0.3
            let len = ridgeAlongX ? w : d
            let dir: V3 = ridgeAlongX ? V3(1, 0, 0) : V3(0, 0, 1)
            let out: V3 = ridgeAlongX ? V3(0, 0, z1 + 0.6) : V3(x1 + 0.6, 0, 0)
            let start = m.vertexCount
            m.box(center: out + V3(0, y, 0), size: ridgeAlongX ? V3(len, 0.15, 1.2) : V3(1.2, 0.15, len), material: Material.wood)
            m.box(center: out * 1.0 + (ridgeAlongX ? V3(0, 0, 0.55) : V3(0.55, 0, 0)) + V3(0, y + 0.55, 0),
                  size: ridgeAlongX ? V3(len, 0.9, 0.06) : V3(0.06, 0.9, len), material: Material.wood)
            _ = dir
            for k in start..<m.vertexCount { m.colors[k] = rgb(0x7A4A28) }
        }
        return m
    }

    // MARK: - Spectators

    public enum SpectatorPose: CaseIterable, Sendable { case standing, cheering, clapping, flag, phone }

    /// A spectator facing −Z (towards the road when rotated), ~1.75 m tall.
    public static func spectator(pose: SpectatorPose, shirt: SIMD4<Float>, trousers: SIMD4<Float>, skin: SIMD4<Float>,
                                 flag: SIMD4<Float> = SIMD4(0.84, 0.16, 0.16, 1), seed: UInt64, detail: Float = 0.6) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let sides = detail >= 0.75 ? 10 : 6
        let h = Float(rng.range(0.92, 1.06))
        let girth = Float(rng.range(0.9, 1.2))
        func limb(_ a: V3, _ b: V3, _ r0: Float, _ r1: Float, _ c: SIMD4<Float>) {
            let start = m.vertexCount
            m.tube(path: [a, b], radius: { t in mixf(r0, r1, t) }, sides: sides, material: Material.person)
            for k in start..<m.vertexCount { m.colors[k] = c }
        }
        // Legs.
        for s: Float in [-1, 1] {
            limb(V3(s * 0.1, 0.95 * h, 0), V3(s * 0.11, 0.05, 0.02), 0.075 * girth, 0.05, trousers)
            let st = m.vertexCount
            m.box(center: V3(s * 0.11, 0.04, -0.05), size: V3(0.1, 0.08, 0.26), material: Material.person)
            for k in st..<m.vertexCount { m.colors[k] = rgb(0x2A2A2A) }
        }
        // Torso.
        let start = m.vertexCount
        m.loft(path: [V3(0, 0.9 * h, 0), V3(0, 1.2 * h, 0), V3(0, 1.48 * h, 0)], up: V3(0, 0, 1), section: { i, _ in
            let w: [Float] = [0.36, 0.34, 0.42]
            let dd: [Float] = [0.24, 0.22, 0.22]
            return Section.superellipse(w[i] * girth, dd[i] * girth, exponent: 2.4, count: sides + 2)
        }, material: { _ in Material.person }, capStart: true, capEnd: true)
        for k in start..<m.vertexCount { m.colors[k] = shirt }
        // Head (and sometimes a cap).
        let hs = m.vertexCount
        m.ellipsoid(center: V3(0, 1.62 * h, 0), radii: V3(0.095, 0.115, 0.105), rings: sides / 2 + 1, segments: sides, material: Material.person)
        for k in hs..<m.vertexCount { m.colors[k] = skin }
        if Scenery.chance(&rng, 0.4) {
            let cs = m.vertexCount
            m.ellipsoid(center: V3(0, 1.69 * h, 0.0), radii: V3(0.1, 0.06, 0.11), rings: 3, segments: sides, material: Material.person)
            m.box(center: V3(0, 1.67 * h, -0.12), size: V3(0.16, 0.02, 0.1), material: Material.person)
            let capColor = [rgb(0xF4D35E), rgb(0xD62828), rgb(0xFFFFFF), rgb(0x1D3557)][Int(rng.next() % 4)]
            for k in cs..<m.vertexCount { m.colors[k] = capColor }
        }
        // Arms by pose.
        let sh = 1.45 * h
        for s: Float in [-1, 1] {
            let shoulder = V3(s * 0.2 * girth, sh, 0)
            let hand: V3
            switch pose {
            case .standing: hand = V3(s * 0.26, 0.85 * h, 0.02)
            case .cheering: hand = V3(s * 0.42, 2.05 * h, -0.05)
            case .clapping: hand = V3(s * 0.04, 1.3 * h, -0.3)
            case .flag: hand = s > 0 ? V3(0.3, 2.0 * h, -0.05) : V3(-0.26, 0.85 * h, 0.02)
            case .phone: hand = s > 0 ? V3(0.12, 1.6 * h, -0.32) : V3(-0.26, 0.85 * h, 0.02)
            }
            let elbow = (shoulder + hand) / 2 + V3(s * 0.08, -0.05, 0.06)
            limb(shoulder, elbow, 0.055, 0.045, shirt)
            limb(elbow, hand, 0.042, 0.035, skin)
            if pose == .flag && s > 0 {
                limb(hand + V3(0, -0.3, 0), hand + V3(0, 1.1, 0), 0.012, 0.012, rgb(0xDDDDDD))
                let fs = m.vertexCount
                let top = hand + V3(0, 1.08, 0)
                let base = UInt32(m.vertexCount)
                for v in [top, top + V3(0.05, 0, 0.75), top + V3(0.05, -0.5, 0.75), top + V3(0, -0.5, 0)] {
                    m.addVertex(v, V3(1, 0, 0), V2(v.z / 0.75, (v.y - top.y + 0.5) / 0.5))
                }
                m.addIndices([base, base + 1, base + 2, base, base + 2, base + 3], material: Material.flag)
                for k in fs..<m.vertexCount { m.colors[k] = flag }
            }
        }
        return m
    }

    // MARK: - Vehicles

    /// A camper van (the classic Tour roadside grandstand), facing +Z, wheels on y = 0.
    public static func campervan(color: SIMD4<Float>, seed: UInt64) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let L = Float(rng.range(5.6, 6.8)), W: Float = 2.25, H = Float(rng.range(2.7, 3.0))
        let start = m.vertexCount
        // Body: rounded box lofted front to back with a sloping cab.
        let steps = 10
        let path = (0...steps).map { V3(0, 0, -L / 2 + L * Float($0) / Float(steps)) }
        m.loft(path: path, up: V3(0, 1, 0), section: { i, t in
            let cab = max(0, t - 0.78) / 0.22                       // the cab at the +Z end is lower
            let top = H - cab * cab * 1.0
            let hh = top - 0.45
            return Section.superellipse(W, hh, exponent: 6, count: 16).map { SIMD2($0.x, $0.y + 0.45 + hh / 2) }
        }, material: { _ in Material.vehicle }, capStart: true, capEnd: true)
        for k in start..<m.vertexCount { m.colors[k] = color }
        // Window band and windscreen.
        let ws = m.vertexCount
        m.box(center: V3(0, H * 0.7, -0.2), size: V3(W + 0.02, 0.45, L * 0.5), material: Material.glass)
        m.box(center: V3(0, H * 0.68 - 0.3, L / 2 - 0.25), size: V3(W - 0.2, 0.7, 0.3), material: Material.glass)
        for k in ws..<m.vertexCount { m.colors[k] = rgb(0x22303A) }
        // Stripe.
        let ss = m.vertexCount
        m.box(center: V3(0, 1.05, 0), size: V3(W + 0.03, 0.12, L * 0.92), material: Material.vehicle)
        let stripe = [rgb(0x2A6FDB), rgb(0xD62828), rgb(0x2A9D8F), rgb(0x7A5230)][Int(rng.next() % 4)]
        for k in ss..<m.vertexCount { m.colors[k] = stripe }
        // Wheels.
        for (x, z) in [(Float(-1), -L * 0.32), (1, -L * 0.32), (-1, L * 0.33), (1, L * 0.33)] {
            let st = m.vertexCount
            m.tube(path: [V3(x * (W / 2 - 0.12), 0.36, z), V3(x * (W / 2 + 0.02), 0.36, z)], radius: { _ in 0.36 }, sides: 12,
                   material: Material.tyre)
            for k in st..<m.vertexCount { m.colors[k] = rgb(0x1A1A1A) }
        }
        return m
    }

    // MARK: - Ground cover

    /// A tuft of grass blades (single-sided triangles; render double-sided), optionally with flowers.
    public static func grassTuft(seed: UInt64, flowers: Bool, dry: Bool = false) -> ModelMesh {
        var rng = SplitMix64(seed: seed)
        var m = ModelMesh()
        let blades = Int(rng.range(5, 9))
        let base = dry ? rgb(0x6E6A3A) : rgb(0x2F5220)
        let tip = dry ? rgb(0xB7A867) : rgb(0x8AA84A)
        for _ in 0..<blades {
            let a = Float(rng.range(0, 6.28))
            let off = V3(cos(a), 0, sin(a)) * Float(rng.range(0, 0.12))
            let h = Float(rng.range(0.18, 0.42))
            let bend = V3(cos(a), 0, sin(a)) * Float(rng.range(0.05, 0.16))
            let side = V3(-sin(a), 0, cos(a)) * 0.018
            let n = V3(cos(a), 0.6, sin(a)).unit
            let b = UInt32(m.vertexCount)
            m.addVertex(off - side, n)
            m.addVertex(off + side, n)
            m.addVertex(off + bend + V3(0, h, 0), n)
            m.colors[Int(b)] = base
            m.colors[Int(b) + 1] = base
            m.colors[Int(b) + 2] = tip
            m.addIndices([b, b + 1, b + 2], material: Material.grass)
        }
        if flowers {
            let c = [rgb(0xF4E04D), rgb(0xFFFFFF), rgb(0xB57EDC), rgb(0xE85D75), rgb(0x5B8DEF)][Int(rng.next() % 5)]
            for _ in 0..<Int(rng.range(1, 4)) {
                let p = V3(Float(rng.range(-0.1, 0.1)), Float(rng.range(0.25, 0.4)), Float(rng.range(-0.1, 0.1)))
                let b = UInt32(m.vertexCount)
                for v in [p + V3(-0.03, 0, 0), p + V3(0.03, 0, 0), p + V3(0, 0.04, 0), p + V3(0, 0, 0.03)] {
                    m.addVertex(v, V3(0, 1, 0))
                    m.colors[m.vertexCount - 1] = c
                }
                m.addIndices([b, b + 1, b + 2, b, b + 3, b + 1], material: Material.grass)
            }
        }
        return m
    }
}
