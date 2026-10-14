import Foundation

/// Bluetooth SIG GATT identifiers used by smart trainers and sensors.
public enum GATT {
    // Fitness Machine Service (FTMS) — Wahoo KICKR (2020+), Tacx NEO / Flux,
    // Elite Direto / Suito, Saris H3, JetBlack, Zwift Hub and most modern trainers.
    public static let fitnessMachineService = "1826"
    public static let fitnessMachineFeature = "2ACC"
    public static let indoorBikeData = "2AD2"
    public static let trainingStatus = "2AD3"
    public static let supportedResistanceRange = "2AD6"
    public static let supportedPowerRange = "2AD8"
    public static let fitnessMachineControlPoint = "2AD9"
    public static let fitnessMachineStatus = "2ADA"

    // Cycling Power Service — power meters and older trainers.
    public static let cyclingPowerService = "1818"
    public static let cyclingPowerMeasurement = "2A63"
    public static let cyclingPowerFeature = "2A65"

    // Heart rate.
    public static let heartRateService = "180D"
    public static let heartRateMeasurement = "2A37"

    // Speed & cadence sensors.
    public static let cyclingSpeedCadenceService = "1816"
    public static let cscMeasurement = "2A5B"

    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
}

/// Little-endian reader over a GATT payload.
public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func s16() -> Int16? { u16().map { Int16(bitPattern: $0) } }

    public mutating func u24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    public mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    public mutating func skip(_ n: Int) { offset = min(bytes.count, offset + n) }
}

// MARK: - FTMS Indoor Bike Data (0x2AD2)

public struct IndoorBikeData: Equatable, Sendable {
    public var speedKmh: Double?
    public var averageSpeedKmh: Double?
    public var cadenceRpm: Double?
    public var averageCadenceRpm: Double?
    public var totalDistanceMeters: Double?
    public var resistanceLevel: Double?
    public var powerWatts: Double?
    public var averagePowerWatts: Double?
    public var totalEnergyKcal: Double?
    public var heartRate: Double?
    public var elapsedSeconds: Double?

    public init() {}

    public static func parse(_ data: Data) -> IndoorBikeData? { parse([UInt8](data)) }

    public static func parse(_ bytes: [UInt8]) -> IndoorBikeData? {
        var r = ByteReader(bytes)
        guard let flags = r.u16() else { return nil }
        var d = IndoorBikeData()
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        // Bit 0 is "More Data": instantaneous speed is present when it is CLEAR.
        if !has(0) { d.speedKmh = r.u16().map { Double($0) / 100 } }
        if has(1) { d.averageSpeedKmh = r.u16().map { Double($0) / 100 } }
        if has(2) { d.cadenceRpm = r.u16().map { Double($0) / 2 } }
        if has(3) { d.averageCadenceRpm = r.u16().map { Double($0) / 2 } }
        if has(4) { d.totalDistanceMeters = r.u24().map(Double.init) }
        if has(5) { d.resistanceLevel = r.s16().map(Double.init) }
        if has(6) { d.powerWatts = r.s16().map(Double.init) }
        if has(7) { d.averagePowerWatts = r.s16().map(Double.init) }
        if has(8) {
            d.totalEnergyKcal = r.u16().map(Double.init)
            r.skip(3) // energy per hour (u16) + per minute (u8)
        }
        if has(9) { d.heartRate = r.u8().map(Double.init) }
        if has(10) { r.skip(1) } // metabolic equivalent
        if has(11) { d.elapsedSeconds = r.u16().map(Double.init) }
        return d
    }
}

// MARK: - FTMS Control Point (0x2AD9)

public enum FTMSCommand: Equatable, Sendable {
    case requestControl
    case reset
    case setTargetResistance(level: Double)
    case setTargetPower(watts: Int)
    case startOrResume
    case stop
    case pause
    /// Simulation mode: the trainer computes resistance from grade, rolling
    /// resistance and wind like the road would.
    case setSimulation(windSpeed: Double, gradePercent: Double, crr: Double, windResistance: Double)
    case setWheelCircumference(millimeters: Double)

    public var bytes: [UInt8] {
        func le16(_ v: Int) -> [UInt8] {
            let u = UInt16(truncatingIfNeeded: v)
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
        switch self {
        case .requestControl: return [0x00]
        case .reset: return [0x01]
        case let .setTargetResistance(level): return [0x04] + le16(Int((level * 10).rounded()))
        case let .setTargetPower(watts): return [0x05] + le16(max(0, min(watts, 4000)))
        case .startOrResume: return [0x07]
        case .stop: return [0x08, 0x01]
        case .pause: return [0x08, 0x02]
        case let .setSimulation(wind, grade, crr, cw):
            let windRaw = Int((wind * 1000).rounded())          // 0.001 m/s
            let gradeRaw = Int((grade * 100).rounded())          // 0.01 %
            let crrRaw = UInt8(max(0, min(255, (crr * 10_000).rounded())))   // 0.0001
            let cwRaw = UInt8(max(0, min(255, (cw * 100).rounded())))        // 0.01 kg/m
            return [0x11] + le16(windRaw) + le16(max(-4000, min(4000, gradeRaw))) + [crrRaw, cwRaw]
        case let .setWheelCircumference(mm): return [0x12] + le16(Int((mm * 10).rounded()))
        }
    }

    public var opcode: UInt8 { bytes[0] }
}

public struct FTMSResponse: Equatable, Sendable {
    public enum Result: UInt8, Sendable {
        case success = 0x01, notSupported = 0x02, invalidParameter = 0x03, failed = 0x04, controlNotPermitted = 0x05
    }

