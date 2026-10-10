import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads and writes `.zwo` structured-workout files, the de-facto XML format
/// used by Zwift and many coaching platforms — so existing workout libraries
/// can be imported directly.
public enum ZWOFormat {
    public enum ParseError: Error, LocalizedError {
        case invalidXML(String)
        case noWorkoutBlocks

        public var errorDescription: String? {
            switch self {
            case let .invalidXML(msg): return "The workout file is not valid XML: \(msg)"
            case .noWorkoutBlocks: return "The workout file has no workout blocks."
            }
        }
    }

    public static func parse(_ data: Data, fallbackName: String = "Imported Workout") throws -> Workout {
        let delegate = ZWOParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        guard !delegate.steps.isEmpty else { throw ParseError.noWorkoutBlocks }
        let name = delegate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Workout(id: "zwo-" + StableHash.hex(String(decoding: data, as: UTF8.self)),
                       name: name.isEmpty ? fallbackName : name,
                       author: delegate.author.trimmingCharacters(in: .whitespacesAndNewlines),
                       summary: delegate.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                       category: .custom, steps: delegate.steps)
    }

    public static func export(_ w: Workout) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        func cad(_ c: Int?) -> String { c.map { " Cadence=\"\($0)\"" } ?? "" }
        var lines = [
            "<workout_file>",
            "    <author>\(esc(w.author))</author>",
            "    <name>\(esc(w.name))</name>",
            "    <description>\(esc(w.summary))</description>",
            "    <sportType>bike</sportType>",
            "    <tags/>",
            "    <workout>",
        ]
        for (i, step) in w.steps.enumerated() {
            switch step {
            case let .steady(d, p, c):
                lines.append("        <SteadyState Duration=\"\(Int(d))\" Power=\"\(f(p))\"\(cad(c))/>")
            case let .ramp(d, a, b, c):
                let tag = i == 0 && b > a ? "Warmup" : (i == w.steps.count - 1 && b < a ? "Cooldown" : "Ramp")
                lines.append("        <\(tag) Duration=\"\(Int(d))\" PowerLow=\"\(f(a))\" PowerHigh=\"\(f(b))\"\(cad(c))/>")
            case let .intervals(r, on, onP, off, offP, c):
                lines.append("        <IntervalsT Repeat=\"\(r)\" OnDuration=\"\(Int(on))\" OffDuration=\"\(Int(off))\" OnPower=\"\(f(onP))\" OffPower=\"\(f(offP))\"\(cad(c))/>")
            case let .freeRide(d):
                lines.append("        <FreeRide Duration=\"\(Int(d))\" FlatRoad=\"0\"/>")
            }
        }
        lines += ["    </workout>", "</workout_file>", ""]
        return lines.joined(separator: "\n")
    }
}

private final class ZWOParserDelegate: NSObject, XMLParserDelegate {
    var name = "", author = "", summary = ""
    var steps: [WorkoutStep] = []
    private var text = ""
    private var inWorkout = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        text = ""
        let tag = elementName.lowercased()
        if tag == "workout" { inWorkout = true; return }
        guard inWorkout else { return }

        func num(_ keys: String...) -> Double? {
            for k in keys {
                if let v = a.first(where: { $0.key.lowercased() == k.lowercased() })?.value, let d = Double(v) { return d }
            }
            return nil
        }
        let duration = num("Duration") ?? 0
        let cadence = num("Cadence").map { Int($0) }

        switch tag {
        case "steadystate", "solidstate":
            steps.append(.steady(duration: duration, power: num("Power", "PowerLow") ?? 0.6, cadence: cadence))
        case "warmup", "cooldown", "ramp":
            let lo = num("PowerLow") ?? 0.5, hi = num("PowerHigh") ?? lo
            steps.append(.ramp(duration: duration, from: lo, to: hi, cadence: cadence))
        case "intervalst":
            steps.append(.intervals(repeats: Int(num("Repeat") ?? 1),
                                    onDuration: num("OnDuration") ?? 60, onPower: num("OnPower", "PowerOnHigh", "PowerOnLow") ?? 1.0,
                                    offDuration: num("OffDuration") ?? 60, offPower: num("OffPower", "PowerOffLow", "PowerOffHigh") ?? 0.5,
                                    cadence: cadence))
        case "freeride", "maxeffort":
            steps.append(.freeRide(duration: duration))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "name" where !inWorkout: name = text
        case "author" where !inWorkout: author = text
        case "description" where !inWorkout: summary = text
        case "workout": inWorkout = false
        default: break
        }
        text = ""
    }
}

/// FNV-1a — stable across launches (unlike `hashValue`), used for imported IDs.
public enum StableHash {
    public static func hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }
}
