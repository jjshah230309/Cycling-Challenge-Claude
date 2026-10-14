import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// GPX/TCX export of rides, and GPX import of routes (e.g. the official GPX
/// files UCI organisers publish for each World Championships course).
public enum GPXFormat {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Export

    public static func exportRide(summary: RideSummary, samples: [RideSample], start: Date) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Breakaway" xmlns="http://www.topografix.com/GPX/1/1"
          xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <metadata><name>\(escape(summary.routeName))</name><time>\(iso.string(from: start))</time></metadata>
          <trk><name>\(escape(summary.routeName))</name><type>VirtualRide</type><trkseg>

        """
        for s in samples {
            let t = iso.string(from: start.addingTimeInterval(s.t))
            var ext = "<power>\(Int(s.power.rounded()))</power><gpxtpx:TrackPointExtension>"
            if let hr = s.heartRate { ext += "<gpxtpx:hr>\(Int(hr.rounded()))</gpxtpx:hr>" }
            ext += "<gpxtpx:cad>\(Int(s.cadence.rounded()))</gpxtpx:cad></gpxtpx:TrackPointExtension>"
            out += String(format: "      <trkpt lat=\"%.7f\" lon=\"%.7f\"><ele>%.1f</ele>", s.latitude, s.longitude, s.elevation)
            out += "<time>\(t)</time><extensions>\(ext)</extensions></trkpt>\n"
        }
        out += "    </trkseg></trk>\n</gpx>\n"
        return out
    }

    public static func exportTCX(summary: RideSummary, samples: [RideSample], start: Date) -> String {
        let m = summary.metrics
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
          xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
          <Activities><Activity Sport="Biking"><Id>\(iso.string(from: start))</Id>
            <Lap StartTime="\(iso.string(from: start))">
              <TotalTimeSeconds>\(Int(m.duration))</TotalTimeSeconds>
              <DistanceMeters>\(String(format: "%.1f", m.distance))</DistanceMeters>
              <Calories>\(Int(m.calories))</Calories>
              <Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>
              <Track>

        """
        for s in samples {
            out += "          <Trackpoint><Time>\(iso.string(from: start.addingTimeInterval(s.t)))</Time>"
            out += String(format: "<Position><LatitudeDegrees>%.7f</LatitudeDegrees><LongitudeDegrees>%.7f</LongitudeDegrees></Position>", s.latitude, s.longitude)
            out += String(format: "<AltitudeMeters>%.1f</AltitudeMeters><DistanceMeters>%.1f</DistanceMeters>", s.elevation, s.distance)
            if let hr = s.heartRate { out += "<HeartRateBpm><Value>\(Int(hr.rounded()))</Value></HeartRateBpm>" }
            out += "<Cadence>\(Int(s.cadence.rounded()))</Cadence>"
            out += String(format: "<Extensions><ns3:TPX><ns3:Speed>%.2f</ns3:Speed><ns3:Watts>%d</ns3:Watts></ns3:TPX></Extensions></Trackpoint>\n", s.speed, Int(s.power.rounded()))
        }
        out += "        </Track>\n      </Lap>\n    </Activity></Activities>\n</TrainingCenterDatabase>\n"
        return out
    }

    /// GPX of the route itself (for loading onto a bike computer and riding it for real).
    public static func exportRoute(_ route: Route) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Breakaway" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>\(escape(route.name))</name><trkseg>

        """
        for (c, e) in zip(route.coordinates, route.elevations) {
            out += String(format: "    <trkpt lat=\"%.6f\" lon=\"%.6f\"><ele>%.1f</ele></trkpt>\n", c.latitude, c.longitude, e)
        }
        out += "  </trkseg></trk>\n</gpx>\n"
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Import

    public struct ImportedTrack: Sendable {
        public var name: String
        public var coordinates: [GeoCoordinate]
        public var elevations: [Double]
        public var hadElevation: Bool
    }

    public enum ImportError: Error, LocalizedError {
        case unreadable(String), tooFewPoints

        public var errorDescription: String? {
            switch self {
            case let .unreadable(m): return "Could not read the GPX file: \(m)"
            case .tooFewPoints: return "The GPX file needs at least a few hundred metres of track."
            }
        }
    }

    public static func importTrack(_ data: Data, fallbackName: String) throws -> ImportedTrack {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ImportError.unreadable(parser.parserError?.localizedDescription ?? "invalid XML") }
        var coords = delegate.points.map(\.0)
        var eles = delegate.points.map { $0.1 ?? 0 }
        let hadElevation = delegate.points.contains { $0.1 != nil }

        // Remove GPS duplicates / jitter below 2 m.
        var keptC: [GeoCoordinate] = [], keptE: [Double] = []
        for (c, e) in zip(coords, eles) {
            if let last = keptC.last, Geo.distance(last, c) < 2 { continue }
            keptC.append(c)
            keptE.append(e)
        }
        coords = keptC
        eles = keptE
        guard coords.count >= 10 else { throw ImportError.tooFewPoints }

        // GPS altitude is noisy: smooth over ~60 m and clamp to plausible road gradients.
        var cum = [0.0]
        for i in 1..<coords.count { cum.append(cum[i - 1] + Geo.distance(coords[i - 1], coords[i])) }
        guard (cum.last ?? 0) > 300 else { throw ImportError.tooFewPoints }
        var smooth = eles
        let sigma = 30.0
        var j0 = 0
        for i in eles.indices {
            while cum[j0] < cum[i] - 3 * sigma { j0 += 1 }
            var acc = 0.0, wsum = 0.0, j = j0
            while j < eles.count, cum[j] <= cum[i] + 3 * sigma {
                let w = exp(-0.5 * pow((cum[j] - cum[i]) / sigma, 2))
                acc += w * eles[j]
                wsum += w
                j += 1
            }
            smooth[i] = acc / wsum
        }
        var clamped = [smooth[0]]
        for i in 1..<smooth.count {
            let dd = cum[i] - cum[i - 1]
            let de = max(-0.25 * dd, min(0.25 * dd, smooth[i] - smooth[i - 1]))
            clamped.append(clamped[i - 1] + de)
        }
        let name = delegate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ImportedTrack(name: name.isEmpty ? fallbackName : name, coordinates: coords, elevations: clamped, hadElevation: hadElevation)
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var name = ""
    var points: [(GeoCoordinate, Double?)] = []
    private var current: GeoCoordinate?
    private var currentEle: Double?
    private var text = ""
    private var depthInPoint = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        let tag = elementName.lowercased()
        if tag == "trkpt" || tag == "rtept" {
            if let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) {
                current = GeoCoordinate(latitude: la, longitude: lo)
                currentEle = nil
                depthInPoint = true
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "ele" where depthInPoint:
            currentEle = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "trkpt", "rtept":
            if let c = current { points.append((c, currentEle)) }
            current = nil
            depthInPoint = false
        case "name" where name.isEmpty && !depthInPoint:
            name = text
        default:
            break
        }
        text = ""
    }
}