    public var requestOpcode: UInt8
    public var result: Result?

    public static func parse(_ bytes: [UInt8]) -> FTMSResponse? {
        guard bytes.count >= 3, bytes[0] == 0x80 else { return nil }
        return FTMSResponse(requestOpcode: bytes[1], result: Result(rawValue: bytes[2]))
    }
}

// MARK: - Cycling Power Measurement (0x2A63)

public struct CyclingPowerMeasurement: Equatable, Sendable {
    public var powerWatts: Double
    public var pedalBalancePercent: Double?
    public var wheelRevolutions: UInt32?
    public var wheelEventTime: UInt16?   // 1/2048 s
    public var crankRevolutions: UInt16?
    public var crankEventTime: UInt16?   // 1/1024 s

    public static func parse(_ data: Data) -> CyclingPowerMeasurement? { parse([UInt8](data)) }

    public static func parse(_ bytes: [UInt8]) -> CyclingPowerMeasurement? {
        var r = ByteReader(bytes)
        guard let flags = r.u16(), let power = r.s16() else { return nil }
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        var m = CyclingPowerMeasurement(powerWatts: Double(power))
        if has(0) { m.pedalBalancePercent = r.u8().map { Double($0) / 2 } }
        if has(2) { r.skip(2) } // accumulated torque
        if has(4) {
            m.wheelRevolutions = r.u32()
            m.wheelEventTime = r.u16()
        }
        if has(5) {
            m.crankRevolutions = r.u16()
            m.crankEventTime = r.u16()
        }
        return m
    }
}

// MARK: - Heart Rate Measurement (0x2A37)

public struct HeartRateMeasurement: Equatable, Sendable {
    public var bpm: Double
    public var rrIntervals: [Double]

    public static func parse(_ data: Data) -> HeartRateMeasurement? { parse([UInt8](data)) }

    public static func parse(_ bytes: [UInt8]) -> HeartRateMeasurement? {
        var r = ByteReader(bytes)
        guard let flags = r.u8() else { return nil }
        let bpm: Double?
        if flags & 0x01 != 0 { bpm = r.u16().map(Double.init) } else { bpm = r.u8().map(Double.init) }
        guard let bpm else { return nil }
        if flags & 0x08 != 0 { r.skip(2) } // energy expended
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while let v = r.u16() { rr.append(Double(v) / 1024) }
        }
        return HeartRateMeasurement(bpm: bpm, rrIntervals: rr)
    }
}

// MARK: - CSC Measurement (0x2A5B)

public struct CSCMeasurement: Equatable, Sendable {
    public var wheelRevolutions: UInt32?
    public var wheelEventTime: UInt16?   // 1/1024 s
    public var crankRevolutions: UInt16?
    public var crankEventTime: UInt16?   // 1/1024 s

    public static func parse(_ data: Data) -> CSCMeasurement? { parse([UInt8](data)) }

    public static func parse(_ bytes: [UInt8]) -> CSCMeasurement? {
        var r = ByteReader(bytes)
        guard let flags = r.u8() else { return nil }
        var m = CSCMeasurement()
        if flags & 0x01 != 0 {
            m.wheelRevolutions = r.u32()
            m.wheelEventTime = r.u16()
        }
        if flags & 0x02 != 0 {
            m.crankRevolutions = r.u16()
            m.crankEventTime = r.u16()
        }
        return m
    }
}

/// Derives cadence from cumulative crank revolutions + event times, handling
/// 16-bit roll-over and sensors that repeat the last event while coasting.
public struct CadenceCalculator: Sendable {
    private var lastRevs: UInt16?
    private var lastTime: UInt16?
    private var lastChange: Double = 0
    public private(set) var rpm: Double = 0

    public init() {}

    /// - Parameters:
    ///   - now: wall-clock seconds, used to time out to zero cadence.
    ///   - timeUnit: event-time resolution (1/1024 s for CPS & CSC).
    public mutating func update(revolutions: UInt16, eventTime: UInt16, now: Double, timeUnit: Double = 1.0 / 1024) -> Double {
        defer {
            lastRevs = revolutions
            lastTime = eventTime
        }
        guard let pr = lastRevs, let pt = lastTime else {
            lastChange = now
            return rpm
        }
        let dRevs = Double(revolutions &- pr)
        let dTicks = Double(eventTime &- pt)
        if dRevs > 0, dTicks > 0 {
            let value = dRevs / (dTicks * timeUnit) * 60
            if value < 250 { rpm = value }
            lastChange = now
        } else if now - lastChange > 2.5 {
            rpm = 0
        }
        return rpm
    }
}
