import Foundation

/// Height field for the 3D world around a route.
///
/// Combines three layers:
///  1. The real DEM grid bundled with the route (bicubic interpolated), so the
///     valleys and mountains are where they really are.
///  2. Deterministic fractal detail, scaled by biome, for texture below the DEM
///     resolution.
///  3. Road blending: within a corridor around the road the ground is eased to
///     the road's own (smoothed, surveyed) elevation, giving natural cuttings and
///     embankments instead of a road floating over or buried in the hillside.
public final class TerrainModel: @unchecked Sendable {
    public let minX: Double, minY: Double, maxX: Double, maxY: Double
    /// Elevation of sea / lake surface if the DEM contains water, otherwise nil.
    public let waterLevel: Double?
    public let biome: RouteRecord.Biome
    public let lowestPoint: Double
    public let highestPoint: Double

    /// Road half width used for flattening (carriageway + shoulder), metres.
    public static let roadHalfWidth = 4.5
    /// Distance over which terrain blends from road level back to natural ground.
    public static let blendDistance = 65.0

    private let projection: LocalProjection
    private let grid: RouteRecord.TerrainGrid?
    /// Road-anchoring correction (metres) on a regular grid; see `buildCorrection`.
    private var correction: [Float] = []
    /// 0 on/near the road, 1 beyond ~600 m: where extra relief may be added.
    private var remoteness: [Float] = []
    private var correctionNX = 0, correctionNY = 0
    private static let correctionCell = 30.0
    private let gridHeights: [Double]
    private let road: RoadIndex
    private let detailAmplitude: Double
    private let fallbackBase: Double

    public init(route: Route) {
        projection = route.projection
        biome = route.record.biome
        road = RoadIndex(route: route)
        fallbackBase = route.minElevation

        if let g = route.record.terrain, g.isValid {
            grid = g
            gridHeights = g.heights.map(Double.init)
            let sw = route.projection.toLocal(GeoCoordinate(latitude: g.south, longitude: g.west))
            let ne = route.projection.toLocal(GeoCoordinate(latitude: g.north, longitude: g.east))
            minX = sw.x; minY = sw.y; maxX = ne.x; maxY = ne.y

            // EU-DEM and SRTM store sea and lake surfaces as exactly flat values.
            let lowest = g.heights.min() ?? 0
            let flatCount = g.heights.filter { $0 == lowest }.count
            waterLevel = Double(flatCount) / Double(g.heights.count) > 0.06 ? Double(lowest) + 0.6 : nil
        } else {
            grid = nil
            gridHeights = []
            let b = route.bounds
            let margin = max(2000, 0.3 * max(b.max.x - b.min.x, b.max.y - b.min.y))
            minX = b.min.x - margin; minY = b.min.y - margin
            maxX = b.max.x + margin; maxY = b.max.y + margin
            waterLevel = nil
        }

        switch biome {
        case .alpine: detailAmplitude = 7
        case .coastal, .lakes: detailAmplitude = 3.5
        case .forest, .countryside: detailAmplitude = 2.5
        case .urban: detailAmplitude = 1.2
        }
        lowestPoint = gridHeights.min() ?? route.minElevation - 50
        highestPoint = max(gridHeights.max() ?? route.maxElevation + 200, route.maxElevation)
        buildCorrection(route: route)
    }

    /// The bundled DEM grid is coarse (100–300 m), so around hairpin stacks it can
    /// sit tens of metres above or below the surveyed road. Anchor the terrain to
    /// the road: measure the road-vs-DEM offset along the route and spread it out
    /// with inverse-distance weighting, fading to zero 100–600 m from the road.
    private func buildCorrection(route: Route) {
        guard grid != nil else { return }
        let cell = TerrainModel.correctionCell
        let radius = 600.0, core = 20.0
        let nx = Int(ceil(width / cell)) + 1, ny = Int(ceil(depth / cell)) + 1
        var sumW = [Double](repeating: 0, count: nx * ny)
        var sumWD = [Double](repeating: 0, count: nx * ny)
        var dmin = [Double](repeating: .infinity, count: nx * ny)
        let rc = Int(radius / cell)
        var d = 0.0
        while d <= route.length {
            let p = route.position(at: d)
            let delta = route.elevation(at: d) - demHeight(x: p.x, y: p.y)
            let ci = Int(((p.x - minX) / cell).rounded()), cj = Int(((p.y - minY) / cell).rounded())
            for j in max(0, cj - rc)...min(ny - 1, max(0, cj + rc)) {
                let cy = minY + Double(j) * cell
                for i in max(0, ci - rc)...min(nx - 1, max(0, ci + rc)) {
                    let cx = minX + Double(i) * cell
                    let dx = cx - p.x, dy = cy - p.y
                    let dd2 = dx * dx + dy * dy
                    guard dd2 <= radius * radius else { continue }
                    let w = 1 / (dd2 + core * core)
                    let k = j * nx + i
                    sumW[k] += w
                    sumWD[k] += w * delta
                    dmin[k] = min(dmin[k], dd2)
                }
            }
            d += 15
        }
        correction = (0..<(nx * ny)).map { k in
            guard sumW[k] > 0 else { return 0 }
            let coverage = 1 - TerrainModel.smoothstep(100, radius, dmin[k].squareRoot())
            return Float(sumWD[k] / sumW[k] * coverage)
        }
        remoteness = dmin.map { Float(TerrainModel.smoothstep(150, radius, $0.squareRoot())) }
        correctionNX = nx
        correctionNY = ny
    }

