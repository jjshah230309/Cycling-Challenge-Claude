import Foundation

/// The state of the road at one distance along a route.
public struct TrackSample: Sendable {
    /// Distance along the route lap, metres (wrapped into the lap for circuits).
    public var distance: Double
    public var position: LocalPoint
    public var elevation: Double
    /// Gradient as a fraction (0.08 = 8 %).
    public var grade: Double
    /// Unit direction of travel in the local east/north plane.
    public var direction: LocalPoint
    public var surface: Surface
    public var coordinate: GeoCoordinate

    /// Heading in radians, 0 = north, clockwise positive.
    public var heading: Double { atan2(direction.x, direction.y) }
}

/// Tour-de-France style climb classification (from the FIETS index).
public enum ClimbCategory: Int, Codable, Comparable, Sendable {
    case hc = 0, cat1, cat2, cat3, cat4

    public static func < (a: ClimbCategory, b: ClimbCategory) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .hc: return "HC"
        case .cat1: return "Cat 1"
        case .cat2: return "Cat 2"
        case .cat3: return "Cat 3"
        case .cat4: return "Cat 4"
        }
    }

    /// FIETS index: H² / (D·10) + max(0, (T − 1000) / 1000).
    public static func classify(gain: Double, length: Double, top: Double) -> ClimbCategory {
        guard length > 0 else { return .cat4 }
        let fiets = gain * gain / (length * 10) + max(0, (top - 1000) / 1000)
        switch fiets {
        case 6.5...: return .hc
        case 4.5..<6.5: return .cat1
        case 3.0..<4.5: return .cat2
        case 1.5..<3.0: return .cat3
        default: return .cat4
        }
    }
}

/// A timed climb (KOM / QOM segment).
public struct Climb: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var startDistance: Double
    public var endDistance: Double
    public var startElevation: Double
    public var topElevation: Double
    public var maxGrade: Double
    public var category: ClimbCategory

    public var length: Double { endDistance - startDistance }
    public var elevationGain: Double { topElevation - startElevation }
    public var averageGrade: Double { length > 0 ? elevationGain / length : 0 }
}

/// A fully processed route: projected track, gradients, climbs, surfaces and terrain.
public final class Route: Identifiable, @unchecked Sendable {
    public let record: RouteRecord
    public let projection: LocalProjection
    public let points: [LocalPoint]
    public let elevations: [Double]
    public let coordinates: [GeoCoordinate]
    /// Cumulative distance at each point. For circuits the last point closes the loop.
    public let cumulative: [Double]
    public let length: Double
    public let climbs: [Climb]
    public let elevationGain: Double
    public let minElevation: Double
    public let maxElevation: Double
    public let maxGrade: Double

    public var id: String { record.id }
    public var name: String { record.name }
    public var isLoop: Bool { record.isLoop }

    private let terrainLock = NSLock()
    private var terrainStorage: TerrainModel?

    /// Lazily built height field for the 3D world.
    public var terrain: TerrainModel {
        terrainLock.lock()
        defer { terrainLock.unlock() }
        if let t = terrainStorage { return t }
        let t = TerrainModel(route: self)
        terrainStorage = t
        return t
    }

