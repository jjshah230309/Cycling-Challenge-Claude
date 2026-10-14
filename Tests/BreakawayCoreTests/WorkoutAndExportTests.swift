import XCTest
@testable import BreakawayCore

final class WorkoutAndExportTests: XCTestCase {
    func testLibraryWorkoutsAreWellFormed() {
        XCTAssertGreaterThanOrEqual(WorkoutLibrary.all.count, 12)
        XCTAssertEqual(Set(WorkoutLibrary.all.map(\.id)).count, WorkoutLibrary.all.count)
        for w in WorkoutLibrary.all {
            XCTAssertGreaterThan(w.duration, 15 * 60, w.name)
            let segs = w.segments
            XCTAssertEqual(segs.last?.end ?? 0, w.duration, accuracy: 1e-6, w.name)
            for (a, b) in zip(segs, segs.dropFirst()) {
                XCTAssertEqual(a.end, b.start, accuracy: 1e-6)
            }
        }
    }

    func testRampTestStaircase() throws {
        let w = try XCTUnwrap(WorkoutLibrary.workout(id: "ramp-test"))
        let steps = w.segments.dropFirst()
        XCTAssertEqual(steps.count, 20)
        XCTAssertEqual(steps.first?.startPower ?? 0, 0.60, accuracy: 1e-9)
        XCTAssertEqual(steps.last?.startPower ?? 0, 0.60 + 0.06 * 19, accuracy: 1e-9)
    }

    func testWorkoutProgressTargets() throws {
        let w = Workout(id: "t", name: "T", summary: "", category: .custom, steps: [
            .ramp(duration: 100, from: 0.5, to: 0.7, cadence: nil),
            .intervals(repeats: 2, onDuration: 30, onPower: 1.2, offDuration: 30, offPower: 0.5, cadence: 100),
            .freeRide(duration: 60),
        ])
        var p = WorkoutProgress(workout: w)
        p.elapsed = 50
        XCTAssertEqual(p.targetWatts(ftp: 200), 120)
        p.elapsed = 110
        XCTAssertEqual(p.targetWatts(ftp: 200), 240)
        XCTAssertEqual(p.current?.label, "Interval 1/2")
        p.elapsed = 145
        XCTAssertEqual(p.current?.label, "Recover")
        p.elapsed = 175
        XCTAssertEqual(p.current?.label, "Interval 2/2")
        p.elapsed = 230
        XCTAssertNil(p.targetWatts(ftp: 200))
        p.elapsed = 300
        XCTAssertTrue(p.isComplete)
    }

    func testTSSOfOneHourAtFTPIs100() {
        let w = Workout(id: "x", name: "x", summary: "", category: .custom, steps: [.steady(duration: 3600, power: 1.0, cadence: nil)])
        XCTAssertEqual(w.estimatedTSS, 100, accuracy: 0.01)
    }

    func testZWOParsing() throws {
        let xml = """
        <workout_file>
            <author>Coach</author>
            <name>Sample &amp; Test</name>
            <description>Two blocks</description>
            <sportType>bike</sportType>
            <workout>
                <Warmup Duration="600" PowerLow="0.25" PowerHigh="0.75"/>
                <SteadyState Duration="300" Power="0.88" Cadence="90">
                    <textevent timeoffset="10" message="Settle in"/>
                </SteadyState>
                <IntervalsT Repeat="4" OnDuration="60" OffDuration="120" OnPower="1.2" OffPower="0.5"/>
                <FreeRide Duration="120" FlatRoad="1"/>
                <Cooldown Duration="300" PowerLow="0.7" PowerHigh="0.3"/>
            </workout>
        </workout_file>
        """
        let w = try ZWOFormat.parse(Data(xml.utf8))
        XCTAssertEqual(w.name, "Sample & Test")
        XCTAssertEqual(w.author, "Coach")
        XCTAssertEqual(w.steps.count, 5)
        XCTAssertEqual(w.duration, 2040.0)  // 600 + 300 + 4·180 + 120 + 300
        XCTAssertEqual(w.steps[1], .steady(duration: 300, power: 0.88, cadence: 90))
        XCTAssertEqual(w.steps[4], .ramp(duration: 300, from: 0.7, to: 0.3, cadence: nil))

        let round = try ZWOFormat.parse(Data(ZWOFormat.export(w).utf8))
        XCTAssertEqual(round.duration, w.duration)
        XCTAssertEqual(round.steps.count, w.steps.count)
    }

    func testZWORejectsGarbage() {
        XCTAssertThrowsError(try ZWOFormat.parse(Data("not xml".utf8)))
        XCTAssertThrowsError(try ZWOFormat.parse(Data("<workout_file><workout></workout></workout_file>".utf8)))
    }

    func testPowerAnalysis() {
        XCTAssertEqual(PowerAnalysis.normalizedPower(Array(repeating: 200, count: 600)), 200, accuracy: 1e-9)
        // Variable power has NP above average power.
        let variable = (0..<1200).map { ($0 / 60) % 2 == 0 ? 350.0 : 100.0 }
        let avg = variable.reduce(0, +) / Double(variable.count)
        XCTAssertGreaterThan(PowerAnalysis.normalizedPower(variable), avg + 20)
        XCTAssertEqual(PowerAnalysis.bestAverage(variable, window: 60), 350)
        XCTAssertNil(PowerAnalysis.bestAverage([1, 2], window: 5))
    }