    private func correctionAt(x: Double, y: Double) -> Double { sampleGrid(correction, x: x, y: y, outside: 0) }

    private func remotenessAt(x: Double, y: Double) -> Double { sampleGrid(remoteness, x: x, y: y, outside: 1) }

    private func sampleGrid(_ values: [Float], x: Double, y: Double, outside: Double) -> Double {
        guard !values.isEmpty else { return outside }
        let cell = TerrainModel.correctionCell
        let fx = min(max((x - minX) / cell, 0), Double(correctionNX - 1))
        let fy = min(max((y - minY) / cell, 0), Double(correctionNY - 1))
        let i = min(Int(fx), correctionNX - 2), j = min(Int(fy), correctionNY - 2)
        let tx = Float(fx - Double(i)), ty = Float(fy - Double(j))
        let n = correctionNX
        let a = values[j * n + i], b = values[j * n + i + 1]
        let c = values[(j + 1) * n + i], e = values[(j + 1) * n + i + 1]
        return Double((a + (b - a) * tx) * (1 - ty) + (c + (e - c) * tx) * ty)
    }

    public var width: Double { maxX - minX }
    public var depth: Double { maxY - minY }

    // MARK: - Public sampling

    /// Final ground height at a local position (road-blended).
    public func height(x: Double, y: Double) -> Double {
        let natural = naturalHeight(x: x, y: y)
        guard let hit = road.nearest(x: x, y: y, maxDistance: TerrainModel.blendDistance) else { return natural }
        let roadBed = hit.elevation - 0.18
        let t = TerrainModel.smoothstep(TerrainModel.roadHalfWidth, TerrainModel.blendDistance, hit.distance)
        return roadBed + (natural - roadBed) * t
    }

    /// Ground height ignoring the road (DEM + detail).
    public func naturalHeight(x: Double, y: Double) -> Double {
        var h = demHeight(x: x, y: y) + correctionAt(x: x, y: y)
        h += detail(x: x, y: y)
        if let w = waterLevel, h < w + 0.5 {
            // Keep shorelines from fizzing with detail noise.
            h = min(h, w - 0.4 - (w + 0.5 - h) * 0.2)
        }
        return h
    }

    /// Distance to the road centreline and the road elevation there.
    public func nearestRoad(x: Double, y: Double, maxDistance: Double = 200) -> (distance: Double, elevation: Double, routeDistance: Double)? {
        road.nearest(x: x, y: y, maxDistance: maxDistance)
    }

    // MARK: - Layers

    func demHeight(x: Double, y: Double) -> Double {
        guard let g = grid else {
            // No DEM (imported routes): gentle hills rising away from the road.
            let base: Double
            if let hit = road.nearest(x: x, y: y, maxDistance: 600) {
                base = hit.elevation + max(0, hit.distance - 30) * 0.06
            } else {
                base = fallbackBase + 36
            }
            return base + 18 * TerrainModel.fbm(x * 0.0018, y * 0.0018, octaves: 3, seed: 11)
        }
        let geo = projection.toGeo(LocalPoint(x: x, y: y))
        let n = g.resolution
        let fx = (geo.longitude - g.west) / (g.east - g.west) * Double(n - 1)
        let fy = (geo.latitude - g.south) / (g.north - g.south) * Double(n - 1)
        return bicubic(fx: fx, fy: fy, n: n)
    }

    private func gridValue(_ i: Int, _ j: Int, _ n: Int) -> Double {
        let ci = min(max(i, 0), n - 1), cj = min(max(j, 0), n - 1)
        return gridHeights[cj * n + ci]
    }

    private func bicubic(fx: Double, fy: Double, n: Int) -> Double {
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func cubic(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
            // Catmull-Rom spline.
            let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
            let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
            let c = -0.5 * p0 + 0.5 * p2
            return ((a * t + b) * t + c) * t + p1
        }
        var rows = [Double](repeating: 0, count: 4)
        for k in 0..<4 {
            let j = y0 - 1 + k
            rows[k] = cubic(gridValue(x0 - 1, j, n), gridValue(x0, j, n), gridValue(x0 + 1, j, n), gridValue(x0 + 2, j, n), tx)
        }
        return cubic(rows[0], rows[1], rows[2], rows[3], ty)
    }

