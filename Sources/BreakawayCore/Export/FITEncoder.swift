import Foundation

/// Minimal Garmin FIT (Flexible and Interoperable Data Transfer) activity
/// encoder — the format Strava, Garmin Connect, TrainingPeaks and
/// intervals.icu expect from indoor rides. Writes file_id, event, record,
/// lap, session and activity messages.
public enum FITEncoder {
    /// FIT epoch: 1989-12-31T00:00:00Z.
    static let fitEpoch: TimeInterval = 631_065_600

    enum BaseType: UInt8 {
        case enumeration = 0x00, uint8 = 0x02, sint16 = 0x83, uint16 = 0x84, sint32 = 0x85, uint32 = 0x86, uint32z = 0x8C
        var size: UInt8 {
            switch self {
            case .enumeration, .uint8: return 1
            case .sint16, .uint16: return 2
            case .sint32, .uint32, .uint32z: return 4
            }
        }
    }

    struct Field {
        let number: UInt8
        let type: BaseType
        let value: Int64
    }

    struct Writer {
        var data = [UInt8]()
        var definitions: [UInt8: [(UInt8, BaseType)]] = [:]
        var globals: [UInt8: UInt16] = [:]

        mutating func define(local: UInt8, global: UInt16, fields: [(UInt8, BaseType)]) {
            data.append(0x40 | local)       // definition message header
            data.append(0)                  // reserved
            data.append(0)                  // little-endian architecture
            data.append(UInt8(global & 0xFF))
            data.append(UInt8(global >> 8))
            data.append(UInt8(fields.count))
            for (num, type) in fields {
                data.append(num)
                data.append(type.size)
                data.append(type.rawValue)
            }
            definitions[local] = fields
            globals[local] = global
        }

        mutating func write(local: UInt8, values: [Int64]) {
            guard let fields = definitions[local] else { return }
            data.append(local)
            for ((_, type), v) in zip(fields, values) {
                var u = UInt64(bitPattern: v)
                for _ in 0..<type.size {
                    data.append(UInt8(u & 0xFF))
                    u >>= 8
                }
            }
        }
    }

