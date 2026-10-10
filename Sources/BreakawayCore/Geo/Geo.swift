import Foundation

/// A WGS-84 position.
public struct GeoCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    public static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres.
    public static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLat = la2 - la1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}

/// Planar point in a local east/north frame, metres.
public struct LocalPoint: Hashable, Sendable {
    public var x: Double  // east
    public var y: Double  // north

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: LocalPoint, b: LocalPoint) -> LocalPoint { LocalPoint(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: LocalPoint, b: LocalPoint) -> LocalPoint { LocalPoint(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: LocalPoint, s: Double) -> LocalPoint { LocalPoint(x: a.x * s, y: a.y * s) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public var normalized: LocalPoint {
        let l = length
        return l > 1e-9 ? LocalPoint(x: x / l, y: y / l) : LocalPoint(x: 0, y: 1)
    }

    public func distance(to o: LocalPoint) -> Double { (self - o).length }

    public static func lerp(_ a: LocalPoint, _ b: LocalPoint, _ t: Double) -> LocalPoint {
        LocalPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// Equirectangular projection around an origin. Accurate to well under 0.1 %
/// over the few tens of kilometres a route covers.
public struct LocalProjection: Sendable {
    public let origin: GeoCoordinate
    private let metersPerDegLat: Double
    private let metersPerDegLon: Double

    public init(origin: GeoCoordinate) {
        self.origin = origin
        let lat = origin.latitude * .pi / 180
        // WGS-84 meridian / parallel lengths.
        metersPerDegLat = 111_132.92 - 559.82 * cos(2 * lat) + 1.175 * cos(4 * lat)
        metersPerDegLon = 111_412.84 * cos(lat) - 93.5 * cos(3 * lat)
    }

    public func toLocal(_ c: GeoCoordinate) -> LocalPoint {
        LocalPoint(x: (c.longitude - origin.longitude) * metersPerDegLon,
                   y: (c.latitude - origin.latitude) * metersPerDegLat)
    }

    public func toGeo(_ p: LocalPoint) -> GeoCoordinate {
        GeoCoordinate(latitude: origin.latitude + p.y / metersPerDegLat,
                      longitude: origin.longitude + p.x / metersPerDegLon)
    }
}

/// Google encoded-polyline codec, extended with a third (elevation) dimension
/// stored in decimetres. Used for the compact bundled route tracks.
public enum PolylineCodec {
    public struct Point3: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var elevation: Double
    }

    public static func decode3(_ encoded: String) -> [Point3] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var values = (0, 0, 0)
        var out: [Point3] = []
        out.reserveCapacity(bytes.count / 6)

        func next() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = next(), let dLon = next(), let dEle = next() else { break }
            values.0 += dLat
            values.1 += dLon
            values.2 += dEle
            out.append(Point3(latitude: Double(values.0) / 1e5,
                              longitude: Double(values.1) / 1e5,
                              elevation: Double(values.2) / 10))
        }
        return out
    }

    public static func encode3(_ points: [Point3]) -> String {
        var out = ""
        var prev = (0, 0, 0)
        func enc(_ v: Int) {
            var v = v < 0 ? ~(v << 1) : (v << 1)
            while v >= 0x20 {
                out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1F)) + 63)))
                v >>= 5
            }
            out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }
        for p in points {
            let cur = (Int((p.latitude * 1e5).rounded()), Int((p.longitude * 1e5).rounded()), Int((p.elevation * 10).rounded()))
            enc(cur.0 - prev.0)
            enc(cur.1 - prev.1)
            enc(cur.2 - prev.2)
            prev = cur
        }
        return out
    }
}
