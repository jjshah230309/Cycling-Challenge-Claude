import XCTest
@testable import BreakawayCore

final class RouteAndSimulationTests: XCTestCase {
    func testCatalogueDecodes() {
        XCTAssertGreaterThanOrEqual(RouteCatalog.all.count, 12)
        XCTAssertEqual(Set(RouteCatalog.all.map(\.id)).count, RouteCatalog.all.count)
        for rec in RouteCatalog.all {
            let route = Route(record: rec)
            XCTAssertGreaterThan(route.points.count, 50, rec.id)
            XCTAssertGreaterThan(route.length, 1500, rec.id)
            XCTAssertNotNil(rec.terrain, rec.id)
            XCTAssertTrue(rec.terrain?.isValid ?? false, rec.id)
            if rec.isLoop {
                XCTAssertEqual(route.points.first!.distance(to: route.points.last!), 0, accuracy: 1, rec.id)
            }
        }
    }

    /// The generated data must stay faithful to the published race figures.
    func testRoutesMatchOfficialStatistics() {
        for rec in RouteCatalog.all {
            let route = Route(record: rec)
            if let km = rec.official?.distanceKm {
                // Approximate reconstructions are allowed more slack (see docs/ROUTES.md).
                let tolerance = rec.quality == .verified ? 0.06 : 0.15
                XCTAssertEqual(route.length / 1000, km, accuracy: km * tolerance, "\(rec.id) distance")
            }
            if let gain = rec.official?.elevationGainM, !rec.isLoop {
                XCTAssertEqual(route.maxElevation - route.elevations[0], gain, accuracy: gain * 0.1, "\(rec.id) climbing")
            }
        }
    }

    func testFamousClimbsAreDetectedAndCategorised() throws {
        let alpe = try XCTUnwrap(RouteCatalog.route(id: "alpe-dhuez"))
        let main = try XCTUnwrap(alpe.climbs.max { $0.elevationGain < $1.elevationGain })
        XCTAssertEqual(main.name, "Alpe d'Huez")
        XCTAssertEqual(main.category, .hc)
        XCTAssertEqual(main.averageGrade, 0.08, accuracy: 0.012)
        XCTAssertGreaterThan(main.length, 12_000)

        let zoncolan = try XCTUnwrap(RouteCatalog.route(id: "zoncolan"))
        XCTAssertGreaterThan(zoncolan.maxGrade, 0.15)

        let sanremo = try XCTUnwrap(RouteCatalog.route(id: "sanremo-finale"))
        let names = sanremo.climbs.map(\.name)
        XCTAssertTrue(names.contains("Cipressa"), "\(names)")
        XCTAssertTrue(names.contains("Poggio"), "\(names)")
        XCTAssertLessThan(names.firstIndex(of: "Cipressa")!, names.firstIndex(of: "Poggio")!)
    }

    /// Grand Tour climbs only go up: no DEM-noise dips that would let a rider freewheel mid-climb.
    func testGrandTourClimbsNeverFakeADescent() {
        for rec in RouteCatalog.all where rec.category == .grandTourClimb {
            let r = Route(record: rec)
            var worstDrop = 0.0
            for d in stride(from: 0.0, to: r.length - 100, by: 25) {
                worstDrop = max(worstDrop, r.elevation(at: d) - r.elevation(at: d + 100))
            }
            XCTAssertLessThan(worstDrop, 0.5, rec.id)
        }
    }

    func testCobbledSectorsArePresent() throws {
        let arenberg = try XCTUnwrap(RouteCatalog.route(id: "arenberg"))
        let sector = try XCTUnwrap(arenberg.record.surfaces.first)
        XCTAssertEqual(sector.endMeters - sector.startMeters, 2300, accuracy: 250)
        XCTAssertEqual(arenberg.surface(at: (sector.startMeters + sector.endMeters) / 2), .cobbles)
        XCTAssertEqual(arenberg.surface(at: 10), .asphalt)
    }

    func testTerrainMeetsTheRoadAndHasRealMountains() throws {
        let stelvio = try XCTUnwrap(RouteCatalog.route(id: "stelvio"))
        let t = stelvio.terrain
        for d in stride(from: 500.0, to: stelvio.length, by: 2500) {
            let p = stelvio.position(at: d)
            XCTAssertEqual(t.height(x: p.x, y: p.y), stelvio.elevation(at: d) - 0.18, accuracy: 0.6)
        }
        // The DEM around the pass reaches well above the road (Ortler group peaks are ~3,900 m).
        XCTAssertGreaterThan(t.highestPoint, 3000)
        XCTAssertLessThan(t.lowestPoint, 1000)
    }

    /// The DEM grid is coarse; the terrain must still sit on the surveyed road
    /// (otherwise hairpin stacks get walls and cuttings tens of metres high).
    func testTerrainIsAnchoredToTheRoad() throws {
        for id in ["stelvio", "alpe-dhuez", "galibier", "zoncolan", "angliru"] {
            let r = try XCTUnwrap(RouteCatalog.route(id: id))
            let errors = stride(from: 0.0, to: r.length, by: 50).map { d -> Double in
                let p = r.position(at: d)
                return abs(r.terrain.naturalHeight(x: p.x, y: p.y) - r.elevation(at: d))
            }.sorted()
            XCTAssertLessThan(errors[errors.count / 2], 4, "\(id) median")
            XCTAssertLessThan(errors[Int(Double(errors.count) * 0.9)], 10, "\(id) p90")
        }
    }