    func detail(x: Double, y: Double) -> Double {
        var h = detailAmplitude * TerrainModel.fbm(x / 160, y / 160, octaves: 4, seed: 3)
        // Coarse DEMs smooth peaks into domes; add ridges and gullies away from the road.
        if grid != nil {
            let far = remotenessAt(x: x, y: y)
            if far > 0 {
                let ridge = 1 - abs(TerrainModel.fbm(x / 700, y / 700, octaves: 3, seed: 8)) * 2
                h += far * detailAmplitude * 2.6 * ridge
            }
        }
        return h
    }

    // MARK: - Noise

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65_535.0 * 2 - 1
    }

    static func valueNoise(_ x: Double, _ y: Double, seed: Int) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let tx = x - Double(xi), ty = y - Double(yi)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let a = hash(xi, yi, seed), b = hash(xi + 1, yi, seed)
        let c = hash(xi, yi + 1, seed), d = hash(xi + 1, yi + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    /// Fractal Brownian motion in roughly [-1, 1].
    public static func fbm(_ x: Double, _ y: Double, octaves: Int, seed: Int) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            sum += amp * valueNoise(x * freq, y * freq, seed: seed + o * 17)
            norm += amp
            amp *= 0.5
            freq *= 2.03
        }
        return sum / norm
    }
}

/// Spatial hash over the road centreline for fast nearest-road queries.
final class RoadIndex: @unchecked Sendable {
    private let cell = 40.0
    private var buckets: [Int64: [Int32]] = [:]
    private let xs: [Double], ys: [Double], es: [Double], ds: [Double]

    init(route: Route) {
        // Sample every 6 m; nearest-point queries project onto segments so the
        // result is exact to the polyline, not just to the samples.
        let step = 6.0
        let n = max(2, Int(route.length / step) + 1)
        var xs = [Double](), ys = [Double](), es = [Double](), ds = [Double]()
        xs.reserveCapacity(n); ys.reserveCapacity(n); es.reserveCapacity(n); ds.reserveCapacity(n)
        for i in 0..<n {
            let d = min(Double(i) * step, route.length)
            let p = route.position(at: d)
            xs.append(p.x); ys.append(p.y); es.append(route.elevation(at: d)); ds.append(d)
        }
        self.xs = xs; self.ys = ys; self.es = es; self.ds = ds
        for i in 0..<(n - 1) {
            // Register each segment in every cell its bounding box touches.
            let x0 = min(xs[i], xs[i + 1]), x1 = max(xs[i], xs[i + 1])
            let y0 = min(ys[i], ys[i + 1]), y1 = max(ys[i], ys[i + 1])
            let cx0 = Int(floor(x0 / cell)), cx1 = Int(floor(x1 / cell))
            let cy0 = Int(floor(y0 / cell)), cy1 = Int(floor(y1 / cell))
            for cx in cx0...cx1 {
                for cy in cy0...cy1 {
                    buckets[key(cx, cy), default: []].append(Int32(i))
                }
            }
        }
    }

    private func key(_ cx: Int, _ cy: Int) -> Int64 { (Int64(cx) << 32) ^ Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: cy))) }

    func nearest(x: Double, y: Double, maxDistance: Double) -> (distance: Double, elevation: Double, routeDistance: Double)? {
        let r = Int(ceil(maxDistance / cell))
        let cx = Int(floor(x / cell)), cy = Int(floor(y / cell))
        var best = maxDistance * maxDistance
        var bestE = 0.0, bestD = 0.0
        var found = false
        for dx in -r...r {
            for dy in -r...r {
                guard let list = buckets[key(cx + dx, cy + dy)] else { continue }
                for idx in list {
                    let i = Int(idx)
                    let ax = xs[i], ay = ys[i], bx = xs[i + 1], by = ys[i + 1]
                    let vx = bx - ax, vy = by - ay
                    let len2 = vx * vx + vy * vy
                    var t = len2 > 1e-9 ? ((x - ax) * vx + (y - ay) * vy) / len2 : 0
                    t = min(max(t, 0), 1)
                    let px = ax + vx * t - x, py = ay + vy * t - y
                    let d2 = px * px + py * py
                    if d2 < best {
                        best = d2
                        bestE = es[i] + (es[i + 1] - es[i]) * t
                        bestD = ds[i] + (ds[i + 1] - ds[i]) * t
                        found = true
                    }
                }
            }
        }
        return found ? (best.squareRoot(), bestE, bestD) : nil
    }
}
