import AppKit
import SwiftUI
import XCTest
@testable import BikeApp

/// Zwift Click v2 (two halves), Kickr Core 2 capabilities, rides without devices and the workout editor.
@MainActor
final class ClickV2AndWorkoutEditorTests: XCTestCase {
    // MARK: Click v2 protocol

    /// Encodes a Ride/Click v2 key pad message: 0x23, field 1 = button map as varint.
    private func keyPad(_ map: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x23, 0x08]
        var v = UInt64(map)
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            bytes.append(b)
        } while v != 0
        return bytes
    }

    func testDecodesButtonMap() {
        XCTAssertEqual(ZwiftClickProtocol.decode(keyPad(0xFFFF_FFFE)), .buttonMap(0xFFFF_FFFE))
        XCTAssertEqual(ZwiftClickProtocol.decode([0xFF, 0x03, 0x01, 0x02]), .locked)
        XCTAssertEqual(ZwiftClickProtocol.decode(Array("RideOn".utf8) + [0x02, 0x03]), .handshake(encrypted: false))
    }

    func testButtonMapTrackerIgnoresBitsNeverReleased() {
        var tracker = ButtonMapTracker()
        // Idle: only the low 20 bits exist, the high bits are always 0.
        XCTAssertEqual(tracker.pressed(0x000F_FFFF), [])
        // Bit 0x1000 cleared = pressed.
        XCTAssertEqual(tracker.pressed(0x000F_EFFF), [0x1000])
        XCTAssertEqual(tracker.pressed(0x000F_FFFF), [])
    }

    func testClassifiesClickV2Halves() {
        let right = Data([0x4A, 0x09, 0x0A, 0x12, 0x34])
        let left = Data([0x4A, 0x09, 0x0B, 0x12, 0x35])
        let v1 = Data([0x4A, 0x09, 0x09, 0x00, 0x01])
        XCTAssertEqual(DeviceClassifier.roles(name: "Zwift Click", services: [], manufacturerData: right), [.click])
        XCTAssertEqual(DeviceClassifier.roles(name: "Zwift Click", services: [], manufacturerData: left), [.clickLeft])
        XCTAssertEqual(DeviceClassifier.roles(name: "Zwift Click", services: [], manufacturerData: v1), [.click])
        XCTAssertEqual(ZwiftDeviceType.pod(for: 0x0B), .left)
        // The trainer wins even if a name looks Zwift-ish.
        XCTAssertEqual(DeviceClassifier.roles(name: "KICKR CORE 2 1A2B", services: [BLEUUID.ftmsService], manufacturerData: nil), [.trainer])
        XCTAssertEqual(DeviceClassifier.trainerModel(name: "KICKR CORE 2 1A2B"), "Kickr Core 2")
    }

    private func makeSettings() -> AppSettings {
        let suite = "BikeAppClickV2Tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    func testTwoHalvesShiftAndPauseTogether() {
        let router = ClickInputRouter(settings: makeSettings())
        var shifts: [ShiftDirection] = []
        var pauses = 0
        router.onShift = { shifts.append($0) }
        router.onBothButtons = { pauses += 1 }
        let right = UUID(), left = UUID()
        let plus = ClickButtonKey(pod: .right, id: 0x1000)
        let minus = ClickButtonKey(pod: .left, id: 0x100)

        router.update(source: right, pressed: [plus])
        router.update(source: right, pressed: [])
        router.update(source: left, pressed: [minus])
        router.update(source: left, pressed: [])
        XCTAssertEqual(shifts, [.up, .down])

        // Both halves at the same time: pause, and the first shift is taken back.
        shifts = []
        router.update(source: right, pressed: [plus])
        router.update(source: left, pressed: [minus])
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(shifts, [.up, .down])
        router.update(source: right, pressed: [])
        router.update(source: left, pressed: [])
    }

    func testLearnedMappingForOneHalf() {
        let settings = makeSettings()
        settings.clickButtonMap = ["right:4096": "up", "right:32": "down"]
        let router = ClickInputRouter(settings: settings)
        XCTAssertEqual(router.direction(for: ClickButtonKey(pod: .right, id: 4096)), .up)
        XCTAssertEqual(router.direction(for: ClickButtonKey(pod: .right, id: 32)), .down)
        XCTAssertNil(router.direction(for: ClickButtonKey(pod: .right, id: 64)), "unassigned buttons of a learned half do nothing")
        XCTAssertEqual(router.direction(for: ClickButtonKey(pod: .left, id: 1)), .down, "other half keeps its default")
        XCTAssertEqual(router.direction(for: .v1Plus), .up)
    }

    func testLearningReportsInsteadOfShifting() {
        let router = ClickInputRouter(settings: makeSettings())
        var learned: [ClickButtonKey] = []
        var shifted = false
        router.onShift = { _ in shifted = true }
        router.onLearn = { learned.append($0) }
        router.update(source: UUID(), pressed: [ClickButtonKey(pod: .right, id: 8)])
        XCTAssertEqual(learned, [ClickButtonKey(pod: .right, id: 8)])
        XCTAssertFalse(shifted)
    }

    // MARK: Trainer capabilities

    func testParsesFTMSFeaturesAndPowerRange() {
        // Machine features (any), target features: power target (bit 3) + simulation (bit 13).
        let features = FTMSFeatures.parse([0x00, 0x40, 0x00, 0x00, 0x08, 0x20, 0x00, 0x00])
        XCTAssertEqual(features, FTMSFeatures(supportsPowerTarget: true, supportsSimulation: true))
        XCTAssertEqual(FTMSFeatures.parse([0, 0, 0, 0, 0x08, 0, 0, 0])?.supportsSimulation, false)
        let range = PowerRange.parse([0x00, 0x00, 0xD0, 0x07, 0x01, 0x00])
        XCTAssertEqual(range, PowerRange(minimum: 0, maximum: 2000))
        XCTAssertEqual(range?.clamp(2500), 2000)
    }

    // MARK: Rides without devices

    func testRideWithoutAnyDeviceRunsAsTimer() {
        let model = AppModel.isolated(suite: "BikeAppSensorlessTests")
        let config = SessionConfig(name: "Test", courseTitle: "Flach", gradeRange: GradeRange(min: 0, max: 0), seed: 1, goal: .duration(seconds: 3600), workout: nil, workoutMode: .ergOffset)
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        engine.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(engine.phase, .waiting, "short grace period for sensors to wake up")
        RunLoop.main.run(until: Date().addingTimeInterval(5.5))
        XCTAssertTrue(engine.sensorless)
        XCTAssertEqual(engine.phase, .riding)
        XCTAssertGreaterThan(engine.movingTime, 0.3)
        engine.finish()
    }

    func testCadenceWithoutTrainerGivesSpeedFromGear() {
        let model = AppModel.isolated(suite: "BikeAppCadenceOnlyTests")
        let config = SessionConfig(name: "Test", courseTitle: "Flach", gradeRange: GradeRange(min: 0, max: 0), seed: 1, goal: .duration(seconds: 3600), workout: nil, workoutMode: .ergOffset)
        let engine = RideEngine(config: config, settings: model.settings, ble: model.ble) { 250 }
        engine.start()
        let feeder = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { model.ble.updatePedalCadence(90) }
        }
        RunLoop.main.add(feeder, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        feeder.invalidate()
        XCTAssertEqual(engine.phase, .riding)
        XCTAssertTrue(engine.speedFromCadence)
        XCTAssertFalse(engine.sensorless)
        XCTAssertGreaterThan(engine.speed * 3.6, 15)
        engine.finish()
    }

    // MARK: Workout editor model

    private var sweetSpot: CustomWorkout { CustomWorkout.templates[1] }

    func testCustomWorkoutExpandsRepeats() {
        let w = sweetSpot
        XCTAssertEqual(w.steps.count, 1 + 3 * 2 + 1)
        XCTAssertEqual(w.duration, (10 + 3 * 15 + 10) * 60)
        XCTAssertEqual(w.steps[1], .steady(600, 0.9, label: "Sweet Spot"))
        XCTAssertEqual(w.asWorkout.id, "custom-" + w.id.uuidString)
        XCTAssertNil(w.asWorkout.eventId)
        XCTAssertGreaterThan(w.stressScore, 50)
        XCTAssertLessThan(w.stressScore, 90)
    }

    func testIntervalsText() {
        let text = sweetSpot.intervalsText
        XCTAssertTrue(text.contains("- Aufwärmen 10m ramp 45-70%"), text)
        XCTAssertTrue(text.contains("3x\n- Sweet Spot 10m 90%\n- Erholung 5m 55%"), text)
        let odd = CustomWorkout(name: "x", blocks: [.steady(4.5, 100), .free(0.5)])
        XCTAssertEqual(odd.intervalsText, "- 4m30s 100%\n\n- 30s freeride")
    }

    func testImportedWorkoutBecomesRepeatGroups() {
        let imported = Workout(id: "event-1", name: "Imported", date: nil, eventId: 1, description: nil, steps: sweetSpot.steps)
        let copy = CustomWorkout.from(imported)
        XCTAssertEqual(copy.blocks.count, 3)
        XCTAssertEqual(copy.blocks[1].kind, .repeats)
        XCTAssertEqual(copy.blocks[1].reps, 3)
        XCTAssertEqual(copy.steps, imported.steps)
    }

    func testStorePersistsWorkouts() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BikeAppWorkouts-\(UUID().uuidString)")
        let store = CustomWorkoutStore(directory: dir)
        store.save(sweetSpot)
        let copy = store.duplicate(store.workouts[0])
        XCTAssertEqual(store.workouts.count, 2)
        let reloaded = CustomWorkoutStore(directory: dir)
        XCTAssertEqual(reloaded.workouts.map(\.name).sorted(), ["Sweet Spot 3 × 10", "Sweet Spot 3 × 10 (Kopie)"])
        XCTAssertEqual(reloaded.workout(id: copy.asWorkout.id)?.steps, sweetSpot.steps)
        reloaded.delete(copy.id)
        XCTAssertEqual(CustomWorkoutStore(directory: dir).workouts.count, 1)
    }

    func testDurationParsing() {
        XCTAssertEqual(DurationField.parse("4:30"), 270)
        XCTAssertEqual(DurationField.parse("10"), 600)
        XCTAssertEqual(DurationField.parse("1:02:00"), 3720)
        XCTAssertNil(DurationField.parse("abc"))
        XCTAssertNil(DurationField.parse("0"))
        XCTAssertEqual(DurationField.format(3720), "1:02:00")
        XCTAssertEqual(DurationField.format(270), "4:30")
    }

    // MARK: Editor snapshot

    /// AppKit-backed controls (text fields, steppers) need a real view hierarchy to render.
    func testRenderWorkoutEditor() throws {
        let model = AppModel.isolated(suite: "BikeAppEditorSnapshot")
        let view = WorkoutEditorView(draft: sweetSpot).environment(model)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 720)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let dir: URL
        if let path = ProcessInfo.processInfo.environment["BIKEAPP_SNAPSHOT_DIR"], !path.isEmpty {
            dir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("BikeAppSnapshots", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("workout-editor.png"))
        print("Snapshot: \(dir.path)/workout-editor.png")
    }
}