    func testWaterIsDetectedOnTheCoast() throws {
        let sanremo = try XCTUnwrap(RouteCatalog.route(id: "sanremo-finale"))
        XCTAssertNotNil(sanremo.terrain.waterLevel)
        let alpe = try XCTUnwrap(RouteCatalog.route(id: "alpe-dhuez"))
        XCTAssertNil(alpe.terrain.waterLevel)
    }

    func testLoopSamplingWraps() throws {
        let mtl = try XCTUnwrap(RouteCatalog.route(id: "montreal-2026"))
        XCTAssertTrue(mtl.isLoop)
        let a = mtl.sample(at: 100), b = mtl.sample(at: mtl.length + 100)
        XCTAssertEqual(a.position.distance(to: b.position), 0, accuracy: 1e-6)
        XCTAssertEqual(mtl.sample(at: -50).distance, mtl.length - 50, accuracy: 1e-6)
    }

    func testFreeRideClimbsAlpeDHuez() throws {
        let route = try XCTUnwrap(RouteCatalog.route(id: "alpe-dhuez"))
        let profile = RiderProfile(weightKg: 70, ftp: 280)
        let sim = RideSimulation(route: route, mode: .freeRide, profile: profile, botCount: 6)
        var events: [RideEvent] = []
        for _ in 0..<(10 * 60 * 20) {   // 10 minutes at 20 Hz
            sim.step(dt: 0.05, input: PlayerInput(power: 280, cadence: 85))
            events += sim.drainEvents()
        }
        // ~4 W/kg on 8 % is ~15–17 km/h.
        XCTAssertEqual(sim.player.distance / 600 * 3.6, 16, accuracy: 2.5)
        XCTAssertTrue(events.contains { if case let .climbStarted(name, _, _, _) = $0 { return name == "Alpe d'Huez" }; return false })
        XCTAssertEqual(Double(sim.recorder.samples.count), 600, accuracy: 1)
        XCTAssertEqual(sim.bots.count, 6)
        if case let .simulation(grade, _, _, _) = sim.trainerTarget {
            // 50 % trainer difficulty halves the real gradient.
            XCTAssertEqual(grade, sim.sample.grade * 100 * 0.5, accuracy: 0.1)
        } else {
            XCTFail("expected simulation-mode trainer target")
        }
    }

    func testTimeTrialHasNoBotsOrDraft() throws {
        let route = try XCTUnwrap(RouteCatalog.route(id: "arenberg"))
        let sim = RideSimulation(route: route, mode: .timeTrial, profile: RiderProfile(), botCount: 10)
        XCTAssertTrue(sim.bots.isEmpty)
        for _ in 0..<200 { sim.step(dt: 0.05, input: PlayerInput(power: 250, cadence: 90)) }
        XCTAssertEqual(sim.player.draft, 0)
    }

    func testRaceFinishesWithPosition() throws {
        let route = try XCTUnwrap(RouteCatalog.route(id: "mur-de-huy"))
        let sim = RideSimulation(route: route, mode: .race, profile: RiderProfile(weightKg: 70, ftp: 300), botCount: 9)
        var finished: RideEvent?
        for _ in 0..<(20 * 60 * 20) where !sim.isFinished {
            sim.step(dt: 0.05, input: PlayerInput(power: 330, cadence: 90))
            for e in sim.drainEvents() { if case .finished = e { finished = e } }
        }
        XCTAssertTrue(sim.isFinished)
        guard case let .finished(position, seconds)? = finished else { return XCTFail("no finish event") }
        XCTAssertNotNil(position)
        XCTAssertGreaterThan(seconds, 60)
        let summary = sim.makeSummary()
        XCTAssertTrue(summary.completed)
        XCTAssertEqual(summary.riders, 10)
        XCTAssertGreaterThan(summary.xpEarned, 0)
        XCTAssertFalse(summary.climbs.isEmpty)
    }

    func testWorkoutModeDrivesERG() throws {
        let route = try XCTUnwrap(RouteCatalog.route(id: "roubaix-finale"))
        let workout = try XCTUnwrap(WorkoutLibrary.workout(id: "sweetspot-3x12"))
        let sim = RideSimulation(route: route, mode: .workout, profile: RiderProfile(ftp: 250), botCount: 0, workout: workout)
        for _ in 0..<(11 * 60 * 10) { sim.step(dt: 0.1, input: PlayerInput(power: 200, cadence: 90)) }
        XCTAssertEqual(sim.trainerTarget, .erg(watts: (0.91 * 250).rounded()))
        sim.ergEnabled = false
        if case .erg = sim.trainerTarget { XCTFail("ERG should be off") }
    }

    func testLapsOnCircuit() throws {
        let route = try XCTUnwrap(RouteCatalog.route(id: "montreal-2026"))
        let sim = RideSimulation(route: route, laps: 2, mode: .freeRide, profile: RiderProfile(ftp: 400), botCount: 0)
        var laps = 0
        while !sim.isFinished && sim.elapsed < 7200 {
            sim.step(dt: 0.2, input: PlayerInput(power: 400, cadence: 90))
            for e in sim.drainEvents() { if case .lapCompleted = e { laps += 1 } }
        }
        XCTAssertTrue(sim.isFinished)
        XCTAssertEqual(laps, 1)
        XCTAssertEqual(sim.lapTimes.count, 2)
        XCTAssertEqual(sim.player.distance, route.length * 2, accuracy: 1)
    }
}