    private func sampleRide() -> (RideSummary, [RideSample]) {
        let samples = (0..<120).map { i in
            RideSample(t: Double(i), distance: Double(i) * 10, latitude: 45.05 + Double(i) * 9e-5, longitude: 6.03,
                       elevation: 720 + Double(i) * 0.8, speed: 10, power: 250, cadence: 90, heartRate: 150, grade: 0.08)
        }
        var m = PowerAnalysis.metrics(samples: samples, ftp: 250)
        m.distance = 1190
        let summary = RideSummary(date: Date(timeIntervalSince1970: 1_700_000_000), routeID: "alpe-dhuez", routeName: "Alpe d'Huez",
                                  mode: .freeRide, laps: 1, workoutName: nil, finishPosition: nil, riders: 1, completed: false,
                                  metrics: m, climbs: [], xpEarned: 0, ftpAtTime: 250, weightAtTime: 70)
        return (summary, samples)
    }

    func testMetrics() {
        let (s, _) = sampleRide()
        XCTAssertEqual(s.metrics.averagePower, 250)
        XCTAssertEqual(s.metrics.normalizedPower, 250, accuracy: 1e-6)
        XCTAssertEqual(s.metrics.intensityFactor, 1, accuracy: 1e-6)
        XCTAssertEqual(s.metrics.trainingStressScore, 120.0 / 3600 * 100, accuracy: 0.01)
        XCTAssertEqual(s.metrics.elevationGain, 119 * 0.8, accuracy: 1e-6)
        XCTAssertEqual(s.metrics.zoneSeconds[3], 120)
        XCTAssertEqual(s.metrics.powerCurve[60], 250)
    }

    func testFITFileIsStructurallyValid() {
        let (summary, samples) = sampleRide()
        let data = [UInt8](FITEncoder.encode(summary: summary, samples: samples, start: summary.date))
        XCTAssertEqual(data[0], 14)
        XCTAssertEqual(Array(data[8..<12]), Array(".FIT".utf8))
        let dataSize = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        XCTAssertEqual(dataSize + 14 + 2, data.count)
        // Header CRC and file CRC: running the CRC over the bytes including a trailing CRC yields 0.
        XCTAssertEqual(FITEncoder.crc(Array(data[0..<14])), 0)
        XCTAssertEqual(FITEncoder.crc(data), 0)
        // file_id definition message comes first.
        XCTAssertEqual(data[14], 0x40)
    }

    func testFITKnownCRC() {
        // Reference value from the FIT SDK CRC for the ASCII string "123456789".
        XCTAssertEqual(FITEncoder.crc(Array("123456789".utf8)), 0xBB3D)
    }

    func testGPXRoundTrip() throws {
        let (summary, samples) = sampleRide()
        let gpx = GPXFormat.exportRide(summary: summary, samples: samples, start: summary.date)
        XCTAssertTrue(gpx.contains("<power>250</power>"))
        let imported = try GPXFormat.importTrack(Data(gpx.utf8), fallbackName: "x")
        XCTAssertEqual(imported.name, "Alpe d'Huez")
        XCTAssertTrue(imported.hadElevation)
        XCTAssertEqual(imported.coordinates.count, samples.count)
        XCTAssertEqual(imported.elevations.last ?? 0, samples.last!.elevation, accuracy: 25)

        let tcx = GPXFormat.exportTCX(summary: summary, samples: samples, start: summary.date)
        XCTAssertTrue(tcx.contains("<ns3:Watts>250</ns3:Watts>"))
    }

    func testImportedRouteBuildsAndDetectsClimb() throws {
        // 3 km straight north at 6 %.
        var gpx = "<gpx><trk><name>Test Hill</name><trkseg>"
        for i in 0...300 {
            gpx += String(format: "<trkpt lat=\"%.6f\" lon=\"6.0\"><ele>%.1f</ele></trkpt>", 45.0 + Double(i) * 10 / 111_132, 500 + Double(i) * 0.6)
        }
        gpx += "</trkseg></trk></gpx>"
        let t = try GPXFormat.importTrack(Data(gpx.utf8), fallbackName: "x")
        let route = Route(importedName: t.name, coordinates: t.coordinates, elevations: t.elevations)
        XCTAssertFalse(route.isLoop)
        XCTAssertEqual(route.length, 3000, accuracy: 30)
        XCTAssertEqual(route.climbs.count, 1)
        XCTAssertEqual(route.climbs[0].averageGrade, 0.06, accuracy: 0.01)
        XCTAssertEqual(route.grade(at: 1500), 0.06, accuracy: 0.005)
        // Terrain without a DEM still meets the road.
        let p = route.position(at: 1500)
        XCTAssertEqual(route.terrain.height(x: p.x, y: p.y), route.elevation(at: 1500), accuracy: 0.5)
    }

    func testPolylineRoundTrip() {
        let pts = [PolylineCodec.Point3(latitude: 45.05547, longitude: 6.03279, elevation: 718.3),
                   PolylineCodec.Point3(latitude: 45.05612, longitude: 6.03301, elevation: 719.9),
                   PolylineCodec.Point3(latitude: -34.42630, longitude: 150.90410, elevation: 0)]
        XCTAssertEqual(PolylineCodec.decode3(PolylineCodec.encode3(pts)), pts)
    }

    func testGeoDistance() {
        let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
        let london = GeoCoordinate(latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(Geo.distance(paris, london) / 1000, 343.5, accuracy: 1.5)
        let proj = LocalProjection(origin: paris)
        let back = proj.toGeo(proj.toLocal(london))
        XCTAssertEqual(back.latitude, london.latitude, accuracy: 1e-9)
    }
}
