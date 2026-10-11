import XCTest
@testable import BreakawayCore

final class PhysicsTests: XCTestCase {
    let body = PhysicsBody(mass: 80, cda: 0.32)

    func testFlatSpeedAt250W() {
        let v = CyclingPhysics.steadySpeed(power: 250, grade: 0, body: body) * 3.6
        // A 72 kg rider on the hoods at 250 W rides ~35–37 km/h on the flat.
        XCTAssertGreaterThan(v, 34)
        XCTAssertLessThan(v, 38)
    }

    func testClimbingSpeed() {
        let v = CyclingPhysics.steadySpeed(power: 300, grade: 0.08, body: body) * 3.6
        XCTAssertGreaterThan(v, 13)
        XCTAssertLessThan(v, 15.5)
    }

    func testPowerAndSpeedAreInverse() {
        for grade in [-0.04, 0.0, 0.03, 0.1] {
            let p = CyclingPhysics.powerRequired(speed: 9, grade: grade, body: body)
            guard p > 0 else { continue }
            XCTAssertEqual(CyclingPhysics.steadySpeed(power: p, grade: grade, body: body), 9, accuracy: 0.01)
        }
    }

    func testDescendingWithoutPedallingReachesTerminalVelocity() {
        var v = 5.0
        for _ in 0..<600 {
            v = CyclingPhysics.step(speed: v, power: 0, grade: -0.07, dt: 0.1, body: body, surface: .asphalt, airDensity: 1.2)
        }
        let terminal = v * 3.6
        XCTAssertGreaterThan(terminal, 55)
        XCTAssertLessThan(terminal, 80)
    }

    func testStepConvergesToSteadyState() {
        var v = 0.0
        for _ in 0..<3000 {
            v = CyclingPhysics.step(speed: v, power: 250, grade: 0.02, dt: 0.05, body: body, surface: .asphalt, airDensity: 1.225)
        }
        XCTAssertEqual(v, CyclingPhysics.steadySpeed(power: 250, grade: 0.02, body: body), accuracy: 0.05)
    }

    func testCobblesAreSlower() {
        let asphalt = CyclingPhysics.steadySpeed(power: 250, grade: 0, body: body, surface: .asphalt)
        let cobbles = CyclingPhysics.steadySpeed(power: 250, grade: 0, body: body, surface: .cobbles)
        XCTAssertLessThan(cobbles, asphalt - 0.8)   // ~3.5 km/h slower at 250 W
    }

    func testDraftingSavesWatts() {
        XCTAssertEqual(Drafting.reduction(gap: 1.0), 0.33 * exp(-0.5 / 3.6), accuracy: 1e-9)
        XCTAssertGreaterThan(Drafting.reduction(gap: 1), Drafting.reduction(gap: 5))
        XCTAssertGreaterThan(Drafting.reduction(gap: 1, ridersAhead: 20), Drafting.reduction(gap: 1, ridersAhead: 1))
        XCTAssertEqual(Drafting.reduction(gap: 20), 0)
        XCTAssertEqual(Drafting.reduction(gap: 1, lateral: 2), 0)
        let solo = CyclingPhysics.powerRequired(speed: 11, grade: 0, body: body)
        let sheltered = CyclingPhysics.powerRequired(speed: 11, grade: 0, body: body, draft: Drafting.reduction(gap: 1))
        XCTAssertLessThan(sheltered, solo * 0.8)
    }

    func testAirDensityFallsWithAltitude() {
        XCTAssertEqual(CyclingPhysics.airDensity(altitude: 0), 1.225, accuracy: 0.002)
        XCTAssertLessThan(CyclingPhysics.airDensity(altitude: 2700), 0.97)
    }

    func testGarageRatingsAndProfileBody() {
        var profile = RiderProfile(weightKg: 70, heightCm: 178)
        profile.bike = BikeSetup(frameID: "velocity", wheelsID: "disc")
        let tt = profile.physicsBody()
        profile.bike = BikeSetup(frameID: "summit", wheelsID: "climber")
        let climber = profile.physicsBody()
        XCTAssertLessThan(tt.cda, climber.cda)
        XCTAssertGreaterThan(tt.mass, climber.mass)
        XCTAssertGreaterThan(BikeSetup(frameID: "summit", wheelsID: "climber").climbRating, BikeSetup(frameID: "velocity", wheelsID: "disc").climbRating)
    }

