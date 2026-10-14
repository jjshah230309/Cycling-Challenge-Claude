import Foundation

// Platform-independent procedural geometry. Models are generated here as plain
// vertex/index buffers (so they can be unit-tested and previewed on any OS) and
// converted to SceneKit geometry by the app.

typealias V3 = SIMD3<Float>
typealias V2 = SIMD2<Float>

extension SIMD3 where Scalar == Float {
    @inline(__always) func dotp(_ o: SIMD3<Float>) -> Float { x * o.x + y * o.y + z * o.z }
    @inline(__always) func crossp(_ o: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    @inline(__always) var norm: Float { (x * x + y * y + z * z).squareRoot() }
    var unit: SIMD3<Float> {
        let l = norm
        return l > 1e-12 ? self / l : SIMD3(0, 1, 0)
    }
}

@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mix3(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
@inline(__always) func smooth01(_ t: Float) -> Float {
    let c = max(0, min(1, t))
    return c * c * (3 - 2 * c)
}

/// An orthonormal frame + origin. Columns `x`, `y`, `z` are the local axes in parent space.
public struct RigidTransform: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var x: SIMD3<Float>
    public var y: SIMD3<Float>
    public var z: SIMD3<Float>

    public init(origin: SIMD3<Float> = .zero, x: SIMD3<Float> = SIMD3(1, 0, 0), y: SIMD3<Float> = SIMD3(0, 1, 0),
                z: SIMD3<Float> = SIMD3(0, 0, 1)) {
        self.origin = origin
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = RigidTransform()

    public static func translation(_ t: SIMD3<Float>) -> RigidTransform { RigidTransform(origin: t) }

    /// Rotation by `angle` radians about a unit `axis` (right-hand rule), then translation.
    public static func rotation(axis: SIMD3<Float>, angle: Float, origin: SIMD3<Float> = .zero) -> RigidTransform {
        let a = axis.unit
        let c = cos(angle), s = sin(angle), t = 1 - c
        let x = SIMD3<Float>(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y)
        let y = SIMD3<Float>(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x)
        let z = SIMD3<Float>(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c)
        return RigidTransform(origin: origin, x: x, y: y, z: z)
    }

    /// A bone frame: local +Y runs from `a` to `b`; local +X is as close to `side` as possible.
    public static func bone(from a: SIMD3<Float>, to b: SIMD3<Float>, side: SIMD3<Float> = SIMD3(1, 0, 0)) -> RigidTransform {
        let y = (b - a).unit
        var x = side - y * side.dotp(y)
        if x.norm < 1e-5 { x = SIMD3(0, 0, 1) - y * y.z }
        x = x.unit
        let z = x.crossp(y)
        return RigidTransform(origin: a, x: x, y: y, z: z)
    }

    public func apply(_ p: SIMD3<Float>) -> SIMD3<Float> { origin + x * p.x + y * p.y + z * p.z }
    public func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> { x * v.x + y * v.y + z * v.z }

    /// `self ∘ other`: apply `other` first, then `self`.
    public func then(_ other: RigidTransform) -> RigidTransform {
        // (self * other)(p) = self(other(p))
        RigidTransform(origin: apply(other.origin), x: rotate(other.x), y: rotate(other.y), z: rotate(other.z))
    }

    public var inverse: RigidTransform {
        // Transpose of the rotation.
        let ix = SIMD3<Float>(x.x, y.x, z.x), iy = SIMD3<Float>(x.y, y.y, z.y), iz = SIMD3<Float>(x.z, y.z, z.z)
        let r = RigidTransform(origin: .zero, x: ix, y: iy, z: iz)
        return RigidTransform(origin: -r.rotate(origin), x: ix, y: iy, z: iz)
    }

    /// Unit quaternion (x, y, z, w) for this rotation.
    public var quaternion: SIMD4<Float> {
        let m00 = x.x, m11 = y.y, m22 = z.z
        let tr = m00 + m11 + m22
        var q: SIMD4<Float>
        if tr > 0 {
            let s = (tr + 1).squareRoot() * 2
            q = SIMD4(( y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, 0.25 * s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            q = SIMD4(0.25 * s, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            q = SIMD4((y.x + x.y) / s, 0.25 * s, (z.y + y.z) / s, (z.x - x.z) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            q = SIMD4((z.x + x.z) / s, (z.y + y.z) / s, 0.25 * s, (x.y - y.x) / s)
        }
        let l = (q * q).sum().squareRoot()
        return q / l
    }
}

/// 2D cross-section helpers for lofts (points counter-clockwise; x = section side, y = section "up").
public enum Section {
    public static func ellipse(_ w: Float, _ h: Float, count: Int = 16, center: SIMD2<Float> = .zero) -> [SIMD2<Float>] {
        (0..<count).map { k in
            let a = Float(k) / Float(count) * 2 * .pi
            return center + SIMD2(cos(a) * w / 2, sin(a) * h / 2)
        }
    }

    /// Rounded rectangle-ish superellipse (exponent 2 = ellipse, larger = boxier).
    public static func superellipse(_ w: Float, _ h: Float, exponent: Float = 4, count: Int = 20) -> [SIMD2<Float>] {
        (0..<count).map { k in
            let a = Float(k) / Float(count) * 2 * .pi
            let c = cos(a), s = sin(a)
            let x = copysign(pow(abs(c), 2 / exponent), c), y = copysign(pow(abs(s), 2 / exponent), s)
            return SIMD2(x * w / 2, y * h / 2)
        }
    }

    /// Truncated aerofoil ("Kamm tail"): rounded leading edge at +y, chopped trailing edge at −y.
    /// `chord` along y, `thickness` along x.
    public static func kammtail(chord: Float, thickness: Float, truncation: Float = 0.25, count: Int = 20) -> [SIMD2<Float>] {
        (0..<count).map { k in
            let a = Float(k) / Float(count) * 2 * .pi
            let s = sin(a), c = cos(a)
            // Map the circle to a teardrop: front half round, rear half tapered then cut.
            let yRaw = s
            var y: Float, x: Float
            if yRaw >= 0 {
                y = yRaw * chord * 0.30
                x = c * thickness / 2
            } else {
                let t = -yRaw                                  // 0 at max thickness → 1 at tail
                y = -t * chord * 0.70
                let taper = 1 - t * (1 - truncation)
                x = c * thickness / 2 * taper
            }
            return SIMD2(x, y + chord * 0.2)
        }
    }

    /// Gear-tooth outline (outer edge of a chainring or sprocket), counter-clockwise.
    public static func gear(teeth: Int, pitchRadius r: Float, toothDepth: Float = 0.0045, pointsPerTooth: Int = 4) -> [SIMD2<Float>] {
        var pts: [SIMD2<Float>] = []
        let n = teeth * pointsPerTooth
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi
            let phase = k % pointsPerTooth
            // Root, flank, tip, flank.
            let rr: Float = phase == 0 ? r - toothDepth * 0.5 : (phase == 2 ? r + toothDepth * 0.5 : r)
            pts.append(SIMD2(cos(a) * rr, sin(a) * rr))
        }
        return pts
    }

    public static func circle(_ r: Float, count: Int) -> [SIMD2<Float>] { ellipse(2 * r, 2 * r, count: count) }
}

/// Indexed triangle mesh with named material parts.
public struct ModelMesh: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    /// Per-vertex colour (multiplied with the material); white unless tinted.
    public var colors: [SIMD4<Float>] = []
    public private(set) var parts: [(material: String, indices: [UInt32])] = []

    public init() {}

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { parts.reduce(0) { $0 + $1.indices.count / 3 } }
    public var materials: [String] { parts.map(\.material) }

    public func indices(for material: String) -> [UInt32] { parts.first { $0.material == material }?.indices ?? [] }

    mutating func addIndices(_ idx: [UInt32], material: String) {
        guard !idx.isEmpty else { return }
        if let i = parts.firstIndex(where: { $0.material == material }) {
            parts[i].indices += idx
        } else {
            parts.append((material, idx))
        }
    }

    @discardableResult
    mutating func addVertex(_ p: V3, _ n: V3, _ uv: V2 = .zero) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        colors.append(SIMD4(1, 1, 1, 1))
        return UInt32(positions.count - 1)
    }

    /// Appends another mesh, optionally transformed and with materials renamed.
    public mutating func append(_ other: ModelMesh, transform: RigidTransform = .identity, scale: SIMD3<Float> = SIMD3(1, 1, 1),
                                rename: [String: String] = [:], tint: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        let base = UInt32(positions.count)
        let uniform = scale.x == scale.y && scale.y == scale.z
        for i in 0..<other.positions.count {
            positions.append(transform.apply(other.positions[i] * scale))
            var n = other.normals[i]
            if !uniform { n = SIMD3(n.x / scale.x, n.y / scale.y, n.z / scale.z).unit }
            normals.append(transform.rotate(n))
            uvs.append(other.uvs[i])
            colors.append(other.colors[i] * tint)
        }
        for part in other.parts {
            addIndices(part.indices.map { $0 + base }, material: rename[part.material] ?? part.material)
        }
    }

    /// Recolours vertices from index `from` onwards.
    public mutating func colorize(from: Int = 0, _ f: (_ position: SIMD3<Float>, _ normal: SIMD3<Float>) -> SIMD4<Float>) {
        guard from < positions.count else { return }
        for i in from..<positions.count { colors[i] = f(positions[i], normals[i]) }
    }

    /// True when any vertex carries a colour other than white.
    public var hasVertexColors: Bool { colors.contains { $0 != SIMD4(1, 1, 1, 1) } }

    public func transformed(_ t: RigidTransform) -> ModelMesh {
        var m = ModelMesh()
        m.append(self, transform: t)
        return m
    }

    /// Axis-aligned bounds.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in positions {
            lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return (lo, hi)
    }

    // MARK: - Grid surfaces (the basis of lofts and lathes)

    /// Adds a smooth rows×cols grid surface. `point(i, j)` gives row `i` (along) and column `j` (around).
    /// With `wrap`, column `cols` repeats column 0 (a closed tube with a UV seam). Normals are
    /// computed from central differences, n = ∂P/∂u × ∂P/∂v, so generators must order columns
    /// counter-clockwise when looking back along the rows for outward-facing normals.
    mutating func addGrid(rows: Int, cols: Int, wrap: Bool, material: (Int) -> String,
                          point: (Int, Int) -> V3, uv: (Int, Int) -> V2) {
        guard rows >= 2, cols >= 2 else { return }
        let ncol = wrap ? cols + 1 : cols
        var P = [V3](repeating: .zero, count: rows * cols)
        for i in 0..<rows {
            for j in 0..<cols { P[i * cols + j] = point(i, j) }
        }
        func at(_ i: Int, _ j: Int) -> V3 {
            let ii = max(0, min(rows - 1, i))
            let jj = wrap ? ((j % cols) + cols) % cols : max(0, min(cols - 1, j))
            return P[ii * cols + jj]
        }
        var N = [V3](repeating: .zero, count: rows * cols)
        var degenerate = [Bool](repeating: false, count: rows * cols)
        for i in 0..<rows {
            for j in 0..<cols {
                let du = at(i, j + 1) - at(i, j - 1)
                let dv = at(i + 1, j) - at(i - 1, j)
                let n = du.crossp(dv)
                if n.norm < 1e-12 {
                    degenerate[i * cols + j] = true
                } else {
                    N[i * cols + j] = n.unit
                }
            }
        }
        // Poles (rings collapsed to a point): point the normal straight along the axis.
        for i in 0..<rows {
            for j in 0..<cols where degenerate[i * cols + j] {
                let inner = i == 0 ? 1 : i - 1
                let axis = at(i, j) - (0..<cols).reduce(V3.zero) { $0 + at(inner, $1) } / Float(cols)
                N[i * cols + j] = axis.norm > 1e-9 ? axis.unit : V3(0, 1, 0)
            }
        }
        let base = UInt32(positions.count)
        for i in 0..<rows {
            for j in 0..<ncol {
                let jj = j % cols
                addVertex(P[i * cols + jj], N[i * cols + jj], uv(i, j))
            }
        }
        var byMaterial: [String: [UInt32]] = [:]
        var order: [String] = []
        for i in 0..<(rows - 1) {
            let m = material(i)
            if byMaterial[m] == nil { order.append(m) }
            for j in 0..<(ncol - 1) {
                let a = base + UInt32(i * ncol + j), b = a + 1
                let d = base + UInt32((i + 1) * ncol + j), c = d + 1
                byMaterial[m, default: []] += [a, b, c, a, c, d]
            }
        }
        for m in order { addIndices(byMaterial[m]!, material: m) }
    }

    /// Flat polygon cap (fan from the centroid), facing `normal`.
    mutating func addCap(_ ring: [V3], normal: V3, material: String) {
        guard ring.count >= 3 else { return }
        let c = ring.reduce(V3.zero, +) / Float(ring.count)
        let base = UInt32(positions.count)
        addVertex(c, normal, V2(0.5, 0.5))
        for p in ring { addVertex(p, normal, V2(0.5, 0.5)) }
        var idx: [UInt32] = []
        // Orient triangles to face `normal`.
        let flip = (ring[1] - ring[0]).crossp(ring[2] - ring[1]).dotp(normal) < 0
        for k in 0..<ring.count {
            let a = base + 1 + UInt32(k), b = base + 1 + UInt32((k + 1) % ring.count)
            idx += flip ? [base, b, a] : [base, a, b]
        }
        addIndices(idx, material: material)
    }

    // MARK: - Lofts

    /// Sweeps cross-sections along a path using rotation-minimising frames (double reflection).
    ///
    /// - `section(i, t)`: the 2D outline for ring `i` (t = 0…1 by arc length). All rings must
    ///   have the same point count, counter-clockwise; section x maps to the frame's side axis,
    ///   section y to the `up` axis carried along the path.
    /// - `material(i)`: material of the band between ring `i` and `i + 1`.
    /// - `capStart` / `capEnd`: close the ends with flat caps.
    public mutating func loft(path: [SIMD3<Float>], up: SIMD3<Float>, section: (Int, Float) -> [SIMD2<Float>],
                              material: (Int) -> String, capStart: Bool = false, capEnd: Bool = false,
                              uvScale: Float = 1) {
        guard path.count >= 2 else { return }
        let frames = ModelMesh.frames(path: path, up: up)
        var arc: [Float] = [0]
        for k in 1..<path.count { arc.append(arc[k - 1] + (path[k] - path[k - 1]).norm) }
        let total = max(arc.last!, 1e-6)
        let sections = (0..<path.count).map { section($0, arc[$0] / total) }
        let cols = sections[0].count
        func point(_ i: Int, _ j: Int) -> V3 {
            let f = frames[i]
            let s = sections[i][j]
            return path[i] + f.side * s.x + f.up * s.y
        }
        addGrid(rows: path.count, cols: cols, wrap: true, material: material, point: point,
                uv: { i, j in V2(Float(j) / Float(cols), arc[i] * uvScale) })
        if capStart {
            addCap((0..<cols).map { point(0, $0) }, normal: -frames[0].tangent, material: material(0))
        }
        if capEnd {
            let last = path.count - 1
            addCap((0..<cols).map { point(last, $0) }, normal: frames[last].tangent, material: material(max(0, last - 1)))
        }
    }

    /// Convenience: a loft with one material and a radius profile along a circular section.
    public mutating func tube(path: [SIMD3<Float>], up: SIMD3<Float> = SIMD3(0, 1, 0), radius: (Float) -> Float, sides: Int = 12,
                              material: String, caps: Bool = true) {
        let unit = Section.circle(1, count: sides)
        loft(path: path, up: up, section: { _, t in unit.map { $0 * radius(t) } }, material: { _ in material },
             capStart: caps, capEnd: caps)
    }

    /// Rotation-minimising frames along a polyline (Wang et al. 2008, double reflection).
    static func frames(path: [V3], up: V3) -> [(tangent: V3, side: V3, up: V3)] {
        let n = path.count
        var tangents = [V3](repeating: .zero, count: n)
        for k in 0..<n {
            let a = path[max(0, k - 1)], b = path[min(n - 1, k + 1)]
            tangents[k] = (b - a).unit
        }
        var u = up - tangents[0] * up.dotp(tangents[0])
        if u.norm < 1e-6 {
            u = abs(tangents[0].y) < 0.9 ? V3(0, 1, 0) : V3(1, 0, 0)
            u = u - tangents[0] * u.dotp(tangents[0])
        }
        u = u.unit
        var result: [(V3, V3, V3)] = []
        result.reserveCapacity(n)
        // side = up × tangent so that (side, up, tangent) is right-handed.
        result.append((tangents[0], u.crossp(tangents[0]).unit, u))
        for k in 0..<(n - 1) {
            let v1 = path[k + 1] - path[k]
            let c1 = v1.dotp(v1)
            guard c1 > 1e-14 else {
                result.append(result[k])
                continue
            }
            let rL = result[k].2 - v1 * (2 / c1 * v1.dotp(result[k].2))
            let tL = tangents[k] - v1 * (2 / c1 * v1.dotp(tangents[k]))
            let v2 = tangents[k + 1] - tL
            let c2 = v2.dotp(v2)
            let r = c2 > 1e-14 ? rL - v2 * (2 / c2 * v2.dotp(rL)) : rL
            let upk = (r - tangents[k + 1] * r.dotp(tangents[k + 1])).unit
            result.append((tangents[k + 1], upk.crossp(tangents[k + 1]).unit, upk))
        }
        return result.map { (tangent: $0.0, side: $0.1, up: $0.2) }
    }

    // MARK: - Lathe (surfaces of revolution about +Y)

    /// Revolves a profile of (radius, y) points about the Y axis. Profile runs bottom → top.
    public mutating func lathe(profile: [SIMD2<Float>], segments: Int = 24, material: (Int) -> String,
                               startAngle: Float = 0, sweep: Float = 2 * .pi, v: ((Int) -> Float)? = nil) {
        let full = abs(sweep - 2 * .pi) < 1e-4
        var arc: [Float] = [0]
        for k in 1..<profile.count { arc.append(arc[k - 1] + simd_dist2(profile[k], profile[k - 1])) }
        let total = max(arc.last!, 1e-6)
        let cols = full ? segments : segments + 1
        addGrid(rows: profile.count, cols: cols, wrap: full, material: material, point: { i, j in
            let a = startAngle + sweep * Float(j) / Float(segments)
            let p = profile[i]
            return V3(p.x * cos(a), p.y, -p.x * sin(a))
        }, uv: { i, j in V2(Float(j) / Float(segments), v?(i) ?? arc[i] / total) })
    }

    // MARK: - Flat plates (chainrings, cogs, discs)

    /// A flat annular plate between an outer and inner outline (same point count), with
    /// side walls, centred on z = 0 with the given thickness. Faces ±Z.
    public mutating func plate(outer: [SIMD2<Float>], inner: [SIMD2<Float>], thickness: Float, material: String,
                               edgeMaterial: String? = nil) {
        let n = outer.count
        precondition(inner.count == n)
        let h = thickness / 2
        let rMax = outer.reduce(Float(0)) { max($0, simd_len2($1)) }
        func uvOf(_ p: SIMD2<Float>) -> V2 { V2(0.5 + p.x / (2 * rMax), 0.5 + p.y / (2 * rMax)) }
        for (z, normalZ) in [(h, Float(1)), (-h, Float(-1))] {
            let base = UInt32(positions.count)
            for k in 0..<n {
                addVertex(V3(outer[k].x, outer[k].y, z), V3(0, 0, normalZ), uvOf(outer[k]))
                addVertex(V3(inner[k].x, inner[k].y, z), V3(0, 0, normalZ), uvOf(inner[k]))
            }
            var idx: [UInt32] = []
            for k in 0..<n {
                let o0 = base + UInt32(2 * k), i0 = o0 + 1
                let o1 = base + UInt32(2 * ((k + 1) % n)), i1 = o1 + 1
                idx += normalZ > 0 ? [o0, o1, i1, o0, i1, i0] : [o0, i1, o1, o0, i0, i1]
            }
            addIndices(idx, material: material)
        }
        // Outer and inner walls.
        for (ring, outward) in [(outer, Float(1)), (inner, Float(-1))] {
            let base = UInt32(positions.count)
            for k in 0..<n {
                let p = ring[k]
                let prev = ring[(k + n - 1) % n], next = ring[(k + 1) % n]
                let t = next - prev
                let nrm = V3(t.y, -t.x, 0).unit * outward
                addVertex(V3(p.x, p.y, h), nrm, V2(Float(k) / Float(n), 0))
                addVertex(V3(p.x, p.y, -h), nrm, V2(Float(k) / Float(n), 1))
            }
            var idx: [UInt32] = []
            for k in 0..<n {
                let a = base + UInt32(2 * k), b = a + 1
                let c = base + UInt32(2 * ((k + 1) % n)), d = c + 1
                idx += outward > 0 ? [a, b, d, a, d, c] : [a, d, b, a, c, d]
            }
            addIndices(idx, material: edgeMaterial ?? material)
        }
    }

    // MARK: - Primitives

    public mutating func ellipsoid(center: SIMD3<Float>, radii: SIMD3<Float>, rings: Int = 10, segments: Int = 16,
                                   material: String, transform: RigidTransform = .identity) {
        var profile: [SIMD2<Float>] = []
        for i in 0...rings {
            let phi = -Float.pi / 2 + Float.pi * Float(i) / Float(rings)
            profile.append(SIMD2(cos(phi), sin(phi)))
        }
        var m = ModelMesh()
        m.lathe(profile: profile, segments: segments, material: { _ in material })
        append(m, transform: RigidTransform(origin: transform.apply(center), x: transform.x, y: transform.y, z: transform.z),
               scale: radii)
    }

    public mutating func box(center: SIMD3<Float>, size: SIMD3<Float>, material: String, transform: RigidTransform = .identity) {
        let h = size / 2
        let faces: [(V3, V3, V3)] = [   // normal, u axis, v axis
            (V3(1, 0, 0), V3(0, 0, -1), V3(0, 1, 0)), (V3(-1, 0, 0), V3(0, 0, 1), V3(0, 1, 0)),
            (V3(0, 1, 0), V3(1, 0, 0), V3(0, 0, -1)), (V3(0, -1, 0), V3(1, 0, 0), V3(0, 0, 1)),
            (V3(0, 0, 1), V3(1, 0, 0), V3(0, 1, 0)), (V3(0, 0, -1), V3(-1, 0, 0), V3(0, 1, 0)),
        ]
        var idx: [UInt32] = []
        for (n, u, v) in faces {
            let base = UInt32(positions.count)
            let c = center + n * h
            let du = u * h, dv = v * h
            for (su, sv) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                let local = c + du * su + dv * sv
                addVertex(transform.apply(local), transform.rotate(n), V2((su + 1) / 2, (sv + 1) / 2))
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        addIndices(idx, material: material)
    }

    /// Subdivided icosahedron, optionally displaced radially by `displace(direction)` (for rocks, foliage).
    public mutating func icosphere(center: SIMD3<Float>, radius: Float, subdivisions: Int = 2, material: String,
                                   scale: SIMD3<Float> = SIMD3(1, 1, 1), displace: ((SIMD3<Float>) -> Float)? = nil) {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var verts: [V3] = [V3(-1, t, 0), V3(1, t, 0), V3(-1, -t, 0), V3(1, -t, 0), V3(0, -1, t), V3(0, 1, t),
                           V3(0, -1, -t), V3(0, 1, -t), V3(t, 0, -1), V3(t, 0, 1), V3(-t, 0, -1), V3(-t, 0, 1)].map { $0.unit }
        var faces: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
                                        (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
                                        (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        for _ in 0..<subdivisions {
            var cache: [Int: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = min(a, b) * 100_000 + max(a, b)
                if let m = cache[key] { return m }
                verts.append(((verts[a] + verts[b]) / 2).unit)
                cache[key] = verts.count - 1
                return verts.count - 1
            }
            var next: [(Int, Int, Int)] = []
            for (a, b, c) in faces {
                let ab = mid(a, b), bc = mid(b, c), ca = mid(c, a)
                next += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
            faces = next
        }
        let pos = verts.map { d -> V3 in center + d * scale * radius * (1 + (displace?(d) ?? 0)) }
        // Smooth normals from faces.
        var acc = [V3](repeating: .zero, count: verts.count)
        for (a, b, c) in faces {
            let n = (pos[b] - pos[a]).crossp(pos[c] - pos[a])
            acc[a] += n
            acc[b] += n
            acc[c] += n
        }
        let base = UInt32(positions.count)
        for (k, p) in pos.enumerated() {
            let d = verts[k]
            addVertex(p, acc[k].unit, V2(0.5 + atan2(d.z, d.x) / (2 * .pi), 0.5 + asin(max(-1, min(1, d.y))) / .pi))
        }
        addIndices(faces.flatMap { [base + UInt32($0.0), base + UInt32($0.1), base + UInt32($0.2)] }, material: material)
    }

    // MARK: - Export (for previews and debugging)

    /// Wavefront OBJ text (positions, normals, uvs; one `usemtl` group per material).
    public func objText(name: String = "model") -> String {
        var s = "o \(name)\n"
        s.reserveCapacity(positions.count * 80)
        let colored = hasVertexColors
        for (i, p) in positions.enumerated() {
            if colored {
                let c = colors[i]
                s += "v \(p.x) \(p.y) \(p.z) \(c.x) \(c.y) \(c.z)\n"
            } else {
                s += "v \(p.x) \(p.y) \(p.z)\n"
            }
        }
        for t in uvs { s += "vt \(t.x) \(t.y)\n" }
        for n in normals { s += "vn \(n.x) \(n.y) \(n.z)\n" }
        for part in parts {
            s += "usemtl \(part.material)\n"
            var k = 0
            while k + 2 < part.indices.count {
                let a = part.indices[k] + 1, b = part.indices[k + 1] + 1, c = part.indices[k + 2] + 1
                s += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
                k += 3
            }
        }
        return s
    }
}

@inline(__always) func simd_len2(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
@inline(__always) func simd_dist2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_len2(a - b) }

/// Cubic Bézier sampled into a polyline.
func bezier(_ p0: V3, _ p1: V3, _ p2: V3, _ p3: V3, steps: Int) -> [V3] {
    (0...steps).map { k in
        let t = Float(k) / Float(steps), u = 1 - t
        return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }
}

/// Polyline through points, subdivided with Catmull–Rom so tubes bend smoothly.
func catmullRom(_ pts: [V3], samplesPerSegment: Int = 6) -> [V3] {
    guard pts.count > 2 else { return pts }
    var out: [V3] = []
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
        for k in 0..<samplesPerSegment {
            let t = Float(k) / Float(samplesPerSegment)
            let t2 = t * t, t3 = t2 * t
            let a = p1 * 2
            let b = (p2 - p0) * t
            let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
            let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
            out.append((a + b + c + d) * 0.5)
        }
    }
    out.append(pts.last!)
    return out
}