    public init(record: RouteRecord) {
        self.record = record
        var decoded = PolylineCodec.decode3(record.encodedTrack)
        if decoded.isEmpty {
            decoded = [PolylineCodec.Point3(latitude: 0, longitude: 0, elevation: 0),
                       PolylineCodec.Point3(latitude: 0.001, longitude: 0, elevation: 0)]
        }
        // Drop duplicate vertices (zero-length segments break interpolation).
        var cleaned: [PolylineCodec.Point3] = [decoded[0]]
        for p in decoded.dropFirst() {
            let last = cleaned[cleaned.count - 1]
            if abs(p.latitude - last.latitude) > 1e-7 || abs(p.longitude - last.longitude) > 1e-7 {
                cleaned.append(p)
            }
        }
        if record.isLoop, let first = cleaned.first, let last = cleaned.last,
           Geo.distance(GeoCoordinate(latitude: first.latitude, longitude: first.longitude),
                        GeoCoordinate(latitude: last.latitude, longitude: last.longitude)) > 0.5 {
            cleaned.append(first) // close the loop exactly
        }

        let lats = cleaned.map(\.latitude), lons = cleaned.map(\.longitude)
        let origin = GeoCoordinate(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let proj = LocalProjection(origin: origin)
        projection = proj
        let coords = cleaned.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        coordinates = coords
        points = coords.map { proj.toLocal($0) }
        elevations = cleaned.map(\.elevation)

        var cum: [Double] = [0]
        cum.reserveCapacity(points.count)
        for i in 1..<points.count {
            cum.append(cum[i - 1] + points[i].distance(to: points[i - 1]))
        }
        cumulative = cum
        length = max(cum.last ?? 1, 1)

        var gain = 0.0
        for i in 1..<elevations.count where elevations[i] > elevations[i - 1] {
            gain += elevations[i] - elevations[i - 1]
        }
        elevationGain = gain
        minElevation = elevations.min() ?? 0
        maxElevation = elevations.max() ?? 0

        // Resample once on a regular grid for climb detection and max gradient.
        let step = 25.0
        let n = Int(length / step) + 1
        var regular = [Double](repeating: 0, count: n)
        for i in 0..<n {
            regular[i] = Route.interpolate(cum, elevations, Double(i) * step)
        }
        var mg = 0.0
        if n > 4 {
            for i in 0..<(n - 4) {
                mg = max(mg, (regular[i + 4] - regular[i]) / (4 * step))
            }
        }
        maxGrade = mg
        climbs = Route.detectClimbs(regular: regular, step: step, names: record.climbNames, segments: record.segments)
    }

    /// Builds a route from imported GPS data.
    public convenience init(importedName: String, coordinates: [GeoCoordinate], elevations: [Double], isLoop: Bool? = nil) {
        let pts = zip(coordinates, elevations).map {
            PolylineCodec.Point3(latitude: $0.latitude, longitude: $0.longitude, elevation: $1)
        }
        let loop: Bool
        if let isLoop {
            loop = isLoop
        } else if let f = coordinates.first, let l = coordinates.last {
            loop = Geo.distance(f, l) < 80
        } else {
            loop = false
        }
        let record = RouteRecord(
            id: "imported-" + StableHash.hex(importedName + "\(coordinates.count)"),
            name: importedName, category: .imported, event: "Imported GPX", location: "",
            countryCode: "", summary: "Imported from a GPX file.", isLoop: loop, defaultLaps: 1,
            biome: .countryside, official: nil, streets: [], segments: [], surfaces: [],
            encodedTrack: PolylineCodec.encode3(pts), terrain: nil)
        self.init(record: record)
    }

    // MARK: - Queries

    /// Wraps (circuits) or clamps (point-to-point) a distance into the lap.
    public func normalize(_ distance: Double) -> Double {
        if isLoop {
            let r = distance.truncatingRemainder(dividingBy: length)
            return r < 0 ? r + length : r
        }
        return min(max(distance, 0), length)
    }

    /// Index of the segment containing `d` (binary search).
    func segmentIndex(_ d: Double) -> Int {
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        return lo
    }

    public func position(at distance: Double) -> LocalPoint {
        let d = normalize(distance)
        let i = segmentIndex(d)
        let j = min(i + 1, points.count - 1)
        let span = cumulative[j] - cumulative[i]
        let t = span > 1e-9 ? (d - cumulative[i]) / span : 0
        return LocalPoint.lerp(points[i], points[j], t)
    }

    public func elevation(at distance: Double) -> Double {
        Route.interpolate(cumulative, elevations, normalize(distance))
    }

    public func grade(at distance: Double) -> Double {
        let h = 15.0
        if isLoop {
            return (elevation(at: distance + h) - elevation(at: distance - h)) / (2 * h)
        }
        let d = normalize(distance)
        let a = max(0, d - h), b = min(length, d + h)
        guard b - a > 1 else { return 0 }
        return (elevation(at: b) - elevation(at: a)) / (b - a)
    }

    /// Smoothed travel direction (looks a few metres either side so corners turn smoothly).
    public func direction(at distance: Double) -> LocalPoint {
        let h = 4.0
        var a = distance - h, b = distance + h
        if !isLoop {
            a = max(0, a)
            b = min(length, b)
        }
        let v = position(at: b) - position(at: a)
        return v.length > 1e-6 ? v.normalized : LocalPoint(x: 0, y: 1)
    }

    public func surface(at distance: Double) -> Surface {
        let d = normalize(distance)
        for s in record.surfaces where d >= s.startMeters && d <= s.endMeters {
            return s.surface
        }
        return .asphalt
    }

    public func surfaceSection(at distance: Double) -> RouteRecord.SurfaceSection? {
        let d = normalize(distance)
        return record.surfaces.first { d >= $0.startMeters && d <= $0.endMeters }
    }

    public func sample(at distance: Double) -> TrackSample {
        let d = normalize(distance)
        let p = position(at: d)
        return TrackSample(distance: d, position: p, elevation: elevation(at: d), grade: grade(at: d),
                           direction: direction(at: d), surface: surface(at: d), coordinate: projection.toGeo(p))
    }

    public func coordinate(at distance: Double) -> GeoCoordinate {
        projection.toGeo(position(at: distance))
    }

    /// Climb containing the given lap distance, if any.
    public func climb(at distance: Double) -> Climb? {
        let d = normalize(distance)
        return climbs.first { d >= $0.startDistance && d <= $0.endDistance }
    }

    /// Evenly spaced (distance, elevation) pairs for charts.
    public func profile(samples: Int = 300) -> [(distance: Double, elevation: Double)] {
        let n = max(2, samples)
        return (0..<n).map { i in
            let d = length * Double(i) / Double(n - 1)
            return (d, elevation(at: d))
        }
    }

    public var bounds: (min: LocalPoint, max: LocalPoint) {
        var lo = LocalPoint(x: .infinity, y: .infinity), hi = LocalPoint(x: -.infinity, y: -.infinity)
        for p in points {
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
        }
        return (lo, hi)
    }

    // MARK: - Helpers

    static func interpolate(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = xs[hi] - xs[lo]
        let t = span > 1e-9 ? (x - xs[lo]) / span : 0
        return ys[lo] + (ys[hi] - ys[lo]) * t
    }

    /// Finds sustained climbs in a regularly sampled elevation profile.
    static func detectClimbs(regular e: [Double], step: Double, names: [String], segments: [RouteRecord.Segment]) -> [Climb] {
        var found: [(start: Int, top: Int)] = []
        let n = e.count
        var i = 0
        while i < n - 4 {
            // A climb starts where the next 100 m rise at least 2 %.
            guard e[i + 4] - e[i] >= 2.0 else {
                i += 1
                continue
            }
            let start = i
            var peak = i
            var j = i
            while j < n - 1 {
                j += 1
                if e[j] > e[peak] { peak = j }
                let gain = e[peak] - e[start]
                let dropped = e[peak] - e[j]
                // End when we have clearly gone over the top, or flattened out for 600 m.
                if dropped > max(12, 0.12 * gain) || j - peak > 24 { break }
            }
            let gain = e[peak] - e[start]
            let len = Double(peak - start) * step
            let avg = len > 0 ? gain / len : 0
            if len >= 200, (gain >= 30 && avg >= 0.025) || (gain >= 15 && avg >= 0.05) {
                found.append((start, peak))
            }
            i = max(peak, i + 1)
        }

        // Name the biggest climbs after the route's known climbs, in road order.
        let ranked = found.enumerated().sorted { (e[$0.element.top] - e[$0.element.start]) > (e[$1.element.top] - e[$1.element.start]) }
        let namedIdx = Set(ranked.prefix(names.count).map(\.offset))
        var nameQueue = names[...]
        var climbs: [Climb] = []
        for (k, c) in found.enumerated() {
            var maxG = 0.0
            if c.top - c.start >= 4 {
                for a in c.start...(c.top - 4) {
                    maxG = max(maxG, (e[a + 4] - e[a]) / (4 * step))
                }
            } else {
                maxG = (e[c.top] - e[c.start]) / max(Double(c.top - c.start) * step, step)
            }
            let startD = Double(c.start) * step, endD = Double(c.top) * step
            let name: String
            if namedIdx.contains(k), let nm = nameQueue.first {
                name = nm
                nameQueue = nameQueue.dropFirst()
            } else {
                name = String(format: "Climb at km %.1f", startD / 1000)
            }
            climbs.append(Climb(id: k, name: name, startDistance: startD, endDistance: endD,
                                startElevation: e[c.start], topElevation: e[c.top], maxGrade: maxG,
                                category: ClimbCategory.classify(gain: e[c.top] - e[c.start], length: endD - startD, top: e[c.top])))
        }
        // Explicit segments from the data file override detection where they overlap.
        for seg in segments where seg.kind == .climb {
            let a = Int(seg.startMeters / step), b = min(Int(seg.endMeters / step), n - 1)
            guard b > a, a >= 0 else { continue }
            climbs.removeAll { $0.startDistance < seg.endMeters && $0.endDistance > seg.startMeters }
            let top = e[a...b].max() ?? e[b]
            climbs.append(Climb(id: 1000 + climbs.count, name: seg.name, startDistance: seg.startMeters, endDistance: seg.endMeters,
                                startElevation: e[a], topElevation: top, maxGrade: 0,
                                category: ClimbCategory.classify(gain: top - e[a], length: seg.endMeters - seg.startMeters, top: top)))
        }
        return climbs.sorted { $0.startDistance < $1.startDistance }
    }
}