    func testLevels() {
        var p = RiderProfile()
        XCTAssertEqual(p.level, 1)
        p.xp = RiderProfile.xpForLevel(5)
        XCTAssertEqual(p.level, 5)
        XCTAssertEqual(p.levelProgress, 0, accuracy: 1e-9)
    }

    // MARK: - Environment & aerodynamics

    func testHumidAndHotAirIsThinner() {
        let dry = CyclingPhysics.airDensity(altitude: 0, temperatureC: 25, relativeHumidity: 0)
        let humid = CyclingPhysics.airDensity(altitude: 0, temperatureC: 25, relativeHumidity: 1)
        XCTAssertLessThan(humid, dry)
        XCTAssertEqual(dry - humid, 0.012, accuracy: 0.004)   // ~1 % lighter at 25 °C
        XCTAssertLessThan(CyclingPhysics.airDensity(altitude: 0, temperatureC: 35), CyclingPhysics.airDensity(altitude: 0, temperatureC: 5))
        // Weather temperature lapses with altitude.
        let w = Weather(windSpeed: 0, windFromDegrees: 0, temperatureC: 20)
        XCTAssertEqual(w.temperature(at: 2000), 7, accuracy: 0.01)
    }

    func testHeadwindAndTailwind() {
        let still = CyclingPhysics.steadySpeed(power: 250, body: body, conditions: RideConditions())
        let head = CyclingPhysics.steadySpeed(power: 250, body: body, conditions: RideConditions(headwind: 5))
        let tail = CyclingPhysics.steadySpeed(power: 250, body: body, conditions: RideConditions(headwind: -5))
        XCTAssertLessThan(head, still - 2.5)
        XCTAssertGreaterThan(tail, still + 2)
    }

    func testDeepRimsPayOffInACrosswind() {
        let shallow = PhysicsBody(mass: 80, cda: 0.30, rimDepth: 0.025)
        let deep = PhysicsBody(mass: 80, cda: 0.30, rimDepth: 0.08)
        XCTAssertEqual(shallow.cda(yaw: 0), deep.cda(yaw: 0), accuracy: 1e-9)
        let yaw = 10 * Double.pi / 180
        XCTAssertLessThan(deep.cda(yaw: yaw), shallow.cda(yaw: yaw))
        // A pure crosswind still costs speed (more frontal area at yaw).
        let c = RideConditions(crosswind: 6)
        XCTAssertLessThan(CyclingPhysics.steadySpeed(power: 250, body: shallow, conditions: c),
                          CyclingPhysics.steadySpeed(power: 250, body: shallow, conditions: RideConditions()))
    }

    func testPostureChangesDrag() {
        XCTAssertLessThan(RiderPosture.tuck.dragFactor, RiderPosture.drops.dragFactor)
        XCTAssertLessThan(RiderPosture.drops.dragFactor, RiderPosture.hoods.dragFactor)
        XCTAssertGreaterThan(RiderPosture.standing.dragFactor, RiderPosture.hoods.dragFactor)
        // Freewheeling down 6 %: the tuck is ~4–8 km/h faster than sitting up.
        func coast(_ p: RiderPosture) -> Double {
            CyclingPhysics.steadySpeed(power: 0, body: body, conditions: RideConditions(grade: -0.06, posture: p)) * 3.6
        }
        XCTAssertGreaterThan(coast(.tuck) - coast(.hoods), 4)
        XCTAssertLessThan(coast(.tuck) - coast(.hoods), 9)
    }

    func testBearingAndSpeedDependentRollingLosses() {
        XCTAssertEqual(CyclingPhysics.bearingForce(speed: 10), 0.178, accuracy: 1e-9)
        let slowCobbles = CyclingPhysics.rollingCoefficient(speed: 3, body: body, surface: .cobbles)
        let fastCobbles = CyclingPhysics.rollingCoefficient(speed: 12, body: body, surface: .cobbles)
        XCTAssertGreaterThan(fastCobbles / slowCobbles, 1.4)
        let fastTarmac = CyclingPhysics.rollingCoefficient(speed: 12, body: body, surface: .asphalt)
        XCTAssertEqual(fastTarmac, 0.0037 * 1.12, accuracy: 1e-9)
    }