    static func crc(_ bytes: [UInt8], seed: UInt16 = 0) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc = seed
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    static func timestamp(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 - fitEpoch) }

    static func semicircles(_ degrees: Double) -> Int64 { Int64((degrees * 2_147_483_648.0 / 180).rounded()) }

    public static func encode(summary: RideSummary, samples: [RideSample], start: Date) -> Data {
        var w = Writer()
        let startTS = timestamp(start)
        let endTS = startTS + Int64(summary.metrics.duration.rounded())
        let m = summary.metrics

        // file_id
        w.define(local: 0, global: 0, fields: [(0, .enumeration), (1, .uint16), (2, .uint16), (3, .uint32z), (4, .uint32)])
        w.write(local: 0, values: [4, 255, 1, 0x00BE_A7A1, startTS])   // activity, manufacturer = development

        // event: timer start
        w.define(local: 1, global: 21, fields: [(253, .uint32), (0, .enumeration), (1, .enumeration)])
        w.write(local: 1, values: [startTS, 0, 0])

        // records
        w.define(local: 2, global: 20, fields: [(253, .uint32), (0, .sint32), (1, .sint32), (2, .uint16), (3, .uint8),
                                                 (4, .uint8), (5, .uint32), (6, .uint16), (7, .uint16)])
        for s in samples {
            let hr: Int64 = s.heartRate.map { Int64(max(0, min(254, $0.rounded()))) } ?? 0xFF
            w.write(local: 2, values: [
                startTS + Int64(s.t.rounded()),
                semicircles(s.latitude),
                semicircles(s.longitude),
                Int64(((s.elevation + 500) * 5).rounded()),
                hr,
                Int64(max(0, min(254, s.cadence.rounded()))),
                Int64((s.distance * 100).rounded()),
                Int64(min(65_534, (s.speed * 1000).rounded())),
                Int64(max(0, min(65_534, s.power.rounded()))),
            ])
        }

        // event: timer stop
        w.write(local: 1, values: [endTS, 0, 4])

        let avgHR: Int64 = m.averageHeartRate.map { Int64($0.rounded()) } ?? 0xFF
        let maxHR: Int64 = m.maxHeartRate.map { Int64($0.rounded()) } ?? 0xFF
        let elapsedMS = Int64((m.duration * 1000).rounded())

        // lap
        w.define(local: 3, global: 19, fields: [(253, .uint32), (0, .enumeration), (1, .enumeration), (2, .uint32), (7, .uint32),
                                                 (8, .uint32), (9, .uint32), (13, .uint16), (14, .uint16), (15, .uint8), (16, .uint8),
                                                 (17, .uint8), (19, .uint16), (20, .uint16), (21, .uint16), (25, .enumeration)])
        w.write(local: 3, values: [endTS, 9, 1, startTS, elapsedMS, elapsedMS, Int64((m.distance * 100).rounded()),
                                   Int64((m.averageSpeed * 1000).rounded()), Int64((m.maxSpeed * 1000).rounded()), avgHR, maxHR,
                                   Int64(m.averageCadence.rounded()), Int64(m.averagePower.rounded()), Int64(m.maxPower.rounded()),
                                   Int64(m.elevationGain.rounded()), 2])

        // session (sport = cycling, sub-sport = virtual activity)
        w.define(local: 4, global: 18, fields: [(253, .uint32), (0, .enumeration), (1, .enumeration), (2, .uint32), (5, .enumeration),
                                                 (6, .enumeration), (7, .uint32), (8, .uint32), (9, .uint32), (11, .uint16), (14, .uint16),
                                                 (15, .uint16), (16, .uint8), (17, .uint8), (18, .uint8), (20, .uint16), (21, .uint16),
                                                 (22, .uint16), (25, .uint16), (26, .uint16), (34, .uint16), (35, .uint16), (36, .uint16),
                                                 (45, .uint16)])
        w.write(local: 4, values: [endTS, 8, 1, startTS, 2, 58, elapsedMS, elapsedMS, Int64((m.distance * 100).rounded()),
                                   Int64(m.calories.rounded()), Int64((m.averageSpeed * 1000).rounded()), Int64((m.maxSpeed * 1000).rounded()),
                                   avgHR, maxHR, Int64(m.averageCadence.rounded()), Int64(m.averagePower.rounded()), Int64(m.maxPower.rounded()),
                                   Int64(m.elevationGain.rounded()), 0, 1, Int64(m.normalizedPower.rounded()),
                                   Int64((m.trainingStressScore * 10).rounded()), Int64((m.intensityFactor * 1000).rounded()),
                                   Int64(summary.ftpAtTime.rounded())])

        // activity
        let localTS = endTS + Int64(TimeZone.current.secondsFromGMT(for: start))
        w.define(local: 5, global: 34, fields: [(253, .uint32), (0, .uint32), (1, .uint16), (2, .enumeration), (3, .enumeration),
                                                 (4, .enumeration), (5, .uint32)])
        w.write(local: 5, values: [endTS, elapsedMS, 1, 0, 26, 1, localTS])

        // header
        var header: [UInt8] = [14, 0x20]
        let profileVersion: UInt16 = 2132
        header += [UInt8(profileVersion & 0xFF), UInt8(profileVersion >> 8)]
        let size = UInt32(w.data.count)
        header += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)]
        header += Array(".FIT".utf8)
        let hcrc = crc(header)
        header += [UInt8(hcrc & 0xFF), UInt8(hcrc >> 8)]

        var file = header + w.data
        let fcrc = crc(file)
        file += [UInt8(fcrc & 0xFF), UInt8(fcrc >> 8)]
        return Data(file)
    }
}
