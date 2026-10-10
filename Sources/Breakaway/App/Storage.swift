import BreakawayCore
import Foundation

/// JSON persistence in ~/Library/Application Support/Breakaway.
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Breakaway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var ridesDirectory: URL { subdirectory("Rides") }
    static var routesDirectory: URL { subdirectory("Routes") }

    private static func subdirectory(_ name: String) -> URL {
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        let url = directory.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to file: String) {
        let url = directory.appendingPathComponent(file)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func saveSamples(_ samples: [RideSample], for id: UUID) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: ridesDirectory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }

    static func loadSamples(for id: UUID) -> [RideSample] {
        let url = ridesDirectory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RideSample].self, from: data)) ?? []
    }

    static func deleteSamples(for id: UUID) {
        try? FileManager.default.removeItem(at: ridesDirectory.appendingPathComponent("\(id.uuidString).json"))
    }
}
