import XCTest
@testable import BikeApp

final class RideModelTests: XCTestCase {
    // MARK: Physics

    func testFlatSpeedAt200Watts() {
        let v = BikePhysics.steadySpeed(power: 200, gradePercent: 0, rider: RiderParameters())
        XCTAssertEqual(v * 3.6, 34, accuracy: 1.5)
    }

    func testClimbingSpeed() {
        let v = BikePhysics.steadySpeed(power: 245, gradePercent: 4.3, rider: RiderParameters())
        XCTAssertEqual(v * 3.6, 19.6, accuracy: 1)
    }

    func testCoastingDownhillHasTerminalSpeed() {
        let v = BikePhysics.steadySpeed(power: 0, gradePercent: -6, rider: RiderParameters())
        XCTAssertGreaterThan(v * 3.6, 40)
        XCTAssertEqual(BikePhysics.steadySpeed(power: 0, gradePercent: 2, rider: RiderParameters()), 0)
    }

    func testIntegrationConvergesToSteadySpeed() {
        var v = 0.0
        for _ in 0..<(4 * 180) {
            v = BikePhysics.advance(speed: v, power: 200, gradePercent: 0, dt: 0.25, rider: RiderParameters())
        }
        XCTAssertEqual(v, BikePhysics.steadySpeed(power: 200, gradePercent: 0, rider: RiderParameters()), accuracy: 0.15)
    }

    // MARK: Gears and resistance

    func testGearbox() {
        var box = VirtualGearbox(gear: 23)
        XCTAssertTrue(box.shift(.up))
        XCTAssertFalse(box.shift(.up))
        XCTAssertEqual(box.gear, 24)
        box = VirtualGearbox(gear: 1)
        XCTAssertFalse(box.shift(.down))
        XCTAssertEqual(VirtualGearbox.count, 24)
        XCTAssertEqual(VirtualGearbox.ratios, VirtualGearbox.ratios.sorted())
    }

    func testMatchedSimulationWithEqualRatiosPassesGradeThrough() {
        let input = ResistanceInput(gradePercent: 5, difficulty: 1, virtualRatio: 2.4, trainerRatio: 2.4, cadence: 90, rider: RiderParameters())
        guard case let .simulation(grade, crr, wind) = MatchedSimulationStrategy().command(for: input) else {
            return XCTFail("expected simulation")
        }
        XCTAssertEqual(grade, 5, accuracy: 0.05)
        XCTAssertEqual(crr, 0.004, accuracy: 1e-6)
        XCTAssertEqual(wind, 1.2 * 0.32, accuracy: 1e-6)
    }

    func testHarderGearMeansMoreTrainerResistance() {
        func trainerPower(_ command: TrainerCommand, speed v: Double) -> Double {
            guard case let .simulation(g, crr, cw) = command else { return 0 }
            let theta = atan(g / 100)
            return (83 * 9.81 * (crr * cos(theta) + sin(theta)) + 0.5 * cw * v * v) * v
        }
        let strategy = MatchedSimulationStrategy()
        var input = ResistanceInput(gradePercent: 2, difficulty: 1, virtualRatio: 2.4, trainerRatio: 2.4, cadence: 90, rider: RiderParameters())
        let easy = trainerPower(strategy.command(for: input), speed: 8)
        input.virtualRatio = 3.24
        let hard = trainerPower(strategy.command(for: input), speed: 8)
        XCTAssertGreaterThan(hard, easy * 1.3)

        // With k = 1.35 the trainer power at speed v should match the road power at speed k·v.
        let k = 3.24 / 2.4
        let road = BikePhysics.powerRequired(speed: 8 * k, gradePercent: 2, rider: RiderParameters()) * RiderParameters().drivetrainEfficiency
        XCTAssertEqual(hard, road, accuracy: road * 0.03)
    }

    func testDifficultyScalesGrade() {
        let input = ResistanceInput(gradePercent: 8, difficulty: 0.5, virtualRatio: 2.4, trainerRatio: 2.4, cadence: 90, rider: RiderParameters())
        guard case let .simulation(grade, _, _) = MatchedSimulationStrategy().command(for: input) else { return XCTFail() }
        XCTAssertEqual(grade, 4, accuracy: 0.05)
    }

    func testErgVirtualStrategy() {
        let input = ResistanceInput(gradePercent: 0, difficulty: 1, virtualRatio: 2.4, trainerRatio: 2.4, cadence: 90, rider: RiderParameters())
        guard case let .targetPower(watts) = ErgVirtualStrategy().command(for: input) else { return XCTFail() }
        // 90 rpm × 2.4 × 2.096 m = 7.55 m/s ≈ 27 km/h on the flat
        XCTAssertEqual(Double(watts), BikePhysics.powerRequired(speed: 90.0 / 60 * 2.4 * 2.096, gradePercent: 0, rider: RiderParameters()), accuracy: 1)
    }