    func testBrakingForACornerLimit() {
        var v = 20.0
        var braked = false
        for _ in 0..<40 {
            let r = CyclingPhysics.step(speed: v, power: 300, dt: 0.1, body: body, conditions: RideConditions(grade: -0.08),
                                        speedLimit: 9)
            v = r.speed
            braked = braked || r.braking
        }
        XCTAssertTrue(braked)
        XCTAssertEqual(v, 9, accuracy: 0.2)
        // Never decelerates harder than the tyres allow (6 m/s² on tarmac).
        let one = CyclingPhysics.step(speed: 20, power: 0, dt: 0.1, body: body, conditions: RideConditions(), speedLimit: 0)
        XCTAssertGreaterThan(one.speed, 20 - 0.1 * 6.0 - 0.1)
    }

    func testCornerSpeedAndLean() {
        // A 10 m hairpin on dry tarmac: ~30 km/h at ~35° of lean.
        let v = Cornering.cornerSpeed(radius: 10, surface: .asphalt)
        XCTAssertEqual(v * 3.6, 29.8, accuracy: 0.5)
        XCTAssertEqual(Cornering.leanAngle(speed: v, curvature: 0.1) * 180 / .pi, 35, accuracy: 0.5)
        XCTAssertLessThan(Cornering.cornerSpeed(radius: 10, surface: .cobbles), v)
    }

    // MARK: - Physiology & drivetrain

    func testWPrimeBalanceDrainsAndRecovers() {
        var w = WPrimeBalance(cp: 300, capacity: 20_000)
        for _ in 0..<100 { w.update(power: 400, dt: 1) }            // 100 s at CP + 100 W
        XCTAssertEqual(w.fraction, 0.5, accuracy: 1e-9)
        for _ in 0..<200 { w.update(power: 500, dt: 1) }
        XCTAssertEqual(w.balance, 0)
        for _ in 0..<600 { w.update(power: 150, dt: 1) }            // ten minutes easy
        XCTAssertGreaterThan(w.fraction, 0.95)
    }

    func testGearsGiveRealisticCadence() {
        var d = Drivetrain.forFrame(.endurance)
        for _ in 0..<40 { d.shift(speed: 11, target: 90) }          // 40 km/h on the flat
        XCTAssertEqual(d.cadence(speed: 11), 90, accuracy: 7)
        XCTAssertEqual(d.frontTeeth, 52)
        for _ in 0..<40 { d.shift(speed: 3.5, target: 80) }         // 12.6 km/h up a col
        XCTAssertEqual(d.frontTeeth, 36)
        XCTAssertEqual(d.cadence(speed: 3.5), 80, accuracy: 9)
        // Small sprockets cost a little efficiency.
        var big = d; big.front = 1; big.rear = 0
        var mid = d; mid.front = 1; mid.rear = 5
        XCTAssertLessThan(big.efficiency, mid.efficiency)
        XCTAssertEqual(mid.efficiency, 0.98, accuracy: 0.01)
    }

    func testEchelonWakeDriftsDownwind() {
        XCTAssertEqual(Drafting.wakeOffset(gap: 2, yaw: 0), 0)
        XCTAssertEqual(Drafting.wakeOffset(gap: 2, yaw: 0.3), 2 * tan(0.3), accuracy: 1e-9)
        XCTAssertGreaterThan(Drafting.leaderBenefit(gapBehind: 0.5), 0.02)
        XCTAssertEqual(Drafting.leaderBenefit(gapBehind: 5), 0)
    }

    func testWindComponents() {
        // Wind from the north, riding north: pure headwind. Riding east: crosswind from the left (−).
        let w = Weather(windSpeed: 10, windFromDegrees: 0)
        let north = w.components(direction: LocalPoint(x: 0, y: 1), exposure: 1)
        XCTAssertEqual(north.head, 10, accuracy: 1e-9)
        XCTAssertEqual(north.cross, 0, accuracy: 1e-9)
        let east = w.components(direction: LocalPoint(x: 1, y: 0), exposure: 1)
        XCTAssertEqual(east.head, 0, accuracy: 1e-9)
        XCTAssertEqual(east.cross, -10, accuracy: 1e-9)
        XCTAssertLessThan(Weather.exposure(.forest), Weather.exposure(.coastal))
    }
}
