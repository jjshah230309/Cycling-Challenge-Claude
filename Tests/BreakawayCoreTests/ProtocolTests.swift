import XCTest
@testable import BreakawayCore

final class ProtocolTests: XCTestCase {
    func testIndoorBikeDataWithSpeedCadencePower() throws {
        // flags: cadence (bit 2) + power (bit 6); bit 0 clear => speed present.
        let bytes: [UInt8] = [0x44, 0x00, 0x10, 0x0E, 0xB4, 0x00, 0xFA, 0x00]
        let d = try XCTUnwrap(IndoorBikeData.parse(bytes))
        XCTAssertEqual(d.speedKmh, 36.0)
        XCTAssertEqual(d.cadenceRpm, 90.0)
        XCTAssertEqual(d.powerWatts, 250.0)
        XCTAssertNil(d.heartRate)
    }

    func testIndoorBikeDataMoreDataFlagSkipsSpeed() throws {
        // bit 0 set (no speed), bit 6 power, bit 9 heart rate.
        let bytes: [UInt8] = [0x41, 0x02, 0x2C, 0x01, 0x96]
        let d = try XCTUnwrap(IndoorBikeData.parse(bytes))
        XCTAssertNil(d.speedKmh)
        XCTAssertEqual(d.powerWatts, 300)
        XCTAssertEqual(d.heartRate, 150)
    }

    func testIndoorBikeDataTruncatedPayloadIsTolerated() {
        XCTAssertNil(IndoorBikeData.parse([0x44]))
        let d = IndoorBikeData.parse([0x44, 0x00, 0x10])
        XCTAssertNotNil(d)
        XCTAssertNil(d?.powerWatts)
    }

    func testControlPointEncoding() {
        XCTAssertEqual(FTMSCommand.requestControl.bytes, [0x00])
        XCTAssertEqual(FTMSCommand.setTargetPower(watts: 250).bytes, [0x05, 0xFA, 0x00])
        XCTAssertEqual(FTMSCommand.setSimulation(windSpeed: 0, gradePercent: 5.5, crr: 0.004, windResistance: 0.51).bytes,
                       [0x11, 0x00, 0x00, 0x26, 0x02, 40, 51])
        // Negative grade is two's complement: -3.2 % => -320 => 0xFEC0.
        XCTAssertEqual(FTMSCommand.setSimulation(windSpeed: 0, gradePercent: -3.2, crr: 0.004, windResistance: 0.51).bytes[3...4],
                       [0xC0, 0xFE])
        XCTAssertEqual(FTMSCommand.pause.bytes, [0x08, 0x02])
    }

    func testControlPointResponse() {
        let r = FTMSResponse.parse([0x80, 0x05, 0x01])
        XCTAssertEqual(r?.requestOpcode, 0x05)
        XCTAssertEqual(r?.result, .success)
        XCTAssertNil(FTMSResponse.parse([0x05, 0x01]))
    }

    func testCyclingPowerMeasurementWithCrankData() throws {
        let bytes: [UInt8] = [0x20, 0x00, 0xC8, 0x00, 0x0A, 0x00, 0x00, 0x04]
        let m = try XCTUnwrap(CyclingPowerMeasurement.parse(bytes))
        XCTAssertEqual(m.powerWatts, 200)
        XCTAssertEqual(m.crankRevolutions, 10)
        XCTAssertEqual(m.crankEventTime, 1024)
    }

    func testCyclingPowerMeasurementWithBalanceAndWheel() throws {
        // flags: balance (bit0) + wheel (bit4)
        let bytes: [UInt8] = [0x11, 0x00, 0x2C, 0x01, 0x64, 0x05, 0x00, 0x00, 0x00, 0x00, 0x08]
        let m = try XCTUnwrap(CyclingPowerMeasurement.parse(bytes))
        XCTAssertEqual(m.powerWatts, 300)
        XCTAssertEqual(m.pedalBalancePercent, 50)
        XCTAssertEqual(m.wheelRevolutions, 5)
        XCTAssertEqual(m.wheelEventTime, 2048)
    }

    func testHeartRate() {
        XCTAssertEqual(HeartRateMeasurement.parse([0x00, 0x8C])?.bpm, 140)
        XCTAssertEqual(HeartRateMeasurement.parse([0x01, 0x2C, 0x01])?.bpm, 300)
        let withRR = HeartRateMeasurement.parse([0x10, 0x50, 0x00, 0x04])
        XCTAssertEqual(withRR?.bpm, 80)
        XCTAssertEqual(withRR?.rrIntervals, [1.0])
    }

    func testCSC() {
        let m = CSCMeasurement.parse([0x02, 0x10, 0x00, 0x00, 0x08])
        XCTAssertEqual(m?.crankRevolutions, 16)
        XCTAssertEqual(m?.crankEventTime, 2048)
        XCTAssertNil(m?.wheelRevolutions)
    }

    func testCadenceCalculatorWithRollover() {
        var c = CadenceCalculator()
        // 90 rpm = one revolution every 2/3 s = 682.67 ticks.
        _ = c.update(revolutions: 65_534, eventTime: 64_000, now: 0)
        let rpm = c.update(revolutions: 1, eventTime: UInt16((64_000 + 3 * 683) % 65_536), now: 2)
        XCTAssertEqual(rpm, 90, accuracy: 0.5)
        // No new revolutions for > 2.5 s => coasting.
        XCTAssertEqual(c.update(revolutions: 1, eventTime: UInt16((64_000 + 3 * 683) % 65_536), now: 6), 0)
    }
}
