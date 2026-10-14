import Foundation

/// Road surface. Drives rolling resistance, road texture and trainer road-feel.
public enum Surface: String, Codable, CaseIterable, Sendable {
    case asphalt, cobbles, gravel

    /// Static coefficient of rolling resistance for a good 28 mm road tyre
    /// (the speed-dependent part is added by `vibrationLoss`).
    public var baseCrr: Double {
        switch self {
        case .asphalt: return 0.0037
        case .gravel: return 0.0060
        case .cobbles: return 0.0085
        }
    }

    /// Fractional increase in rolling resistance per m/s of speed: tyre hysteresis on
    /// tarmac, and energy lost shaking bike and rider on rough surfaces.
    public var vibrationLoss: Double {
        switch self {
        case .asphalt: return 0.010
        case .gravel: return 0.05
        case .cobbles: return 0.065
        }
    }

    public var displayName: String {
        switch self {
        case .asphalt: return "Asphalt"
        case .cobbles: return "Cobbles"
        case .gravel: return "Gravel"
        }
    }
}

/// Raw route data, as bundled with the app (generated from OpenStreetMap + DEM data)
/// or produced by the GPX importer.
public struct RouteRecord: Identifiable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case grandTourClimb, classic, worldChampionship, imported

        public var displayName: String {
            switch self {
            case .grandTourClimb: return "Grand Tour Climbs"
            case .classic: return "Monuments & Classics"
            case .worldChampionship: return "UCI World Championships"
            case .imported: return "My Routes"
            }
        }
    }

    public enum Biome: String, Codable, CaseIterable, Sendable {
        case alpine, coastal, urban, countryside, forest, lakes
    }

    /// How closely the bundled geometry matches the official course.
    public enum DataQuality: String, Codable, Sendable {
        /// Real roads, within 6 % of the official distance.
        case verified
        /// Real named roads of the course; exact street sequence unconfirmed.
        case approximate
        /// Real roads and elevation; no official distance to compare against.
        case traced

        public var label: String {
            switch self {
            case .verified: return "Verified against race data"
            case .approximate: return "Approximate course"
            case .traced: return "Traced on real roads"
            }
        }
    }

    public struct OfficialStats: Sendable {
        public var distanceKm: Double?
        public var elevationGainM: Double?
        public var averageGradePercent: Double?

        public init(distanceKm: Double? = nil, elevationGainM: Double? = nil, averageGradePercent: Double? = nil) {
            self.distanceKm = distanceKm
            self.elevationGainM = elevationGainM
            self.averageGradePercent = averageGradePercent
        }
    }

    public struct Segment: Sendable {
        public enum Kind: String, Codable, Sendable { case climb, sprint }
        public var name: String
        public var kind: Kind
        public var startMeters: Double
        public var endMeters: Double

        public init(name: String, kind: Kind, startMeters: Double, endMeters: Double) {
            self.name = name
            self.kind = kind
            self.startMeters = startMeters
            self.endMeters = endMeters
        }
    }

    public struct SurfaceSection: Sendable {
        public var surface: Surface
        public var startMeters: Double
        public var endMeters: Double
        public var name: String

        public init(surface: Surface, startMeters: Double, endMeters: Double, name: String) {
            self.surface = surface
            self.startMeters = startMeters
            self.endMeters = endMeters
            self.name = name
        }
    }

    /// Square DEM grid (south-west origin, row-major, rows run north) of int16 metres.
    public struct TerrainGrid: Sendable {
        public var south: Double, west: Double, north: Double, east: Double
        public var resolution: Int
        public var heights: [Int16]

        public init(south: Double, west: Double, north: Double, east: Double, resolution: Int, base64Int16: String) {
            self.south = south
            self.west = west
            self.north = north
            self.east = east
            self.resolution = resolution
            var heights: [Int16] = []
            if let data = Data(base64Encoded: base64Int16) {
                heights.reserveCapacity(data.count / 2)
                let bytes = [UInt8](data)
                var i = 0
                while i + 1 < bytes.count {
                    heights.append(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)))
                    i += 2
                }
            }
            self.heights = heights
        }

        public init(south: Double, west: Double, north: Double, east: Double, resolution: Int, heights: [Int16]) {
            self.south = south
            self.west = west
            self.north = north
            self.east = east
            self.resolution = resolution
            self.heights = heights
        }

        public var isValid: Bool { resolution >= 2 && heights.count == resolution * resolution }
    }

    public var id: String
    public var name: String
    public var category: Category
    public var event: String
    public var location: String
    public var countryCode: String
    public var summary: String
    public var isLoop: Bool
    public var defaultLaps: Int
    public var biome: Biome
    public var official: OfficialStats?
    public var quality: DataQuality
    public var streets: [String]
    public var segments: [Segment]
    public var surfaces: [SurfaceSection]
    public var climbNames: [String]
    public var encodedTrack: String
    public var terrain: TerrainGrid?

    public init(id: String, name: String, category: Category, event: String, location: String,
                countryCode: String, summary: String, isLoop: Bool, defaultLaps: Int, biome: Biome,
                official: OfficialStats?, quality: DataQuality = .traced, streets: [String], segments: [Segment], surfaces: [SurfaceSection],
                climbNames: [String] = [], encodedTrack: String, terrain: TerrainGrid?) {
        self.id = id
        self.name = name
        self.category = category
        self.event = event
        self.location = location
        self.countryCode = countryCode
        self.summary = summary
        self.isLoop = isLoop
        self.defaultLaps = defaultLaps
        self.biome = biome
        self.official = official
        self.quality = quality
        self.streets = streets
        self.segments = segments
        self.surfaces = surfaces
        self.climbNames = climbNames
        self.encodedTrack = encodedTrack
        self.terrain = terrain
    }

    /// Country flag emoji from the ISO code.
    public var flag: String {
        countryCode.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
            .map { String($0) }.joined()
    }
}

/// The bundled route library.
public enum RouteCatalog {
    public static var all: [RouteRecord] { bundled }

    public static func record(id: String) -> RouteRecord? {
        bundled.first { $0.id == id }
    }

    /// Fully processed routes are relatively expensive to build (terrain sampling,
    /// climb detection), so they are cached.
    private static let cacheLock = NSLock()
    private static var cache: [String: Route] = [:]

    public static func route(id: String) -> Route? {
        cacheLock.lock()
        if let r = cache[id] {
            cacheLock.unlock()
            return r
        }
        cacheLock.unlock()
        guard let rec = record(id: id) else { return nil }
        let route = Route(record: rec)
        cacheLock.lock()
        cache[id] = route
        cacheLock.unlock()
        return route
    }
}
