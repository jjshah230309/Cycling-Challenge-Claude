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
}
