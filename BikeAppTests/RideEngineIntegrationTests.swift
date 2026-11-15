import XCTest
@testable import BikeApp

/// Runs the real ride loop with the demo trainer for a few seconds.
@MainActor
final class RideEngineIntegrationTests: XCTestCase {
    private func makeModel() -> AppModel {
        AppModel.isolated(suite: "BikeAppIntegrationTests")
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testFreeRideWithDemoTrainer() {
        let model = makeModel()
        model.ble.startTemporaryDemo()
        let config = SessionConfig(name: "Test", courseTitle: "Hügelig", gradeRange: GradeRange(min: -5, max: 7), seed: 1, goal: .distance(meters: 50_000), workout: nil, workoutMode: .ergOffset)
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        engine.start()
        spin(3.5)
        XCTAssertEqual(engine.phase, .riding)
        XCTAssertGreaterThan(engine.power3s, 100)
        XCTAssertGreaterThan(engine.cadence, 40)
        XCTAssertGreaterThan(engine.distance, 2)
        XCTAssertGreaterThanOrEqual(engine.recorder.samples.count, 2)
        XCTAssertNotNil(engine.heartRate)

        let gear = engine.gearbox.gear
        engine.shift(.up)
        engine.shift(.up)
        XCTAssertEqual(engine.gearbox.gear, gear + 2)

        engine.togglePause()
        XCTAssertEqual(engine.phase, .paused)
        let distance = engine.distance
        spin(0.6)
        XCTAssertEqual(engine.distance, distance, "no distance while paused")
        engine.togglePause()
        XCTAssertEqual(engine.phase, .riding)

        engine.finish()
        XCTAssertEqual(engine.phase, .finished)
        XCTAssertEqual(engine.recorder.laps.count, 1)
    }

    func testWorkoutUsesErgTargetsAndClickOffset() {
        let model = makeModel()
        model.ble.startTemporaryDemo()
        let workout = Workout(id: "w", name: "Kurz", date: nil, eventId: 42, description: nil, steps: [.steady(3, 0.6), .steady(600, 0.9)])
        let config = SessionConfig(name: "Kurz", courseTitle: "", gradeRange: GradeRange(min: 0, max: 2), seed: 1, goal: .workout, workout: workout, workoutMode: .ergOffset)
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        engine.start()
        spin(1.5)
        XCTAssertTrue(engine.isErgActive)
        XCTAssertEqual(engine.targetWatts, 150)
        XCTAssertTrue(engine.clickAdjustsErgOffset)
        engine.shift(.up)
        XCTAssertEqual(engine.ergOffset, 5)
        XCTAssertEqual(engine.targetWatts, 155)
        // The demo trainer follows the ERG target.
        spin(3)
        XCTAssertEqual(engine.targetWatts, 230) // second step: 225 W + 5 W offset
        XCTAssertEqual(Double(engine.power3s), 205, accuracy: 60)
        engine.finish()
        XCTAssertGreaterThanOrEqual(engine.recorder.laps.count, 2)
    }

    func testFinishedRideBuildsFIT() {
        let model = makeModel()
        model.ble.startTemporaryDemo()
        model.settings.autoUpload = false
        model.startRide(SessionConfig(name: "FIT", courseTitle: "", gradeRange: GradeRange(min: -3, max: 4), seed: 3, goal: .duration(seconds: 2.5), workout: nil, workoutMode: .ergOffset))
        spin(4)
        let finished = model.finished
        XCTAssertNotNil(finished)
        XCTAssertGreaterThan(finished?.fit.count ?? 0, 100)
        XCTAssertEqual(finished?.uploadState, .waitingForKey)
        XCTAssertFalse(model.isRiding)
    }
}