    func testRatioCalibrator() {
        var c = TrainerRatioCalibrator()
        for _ in 0..<50 {
            // 90 rpm with 34/14 and 2.096 m wheel
            c.add(trainerSpeed: 90.0 / 60 * (34.0 / 14) * 2.096, cadence: 90, wheelCircumference: 2.096)
        }
        XCTAssertTrue(c.isCalibrated)
        XCTAssertEqual(c.estimate ?? 0, 34.0 / 14, accuracy: 0.01)
    }

    // MARK: Elevation profile

    func testProfileIsDeterministic() {
        let a = ElevationProfile(range: GradeRange(min: -5, max: 7), seed: 1234)
        let b = ElevationProfile(range: GradeRange(min: -5, max: 7), seed: 1234)
        a.ensure(distance: 30_000)
        b.ensure(distance: 30_000)
        XCTAssertEqual(a.grades, b.grades)
        let c = ElevationProfile(range: GradeRange(min: -5, max: 7), seed: 999)
        c.ensure(distance: 30_000)
        XCTAssertNotEqual(a.grades, c.grades)
    }

    func testProfileStaysInRange() {
        for preset in CoursePreset.allCases {
            guard let range = preset.range else { continue }
            let p = ElevationProfile(range: range, seed: 42)
            p.ensure(distance: 100_000)
            XCTAssertGreaterThanOrEqual(p.grades.min() ?? 0, range.min - 1e-9, preset.title)
            XCTAssertLessThanOrEqual(p.grades.max() ?? 0, range.max + 1e-9, preset.title)
        }
    }

    func testHillyProfileHasClimbsAndDescentsAndDoesNotDrift() {
        let p = ElevationProfile(range: GradeRange(min: -5, max: 7), seed: 7)
        p.ensure(distance: 200_000)
        XCTAssertLessThan(p.grades.min() ?? 0, -2)
        XCTAssertGreaterThan(p.grades.max() ?? 0, 4)
        let elevations = p.endElevations
        XCTAssertLessThan((elevations.max() ?? 0) - (elevations.min() ?? 0), 1200)
    }

    func testProfileColumnsAndAscent() {
        let p = ElevationProfile(range: GradeRange(min: -6, max: 10), seed: 502)
        let cols = p.columns(from: 0, to: 30_000, count: 110)
        XCTAssertEqual(cols.count, 110)
        XCTAssertEqual(cols.map(\.norm).max() ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(cols.map(\.norm).min() ?? 1, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(p.ascent(upTo: 30_000), 50)
        XCTAssertEqual(p.elevation(at: 0), 0)
        let rolling = p.columns(from: -1000, to: 4000, count: 50)
        XCTAssertEqual(rolling.count, 50)
    }

    // MARK: Workout

    func testWorkoutPlayer() {
        let w = Workout(id: "w", name: "Test", date: nil, eventId: nil, description: nil, steps: [
            .ramp(600, from: 0.5, to: 0.7),
            .steady(300, 1.0),
            .steady(120, 0.5),
            .steady(300, 1.0),
            .free(60),
        ])
        let player = WorkoutPlayer(workout: w)
        XCTAssertEqual(player.duration, 1380)
        XCTAssertEqual(player.targetFraction(at: 0) ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(player.targetFraction(at: 300) ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(player.position(at: 700)?.index, 1)
        XCTAssertEqual(player.position(at: 700)?.remainingInStep ?? 0, 200, accuracy: 1e-9)
        XCTAssertNil(player.targetFraction(at: 1330))
        XCTAssertNil(player.position(at: 1380))
        XCTAssertEqual(player.repetition(of: 3)?.current, 2)
        XCTAssertEqual(player.repetition(of: 3)?.total, 2)
    }

    func testNormalizedPower() {
        XCTAssertEqual(RideSummary.normalizedPower(Array(repeating: 200, count: 120)), 200)
        let mixed = Array(repeating: 100, count: 300) + Array(repeating: 300, count: 300)
        XCTAssertGreaterThan(RideSummary.normalizedPower(mixed), 200)
    }

    func testPowerZones() {
        let z = PowerZones.standard
        XCTAssertEqual(z.index(watts: 120, ftp: 250), 0) // 48 %
        XCTAssertEqual(z.index(watts: 245, ftp: 250), 3) // 98 %
        XCTAssertEqual(z.index(watts: 400, ftp: 250), 5) // 160 %
        XCTAssertEqual(TargetCompliance(watts: 228, target: 230), .inTarget)
        XCTAssertEqual(TargetCompliance(watts: 200, target: 230), .tooLow)
        XCTAssertEqual(TargetCompliance(watts: 260, target: 230), .tooHigh)
    }
}
